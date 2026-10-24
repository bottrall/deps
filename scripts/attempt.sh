#!/usr/bin/env bash
# The untrusted half of the fixer: runs everything that executes the repo's
# (freshly updated) dependencies, and holds no write credential. It writes its
# result to OUT for publish.sh, which runs in a separate job.
#
# 1. Scripted fixes (free): a stale rbs collection lockfile.
# 2. Otherwise, riffer-rig headless, up to MAX_ATTEMPTS fixer commits per branch.
#
# OUT gets `meta.json` ({kind, attempts, agent_exit, usage, reason}),
# `patch.diff` (changes since the post-setup baseline) and `reply.md`.
#
# Env: OUT, ACTIONS_TOKEN (read-only GITHUB_TOKEN, for logs), REPO, BRANCH,
# BASE, RUN_ID, MODEL, REASONING, MAX_STEPS, MAX_ATTEMPTS, TOOLING (this repo's
# files), and either the ANTHROPIC_* federation variables (organization, rule
# and service account IDs, optional workspace) or ANTHROPIC_API_KEY.
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

work=$(mktemp -d)
agent_env=(env -u ACTIONS_TOKEN -u ACTIONS_ID_TOKEN_REQUEST_TOKEN -u ACTIONS_ID_TOKEN_REQUEST_URL)
untracked=(':(exclude)vendor' ':(exclude)node_modules' ':(exclude).riffer' ':(exclude)tmp')

refresh_identity_token() {
  local token
  token=$(curl -fsS -H "Authorization: Bearer ${ACTIONS_ID_TOKEN_REQUEST_TOKEN}" \
    "${ACTIONS_ID_TOKEN_REQUEST_URL}&audience=https://api.anthropic.com" | jq -r '.value // empty') || return 1
  [[ -n $token ]] || return 1
  printf '%s' "$token" >"${ANTHROPIC_IDENTITY_TOKEN_FILE}.next" && mv "${ANTHROPIC_IDENTITY_TOKEN_FILE}.next" "$ANTHROPIC_IDENTITY_TOKEN_FILE"
}

