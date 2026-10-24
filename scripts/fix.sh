#!/usr/bin/env bash
# Tries to turn a red Renovate branch green, run from the target repo's checkout.
#
# 1. Scripted fixes (free): a stale rbs collection lockfile.
# 2. Otherwise, riffer-rig headless, up to MAX_ATTEMPTS commits per branch.
#
# Env: GH_TOKEN (App token), ACTIONS_TOKEN (GITHUB_TOKEN, for logs), REPO,
# BRANCH, BASE, RUN_ID, MODEL, REASONING, MAX_STEPS, MAX_ATTEMPTS, SAFE_PATHS,
# TOOLING (this repo's files), ANTHROPIC_API_KEY.
set -euo pipefail

source "$(dirname "$0")/lib.sh"

work=$(mktemp -d)

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
  env -u GH_TOKEN -u ACTIONS_TOKEN \
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

if mechanical_fix; then
  push_branch
  summary "Pushed a scripted fix: updated rbs_collection.lock.yaml."
  exit 0
fi

pr=$(ensure_pr)
attempts=$(git log --fixed-strings --author="$FIXER_EMAIL" --format=%H "origin/${BASE}..HEAD" | wc -l | tr -d ' ')

if ((attempts >= MAX_ATTEMPTS)); then
  add_label "$pr" needs-human d93f0b "The deps fixer couldn't get this green"
  gh pr comment "$pr" --repo "$REPO" --body "CI is still failing after ${attempts} fixer attempts, so this needs a human." >/dev/null
  summary "Gave up after ${attempts} attempts; labelled #${pr} needs-human."
  exit 0
fi

[[ -x bin/setup ]] && bin/setup
write_context
run_agent

if ! stage_changes; then
  add_label "$pr" needs-human d93f0b "The deps fixer couldn't get this green"
  report "$pr" "The fixer made no changes" ""
  exit 0
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
