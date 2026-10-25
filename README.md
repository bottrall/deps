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
| `scripts/` | `attempt.sh` and `publish.sh` (the two halves of a fix), `merge.sh`, and `onboard.sh` for adding a repo |
| `prompts/fix.md` | What the agent is asked to do |
| `riffer/models.json` | Haiku 5.5 prices, so each run's cost shows up in the PR comment |

A fix runs as two jobs on separate machines, because it executes freshly updated dependencies, any of which could be malicious. `attempt` runs them (setup, the rbs update, the agent) with only read-only GitHub credentials and a short-lived Anthropic token, and hands over a patch. `publish` holds the App's write token but runs none of the repo's code: it refuses patches that touch `.github/`, add symlinks or submodules, or rename files, then commits and pushes.

The fixer's commits only merge without review when every file they touch matches the `safe-paths` input: lockfiles, `sig/` and RuboCop config. Anything else waits for you with the `deps-review` label.

## Adding a repo

`scripts/onboard.sh <repo> [ci-workflow-file]` does steps 1–5 apart from installing the App, and opens a PR in the repo. By hand:

1. Install the GitHub App on the repo, and add it to the `RENOVATE_REPOSITORIES` variable on this repo (comma-separated `owner/name`).
2. Add the repo secrets `DEPS_APP_CLIENT_ID` and `DEPS_APP_PRIVATE_KEY`. No Anthropic secret is needed (see [Anthropic credentials](#anthropic-credentials)).
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
     id-token: write

   jobs:
     deps:
       uses: bottrall/deps/.github/workflows/fix.yml@main
       secrets: inherit
   ```

## Setup (once)

This repo needs the secrets `DEPS_APP_CLIENT_ID` and `DEPS_APP_PRIVATE_KEY` for a GitHub App with these repository permissions: Contents, Pull requests, Issues, Commit statuses, Workflows and Checks (read and write), plus Actions and Metadata (read). The App's tokens are what make Renovate's and the fixer's pushes trigger CI, which pushes made with `GITHUB_TOKEN` don't.

This repo is public so its Actions minutes are free. Renovate's logs here name the repos in `RENOVATE_REPOSITORIES` and the dependencies it updates.

## Anthropic credentials

The agent authenticates with [Workload Identity Federation](https://platform.claude.com/docs/en/manage-claude/wif-providers/github-actions): each run exchanges the job's GitHub identity token for an Anthropic token that lasts minutes, so there is no API key to store or leak, and one federation rule covers every repo. The fix workflow's `anthropic-*` inputs default to that rule's IDs; they aren't secret, because the rule only accepts tokens from this repo's fix workflow on `main`.

In the Claude Console, the `GitHub automation` workspace (with a monthly spend limit) holds everything GitHub-driven, `bottrall-bot` is the service account all bot jobs act as, and each job gets its own rule under **Workload identity**. This job's rule, `deps-fixer`:

| Field | Value |
| ----- | ----- |
| Issuer | `github-actions`: `https://token.actions.githubusercontent.com` (discovery) |
| Service account | `bottrall-bot` |
| Workspace | `GitHub automation` only |
| Subject prefix | `repo:bottrall@75273444/*`. GitHub's subjects carry the owner's and repo's immutable IDs (`repo:bottrall@75273444/riffer-rig@1248766665:ref:refs/heads/main`), so a renamed or re-registered `bottrall` can't match |
| Audience | `https://api.anthropic.com` |
| Claims | `repository_owner` = `bottrall`, `ref` = `refs/heads/main`, `event_name` = `workflow_run`, `job_workflow_ref` = `bottrall/deps/.github/workflows/fix.yml@refs/heads/main` |
| Scope | `workspace:developer` |
| Token lifetime | 600 seconds |

A new job that needs Claude gets a new rule for its own workflow, targeting the same service account and workspace.

With the `anthropic-*` inputs empty, the fixer falls back to an `ANTHROPIC_API_KEY` secret on the calling repo.
