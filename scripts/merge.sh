#!/usr/bin/env bash
# Merges a Renovate PR the fixer has taken over, once CI is green. Renovate
# stops managing a branch with fixer commits on it, so it won't merge it itself.
#
# Env: GH_TOKEN (App token), REPO, BRANCH, BASE, HEAD_SHA, SAFE_PATHS.
set -euo pipefail

source "$(dirname "$0")/lib.sh"

skip() {
  summary "Not merging: $*"
  exit 0
}

pr=$(open_pr_number)
[[ -n $pr ]] || skip "no open PR for ${BRANCH}."

labels=$(gh pr view "$pr" --repo "$REPO" --json labels --jq '[.labels[].name] | join(",")')
for blocked in major needs-human deps-review; do
  [[ ",${labels}," == *",${blocked},"* ]] && skip "#${pr} is labelled ${blocked}."
done

files=$(fixer_files)
[[ -n $files ]] || skip "#${pr} has no fixer commits; Renovate merges it."
[[ -z $(unsafe_files <<<"$files") ]] || skip "#${pr}'s fixer changes go beyond the safe paths."

failing=$(gh pr view "$pr" --repo "$REPO" --json statusCheckRollup --jq '
  [.statusCheckRollup[] | (.conclusion // .state)
   | select(. == "FAILURE" or . == "ERROR" or . == "TIMED_OUT" or . == "CANCELLED" or . == "ACTION_REQUIRED")]
  | length')
((failing == 0)) || skip "#${pr} has ${failing} failing checks."

gh pr merge "$pr" --repo "$REPO" --squash --delete-branch --match-head-commit "$HEAD_SHA"
summary "Merged #${pr}."