# The claims the federation rule matches on, for comparing against it when an
# exchange is refused. Only the decoded payload: the token itself is a
# credential.
summarize_identity_claims() {
  local claims
  claims=$(jq -rR 'split(".")[1] | gsub("-"; "+") | gsub("_"; "/") | @base64d | fromjson
    | {sub, aud, repository_owner, ref, event_name, job_workflow_ref}' "$ANTHROPIC_IDENTITY_TOKEN_FILE") || return 0
  summary "Identity token claims:"$'\n\n```json\n'"${claims}"$'\n```'
}

# GitHub's identity tokens live ~5 minutes and each can be exchanged only once,
# and the SDK re-reads the file on every refresh, so it's rewritten every 2
# minutes for as long as the agent runs.
anthropic_credentials() {
  local name
  for name in ANTHROPIC_ORGANIZATION_ID ANTHROPIC_FEDERATION_RULE_ID ANTHROPIC_SERVICE_ACCOUNT_ID ANTHROPIC_WORKSPACE_ID ANTHROPIC_API_KEY; do
    [[ -n ${!name:-} ]] || unset "$name"
  done

  if [[ -n ${ANTHROPIC_FEDERATION_RULE_ID:-} ]]; then
    [[ -n ${ACTIONS_ID_TOKEN_REQUEST_URL:-} ]] || {
      credentials_problem="Federation is configured, but the calling workflow doesn't grant \`id-token: write\`."
      return 1
    }
    export ANTHROPIC_IDENTITY_TOKEN_FILE=$work/identity-token
    refresh_identity_token || {
      credentials_problem="Couldn't fetch a GitHub identity token."
      return 1
    }
    summarize_identity_claims
    (while sleep 120; do refresh_identity_token || true; done) >/dev/null 2>&1 &
    trap "kill $! 2>/dev/null || true" EXIT
    # Any ANTHROPIC_API_KEY, even an empty one, would win over federation.
    agent_env+=(-u ANTHROPIC_API_KEY)
    return 0
  fi

  [[ -n ${ANTHROPIC_API_KEY:-} ]] || {
    credentials_problem="No Anthropic credentials are configured (federation inputs or an ANTHROPIC_API_KEY secret)."
    return 1
  }
}

# Setup rewrites tracked files (setup-ruby changes a committed .bundle/config),
# so the patch is taken against a local commit of the post-setup tree.
commit_baseline() {
  git add --all -- . "${untracked[@]}"
  git -c user.name=baseline -c user.email=baseline@invalid commit --quiet --allow-empty --no-verify --message baseline
}

write_patch() {
  git add --all -- . "${untracked[@]}"
  git diff --cached --binary HEAD >"$OUT/patch.diff"
}

write_context() {
  {
    printf '## Failed CI log\n\n```\n'
    GH_TOKEN=$ACTIONS_TOKEN gh run view "$RUN_ID" --repo "$REPO" --log-failed | tail -c 60000
    printf '\n```\n\n## Dependency changes\n\n```\n'
    git diff --stat "origin/${BASE}...origin/${BRANCH}"
    git diff "origin/${BASE}...origin/${BRANCH}" -- Gemfile Gemfile.lock '*.gemspec' package.json | head -c 40000
    printf '\n```\n'
  } >"$work/context.md"
}

# riffer-rig declares the Anthropic SDK version it supports; the newest
# release may be a major it doesn't.
install_riffer() {
  local sdk
  gem install riffer-rig --no-document --silent
  sdk=$(ruby -e 'require "riffer/rig"; puts Riffer::Rig::ProviderSetup::TABLE.fetch(:anthropic).sdk.last')
  gem install anthropic --version "$sdk" --no-document --silent
  mkdir -p ~/.riffer
  jq -n --arg catalog "$TOOLING/riffer/models.json" '{catalog_files: [$catalog]}' >~/.riffer/settings.json
}

run_agent() {
  set +e
  "${agent_env[@]}" \
    riffer -p --no-save --json \
      --model "anthropic/${MODEL}" --reasoning "$REASONING" --max-steps "$MAX_STEPS" \
      "$(cat "$TOOLING/prompts/fix.md")" <"$work/context.md" >"$work/riffer.ndjson" 2>"$work/riffer.stderr"
  agent_exit=$?
  set -e

  jq -rs '
    ([.[] | select(.type == "text_done")] | last | .content)
    // ([.[] | select(.type == "error")] | last | select(.) | "riffer failed: \(.message)")
    // "(no reply)"' "$work/riffer.ndjson" >"$OUT/reply.md"
  agent_usage=$(jq -cs '[.[] | select(.type == "turn_end")] | last | .usage // {}' "$work/riffer.ndjson")
}

finish() {
  local kind=$1 reason=${2:-}
  jq -n --arg kind "$kind" --arg reason "$reason" --argjson attempts "${attempts:-0}" \
    --argjson agent_exit "${agent_exit:-null}" --argjson usage "${agent_usage:-null}" \
    '{kind: $kind, reason: $reason, attempts: $attempts, agent_exit: $agent_exit, usage: $usage}' >"$OUT/meta.json"
  summary "Attempt result: ${kind}${reason:+ (${reason})}"
}

main() {
  mkdir -p "$OUT"
  : >"$OUT/patch.diff"
  : >"$OUT/reply.md"

  [[ -x bin/setup ]] && bin/setup
  commit_baseline

  if [[ -f rbs_collection.yaml ]] && bundle exec rbs collection update && ! git diff --quiet -- rbs_collection.lock.yaml; then
    write_patch
    finish mechanical
    return 0
  fi
  git checkout --quiet -- .

  attempts=$(git log --fixed-strings --author="$FIXER_EMAIL" --format=%H "origin/${BASE}..origin/${BRANCH}" | wc -l | tr -d ' ')
  if ((attempts >= MAX_ATTEMPTS)); then
    finish gave-up
    return 0
  fi

  if ! anthropic_credentials; then
    finish no-credentials "$credentials_problem"
    return 0
  fi

  write_context
  install_riffer
  run_agent
  write_patch
  finish agent
}

# Sourcing (for tests) defines the functions without running.
if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  main "$@"
fi
