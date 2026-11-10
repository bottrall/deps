#!/usr/bin/env bash
# The trusted half of the fixer: holds the App token and never runs the repo's
# code. It treats attempt.sh's output (in IN) as untrusted data: it checks the
# patch before applying it, then commits, pushes, labels and comments.
#
# Env: GH_TOKEN (App token), IN, REPO, BRANCH, BASE, SAFE_PATHS, MAX_ATTEMPTS,
# MODEL, REASONING, ATTEMPT_RESULT (the attempt job's result; anything but
# `success` means it crashed and IN is empty) and RUN_URL.
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

meta=$IN/meta.json
patch=$IN/patch.diff
work=$(mktemp -d)

refuse() {
  summary "Refused the attempt's output: $*"
  echo "::error::Refused the attempt's output: $*" >&2
  exit 1
}

# Prints the patch's paths, refusing renames, unusual names and workflows.
patch_files() {
  local files
  files=$(git apply --numstat "$patch" | cut -f3) || refuse "the patch is malformed"
  grep -qE '=>|^"' <<<"$files" && refuse "the patch renames files or uses unusual file names"
  grep -qE '^\.github/' <<<"$files" && refuse "the patch touches .github/"
  printf '%s\n' "$files"
}

# Refuses anything the patch leaves in the index other than a regular file
# added, modified or deleted (symlinks, submodules, type changes), checked
# after applying because a patch can spell a mode many ways.
apply_patch() {
  local header path
  git apply --check --index "$patch" || refuse "the patch doesn't apply to ${BRANCH}"
  git apply --index "$patch"
  git diff --cached --raw -z --no-renames >"$work/raw"
  while IFS= read -r -d '' header && IFS= read -r -d '' path; do
    [[ $header =~ ^:(100644|100755|000000)\ (100644|100755|000000)\ [0-9a-f]+\ [0-9a-f]+\ [AMD]$ ]] ||
      refuse "the patch makes ${path@Q} something other than a regular file"
  done <"$work/raw"
}

# Paths are grepped along with headers, but one that looks like a header only
# errs towards review.
adds_executable() {
  grep -qz '^:[0-7]* 100755 ' "$work/raw"
}

needs_review() {
  [[ -n $(unsafe_files <<<"$1") ]] || adds_executable
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

needs_human() {
  add_label "$1" needs-human d93f0b "The deps fixer couldn't get this green"
  hold "$1"
}

# Renovate turns on GitHub's auto-merge when it opens a PR, which would merge
# a labelled PR as soon as CI passes; a PR waiting for a human must not. If
# it's still on, nothing more is pushed.
hold() {
  gh pr merge "$1" --repo "$REPO" --disable-auto >/dev/null 2>&1 || true
  [[ $(gh pr view "$1" --repo "$REPO" --json autoMergeRequest --jq '.autoMergeRequest == null') == true ]] && return 0
  add_label "$1" needs-human d93f0b "The deps fixer couldn't get this green"
  summary "Couldn't turn off auto-merge on #${1}, so pushed nothing and labelled it needs-human."
  echo "::error::Couldn't turn off auto-merge on #${1}" >&2
  exit 1
}

report() {
  local pr=$1 heading=$2 files=${3:-}
  {
    printf '### %s\n\n' "$heading"
    head -c 50000 "$IN/reply.md"
    printf '\n\n'
    [[ -n $files ]] && printf '**Files changed:**\n\n%s\n\n' "$(sed 's/^/- `/; s/$/`/' <<<"$files")"
    printf '<sub>%s · reasoning %s · riffer exit %s · usage `%s`</sub>\n' \
      "$MODEL" "$REASONING" "$(jq -r '.agent_exit // "-"' "$meta")" "$(jq -c '.usage // {}' "$meta")"
  } >"$work/comment.md"
  gh pr comment "$pr" --repo "$REPO" --body-file "$work/comment.md" >/dev/null
  cat "$work/comment.md" >>"${GITHUB_STEP_SUMMARY:-/dev/stdout}"
}

publish_mechanical() {
  local files
  files=$(patch_files)
  [[ $files == rbs_collection.lock.yaml ]] || refuse "a scripted fix may only change rbs_collection.lock.yaml"
  apply_patch
  adds_executable && refuse "a scripted fix may not make files executable"
  commit_as "$MECHANICAL_NAME" "$MECHANICAL_EMAIL" "chore(deps): update rbs collection lockfile"
  push_branch
  summary "Pushed a scripted fix: updated rbs_collection.lock.yaml."
}

give_up() {
  needs_human "$1"
  gh pr comment "$1" --repo "$REPO" --body "CI is still failing after $(fixer_attempts) fixer attempts, so this needs a human." >/dev/null
  summary "Gave up; labelled #${1} needs-human."
}

publish_agent() {
  local pr files attempt agent_exit
  pr=$(ensure_pr)
  attempt=$(($(fixer_attempts) + 1))
  if ((attempt > MAX_ATTEMPTS)); then
    give_up "$pr"
    return 0
  fi
  agent_exit=$(jq -e '.agent_exit | select(type == "number" and . == floor)' "$meta") || refuse "agent_exit isn't an integer"

  # A riffer run that errored (exit 1 or 2) leaves nothing worth committing;
  # one that hit its step limit (3) may have made progress the next attempt
  # can build on.
  if [[ ! -s $patch || ($agent_exit != 0 && $agent_exit != 3) ]]; then
    needs_human "$pr"
    report "$pr" "Fixer attempt ${attempt}: no usable changes"
    return 0
  fi

  files=$(patch_files)
  apply_patch
  needs_review "$files" && hold "$pr"
  commit_as "$FIXER_NAME" "$FIXER_EMAIL" "chore(deps): fix CI after dependency updates"
  push_branch

  if needs_review "$files"; then
    add_label "$pr" deps-review 1d76db "The deps fixer changed code; review before merging"
    report "$pr" "Fixer attempt ${attempt}: changed code, so this needs your review once CI is green" "$files"
  else
    report "$pr" "Fixer attempt ${attempt}: this merges automatically once CI is green" "$files"
  fi
}

main() {
  local kind pr
  if [[ $ATTEMPT_RESULT != success ]]; then
    pr=$(ensure_pr)
    needs_human "$pr"
    gh pr comment "$pr" --repo "$REPO" --body "CI failed and the fix attempt crashed before the agent could finish ([run](${RUN_URL})), so this needs a human." >/dev/null
    summary "The attempt crashed; labelled #${pr} needs-human."
    return 0
  fi

  kind=$(jq -r '.kind' "$meta") || refuse "meta.json is unreadable"

  case $kind in
    mechanical) publish_mechanical ;;
    agent) publish_agent ;;
    gave-up)
      pr=$(ensure_pr)
      give_up "$pr"
      ;;
    no-credentials)
      pr=$(ensure_pr)
      needs_human "$pr"
      gh pr comment "$pr" --repo "$REPO" --body "CI failed and the fixer can't run its agent: $(jq -r '.reason' "$meta" | head -c 500)" >/dev/null
      summary "Skipped the agent; labelled #${pr} needs-human."
      ;;
    *) refuse "unknown result kind: ${kind@Q}" ;;
  esac
}

# Sourcing (for tests) defines the functions without running.
if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  main "$@"
fi
