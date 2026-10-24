CI failed on a branch that only updates dependencies. The failing CI log and the dependency diff are attached below. Make CI pass with the smallest correct change.

- Adapt the code, configuration or type signatures to the new versions. Don't revert, downgrade or pin back any dependency; if that is the only honest fix, change nothing and explain why.
- Follow the conventions in AGENTS.md, and use the project's own `bin/` scripts.
- Reproduce each failure locally before fixing it, then rerun the same command to confirm it passes. Run only the checks that failed, not the whole suite.
- Don't commit, push, or touch anything under `.github/`. Leave your changes in the working tree.

Finish with a short summary for the pull request: the root cause, what you changed and why, and anything you are unsure about.
