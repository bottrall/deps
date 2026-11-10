#!/usr/bin/env bash
# Merges a Renovate PR the fixer has taken over, once CI is green. Renovate
# stops managing a branch with fixer commits on it, so it won't merge it itself.
#
# Env: GH_TOKEN (App token), REPO, BRANCH, BASE, HEAD_SHA, SAFE_PATHS.
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

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

mapfile -t paths <<<"$files"
modes=$(git --literal-pathspecs ls-tree -r --format='%(objectmode)' HEAD -- "${paths[@]}")
[[ -z $(grep -vx 100644 <<<"$modes") ]] || skip "#${pr}'s fixer changes leave a file executable or not a regular file."

unpassed=$(gh pr view "$pr" --repo "$REPO" --json statusCheckRollup --jq '
  [.statusCheckRollup[]
   | select(.state == "SUCCESS" or (.status == "COMPLETED" and (.conclusion == "SUCCESS" or .conclusion == "NEUTRAL" or .conclusion == "SKIPPED")) | not)]
  | length')
((unpassed == 0)) || skip "#${pr} has ${unpassed} checks that haven't passed."

gh pr merge "$pr" --repo "$REPO" --squash --delete-branch --match-head-commit "$HEAD_SHA"
summary "Merged #${pr}."
