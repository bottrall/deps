#!/usr/bin/env bash
# Onboards one of your repos, run locally: sets the App secrets, opens a PR
# adding renovate.json and deps.yml, and adds the repo to
# RENOVATE_REPOSITORIES. Needs the App credentials in ~/.config/bottrall-deps
# (written when the App was created). For GitHub to merge Renovate's PRs
# itself, the repo needs "Allow auto-merge" and required status checks.
#
# Usage: scripts/onboard.sh <repo> [ci-workflow-file]   (default ci.yml)
set -euo pipefail

owner=bottrall
repo=$owner/$1
ci_file=.github/workflows/${2:-ci.yml}
branch=chore/renovate
config=~/.config/bottrall-deps
tmp=$(mktemp -d)

put() {
  local path=$1 file=$2 message=$3 sha
  sha=$(gh api "repos/$repo/contents/$path?ref=$branch" --jq .sha 2>/dev/null || true)
  gh api -X PUT "repos/$repo/contents/$path" -f message="$message" -f branch="$branch" \
    -f content="$(base64 <"$file")" ${sha:+-f sha="$sha"} --silent
}

gh secret set DEPS_APP_CLIENT_ID --repo "$repo" --body "$(jq -r .client_id "$config/app.json")"
gh secret set DEPS_APP_PRIVATE_KEY --repo "$repo" <"$config/app.pem"

base_sha=$(gh api "repos/$repo/git/ref/heads/main" --jq .object.sha)
gh api "repos/$repo/git/refs" -f ref="refs/heads/$branch" -f sha="$base_sha" --silent

printf '{\n  "$schema": "https://docs.renovatebot.com/renovate-schema.json",\n  "extends": ["github>%s/deps"]\n}\n' "$owner" >"$tmp/renovate.json"
put renovate.json "$tmp/renovate.json" "chore: add renovate config"

ci_name=$(gh api "repos/$repo/contents/$ci_file" --jq .content | base64 -d | ruby -ryaml -e 'puts YAML.load($stdin.read).fetch("name")')

cat >"$tmp/deps.yml" <<EOF
# Fixes and merges Renovate's branches when CI finishes on them; the logic
# lives in $owner/deps.

name: deps

on:
  workflow_run:
    workflows: [$ci_name]
    types: [completed]
    branches: ["renovate/**"]

permissions:
  actions: read
  contents: read
  id-token: write

jobs:
  deps:
    uses: $owner/deps/.github/workflows/fix.yml@main
    secrets: inherit
EOF
put .github/workflows/deps.yml "$tmp/deps.yml" "chore: add deps workflow"

cat >"$tmp/body.md" <<EOF
Onboards this repo onto [$owner/deps](https://github.com/$owner/deps):

- \`renovate.json\` extends the shared preset: one grouped PR a week for non-major updates plus one for lockfile maintenance, merged automatically once CI passes; majors get their own PR and are never merged automatically.
- \`deps.yml\` calls the shared fixer when CI finishes on a Renovate branch.
EOF
gh pr create --repo "$repo" --base main --head "$branch" --title "chore: onboard onto $owner/deps" --body-file "$tmp/body.md"

current=$(gh variable get RENOVATE_REPOSITORIES --repo "$owner/deps" 2>/dev/null || true)
if [[ ",${current}," != *",${repo},"* ]]; then
  gh variable set RENOVATE_REPOSITORIES --repo "$owner/deps" --body "${current:+${current},}${repo}"
fi
