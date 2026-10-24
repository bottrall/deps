#!/usr/bin/env bash
# Tries to turn a red Renovate branch green, run from the target repo's checkout.
#
# 1. Scripted fixes (free): a stale rbs collection lockfile.
# 2. Otherwise, riffer-rig headless, up to MAX_ATTEMPTS commits per branch.
#
# Env: GH_TOKEN (App token), ACTIONS_TOKEN (GITHUB_TOKEN, for logs), REPO,
# BRANCH, BASE, RUN_ID, MODEL, REASONING, MAX_STEPS, MAX_ATTEMPTS, SAFE_PATHS,
# TOOLING (this repo's files), and either the ANTHROPIC_* federation variables
# (organization, rule and service account IDs, optional workspace) or
# ANTHROPIC_API_KEY.
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

work=$(mktemp -d)
agent_env=(env -u GH_TOKEN -u ACTIONS_TOKEN -u ACTIONS_ID_TOKEN_REQUEST_TOKEN -u ACTIONS_ID_TOKEN_REQUEST_URL)

refresh_identity_token() {
  local token
  token=$(curl -fsS -H "Authorization: Bearer ${ACTIONS_ID_TOKEN_REQUEST_TOKEN}" \
    "${ACTIONS_ID_TOKEN_REQUEST_URL}&audience=https://api.anthropic.com" | jq -r '.value // empty') || return 1
  [[ -n $token ]] || return 1
  printf '%s' "$token" >"${ANTHROPIC_IDENTITY_TOKEN_FILE}.next" && mv "${ANTHROPIC_IDENTITY_TOKEN_FILE}.next" "$ANTHROPIC_IDENTITY_TOKEN_FILE"
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

mechanical_fix() {
  [[ -f rbs_collection.yaml ]] || return 1
  bundle exec rbs collection update
  git diff --quiet -- rbs_collection.lock.yaml && return 1
  git add rbs_collection.lock.yaml
  commit_as "$MECHANICAL_NAME" "$MECHANICAL_EMAIL" "chore(deps): update rbs collection lockfile"
}

ensure_pr() {
  local number title
  number=$(open_pr_number)
  if [[ -z $number ]]; then
    title=$(git log --reverse --format=%s "origin/${BASE}..HEAD" | head -n 1)
    gh pr create --repo "$REPO" --base "$BASE" --head "$BRANCH" --title "$title" \
      --body "Renovate's update failed CI, so the deps fixer opened this PR to work on it." >/dev/null
    number=$(open_pr_number)
  fi
  printf '%s' "$number"
}

write_context() {
  {
    printf '## Failed CI log\n\n```\n'
    GH_TOKEN=$ACTIONS_TOKEN gh run view "$RUN_ID" --repo "$REPO" --log-failed | tail -c 60000
    printf '\n```\n\n## Dependency changes\n\n```\n'
    git diff --stat "origin/${BASE}...HEAD"
    git diff "origin/${BASE}...HEAD" -- Gemfile Gemfile.lock '*.gemspec' package.json | head -c 40000
    printf '\n```\n'
  } >"$work/context.md"
}

run_agent() {
  gem install riffer-rig anthropic --no-document --silent
  mkdir -p ~/.riffer
  jq -n --arg catalog "$TOOLING/riffer/models.json" '{catalog_files: [$catalog]}' >~/.riffer/settings.json

  set +e
  "${agent_env[@]}" \
    riffer -p --no-save --json \
      --model "anthropic/${MODEL}" --reasoning "$REASONING" --max-steps "$MAX_STEPS" \
      "$(cat "$TOOLING/prompts/fix.md")" <"$work/context.md" >"$work/riffer.ndjson" 2>"$work/riffer.stderr"
  agent_exit=$?
  set -e

  agent_reply=$(jq -rs '
    ([.[] | select(.type == "text_done")] | last | .content)
    // ([.[] | select(.type == "error")] | last | select(.) | "riffer failed: \(.message)")
    // "(no reply)"' "$work/riffer.ndjson")
  agent_usage=$(jq -cs '[.[] | select(.type == "turn_end")] | last | .usage // {}' "$work/riffer.ndjson")
}

stage_changes() {
  git add --all -- . ':(exclude)vendor' ':(exclude)node_modules' ':(exclude).riffer' ':(exclude)tmp'
  ! git diff --cached --quiet
}

report() {
  local pr=$1 heading=$2 files=${3:-}
  {
    printf '### %s\n\n%s\n\n' "$heading" "$agent_reply"
    [[ -n $files ]] && printf '**Files changed:**\n\n%s\n\n' "$(sed 's/^/- `/; s/$/`/' <<<"$files")"
    printf '<sub>%s · reasoning %s · riffer exit %s · usage `%s`</sub>\n' "$MODEL" "$REASONING" "$agent_exit" "$agent_usage"
  } >"$work/comment.md"
  gh pr comment "$pr" --repo "$REPO" --body-file "$work/comment.md" >/dev/null
  cat "$work/comment.md" >>"${GITHUB_STEP_SUMMARY:-/dev/stdout}"
}

main() {
  if mechanical_fix; then
    push_branch
    summary "Pushed a scripted fix: updated rbs_collection.lock.yaml."
    return 0
  fi

  pr=$(ensure_pr)
  attempts=$(git log --fixed-strings --author="$FIXER_EMAIL" --format=%H "origin/${BASE}..HEAD" | wc -l | tr -d ' ')

  if ((attempts >= MAX_ATTEMPTS)); then
    add_label "$pr" needs-human d93f0b "The deps fixer couldn't get this green"
    gh pr comment "$pr" --repo "$REPO" --body "CI is still failing after ${attempts} fixer attempts, so this needs a human." >/dev/null
    summary "Gave up after ${attempts} attempts; labelled #${pr} needs-human."
    return 0
  fi

  if ! anthropic_credentials; then
    add_label "$pr" needs-human d93f0b "The deps fixer couldn't get this green"
    gh pr comment "$pr" --repo "$REPO" --body "CI failed and the fixer can't run its agent: ${credentials_problem}" >/dev/null
    summary "Skipped the agent: ${credentials_problem}"
    return 0
  fi

  [[ -x bin/setup ]] && bin/setup
  write_context
  run_agent

  if ! stage_changes; then
    add_label "$pr" needs-human d93f0b "The deps fixer couldn't get this green"
    report "$pr" "The fixer made no changes" ""
    return 0
  fi

  files=$(git diff --cached --name-only)
  commit_as "$FIXER_NAME" "$FIXER_EMAIL" "chore(deps): fix CI after dependency updates"
  push_branch

  if [[ -n $(unsafe_files <<<"$files") ]]; then
    add_label "$pr" deps-review 1d76db "The deps fixer changed code; review before merging"
    report "$pr" "Fixer attempt $((attempts + 1)): changed code, so this needs your review once CI is green" "$files"
  else
    report "$pr" "Fixer attempt $((attempts + 1)): this merges automatically once CI is green" "$files"
  fi
}

# Sourcing (for tests) defines the functions without running.
if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  main "$@"
fi
