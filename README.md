# deps

Dependency updates for bottrall's repos that don't need looking after: self-hosted [Renovate](https://docs.renovatebot.com/) opens one grouped branch a week and merges it when CI is green, and when CI is red a [riffer-rig](https://github.com/bottrall/riffer-rig) agent (Claude Haiku 5.5, `xhigh` reasoning) tries to fix it.

```text
Renovate (every 2h, new branches Monday mornings)
  └─ renovate/* branch ── CI ──┬─ green ─────────────► Renovate merges it
                               └─ red ── deps-fix ─┬─ rbs lockfile stale ──► scripted fix, CI reruns
                                                   └─ otherwise ──► PR + riffer-rig fix, CI reruns
                                                         ├─ green, safe files only ─► merged
                                                         ├─ green, code changed ────► labelled deps-review
                                                         └─ still red after 2 tries ► labelled needs-human
```

## What's here

| Path | What it does |
| ---- | ------------ |
| `default.json` | The shared Renovate preset: grouped non-major updates and lockfile maintenance, merged without a PR; majors get their own PR and are never merged automatically; a release must be 3 days old |
| `.github/workflows/renovate.yml` | Runs Renovate for every repo the GitHub App is installed on that has a `renovate.json` |
| `.github/workflows/fix.yml` | Reusable workflow each repo calls when its CI finishes on a `renovate/*` branch |
| `scripts/` | The fix and merge steps |
| `prompts/fix.md` | What the agent is asked to do |
| `riffer/models.json` | Haiku 5.5 prices, so each run's cost shows up in the PR comment |

The fixer's commits only merge without review when every file they touch matches the `safe-paths` input: lockfiles, `sig/` and RuboCop config. Anything else waits for you with the `deps-review` label.

## Adding a repo

1. Install the GitHub App on the repo.
2. Add the repo secrets `DEPS_APP_CLIENT_ID`, `DEPS_APP_PRIVATE_KEY` and `ANTHROPIC_API_KEY`.
3. Add `renovate.json`:

   ```json
   { "extends": ["github>bottrall/deps"] }
   ```

4. Make CI run on Renovate's branches as well as PRs, because Renovate merges without opening one:

   ```yaml
   on:
     pull_request:
     push:
       branches:
         - "renovate/**"
   ```

5. Add `.github/workflows/deps.yml`, naming the CI workflow in `workflows`:

   ```yaml
   name: deps

   on:
     workflow_run:
       workflows: [ci]
       types: [completed]
       branches: ["renovate/**"]

   permissions:
     actions: read
     contents: read

   jobs:
     deps:
       uses: bottrall/deps/.github/workflows/fix.yml@main
       secrets: inherit
   ```

## Setup (once)

This repo needs the secrets `DEPS_APP_CLIENT_ID` and `DEPS_APP_PRIVATE_KEY` for a GitHub App with these repository permissions: Contents, Pull requests, Issues, Commit statuses, Workflows and Checks (read and write), plus Metadata (read). The App's tokens are what make Renovate's and the fixer's pushes trigger CI, which pushes made with `GITHUB_TOKEN` don't.

This repo is public so its Actions minutes are free. Renovate's logs here name the repos and dependencies it updates.
