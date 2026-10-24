# Shared helpers for fix.sh and merge.sh. Expects GH_TOKEN, REPO, BRANCH and
# BASE in the environment.

# Renovate is told to ignore MECHANICAL_EMAIL (see renovate.yml), so it keeps
# managing a branch that only has scripted fixes. FIXER_EMAIL is deliberately
# not ignored: an agent commit hands the branch over from Renovate to merge.sh.
MECHANICAL_NAME="deps-mechanical"
MECHANICAL_EMAIL="deps-mechanical@bottrall-deps.invalid"
FIXER_NAME="riffer-rig fixer"
FIXER_EMAIL="deps-fixer@bottrall-deps.invalid"

commit_as() {
  local name=$1 email=$2 message=$3
  git -c user.name="$name" -c user.email="$email" commit --quiet --message "$message"
}

push_branch() {
  git push --quiet "https://x-access-token:${GH_TOKEN}@github.com/${REPO}.git" "HEAD:refs/heads/${BRANCH}"
}

open_pr_number() {
  gh pr list --repo "$REPO" --head "$BRANCH" --state open --json number --jq '.[0].number // empty'
}

fixer_files() {
  git log --fixed-strings --author="$FIXER_EMAIL" --name-only --format= "origin/${BASE}..HEAD" | sort -u | sed '/^$/d'
}

# Prints the files that don't match any SAFE_PATHS regex (one per line).
unsafe_files() {
  grep --invert-match --extended-regexp --file=<(printf '%s\n' "$SAFE_PATHS" | sed '/^[[:space:]]*$/d') || true
}

add_label() {
  local pr=$1 label=$2 color=$3 description=$4
  gh label create "$label" --repo "$REPO" --color "$color" --description "$description" --force >/dev/null
  gh pr edit "$pr" --repo "$REPO" --add-label "$label" >/dev/null
}

summary() {
  printf '%s\n' "$*" >>"${GITHUB_STEP_SUMMARY:-/dev/stdout}"
}
