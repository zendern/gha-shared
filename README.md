# gha-shared

GitHub Actions and Renovate presets shared across zendern's repositories.
The repository is private; **Settings > Actions > General > Access** is set to
"Accessible from repositories owned by 'zendern' user" so the other repos can
use its actions.

## `tree-check` action

Decides whether a merged PR needs re-testing on the base branch. CI runs on
pull requests only, and a workflow on `pull_request: closed` uses this to skip
the re-run when main already holds exactly the tested content:

```yaml
on:
  pull_request:
    types: [closed]
    branches: [main]

jobs:
  tree-check:
    if: ${{ github.event.pull_request.merged }}
    runs-on: ubuntu-24.04
    permissions:
      contents: read
      checks: read
    outputs:
      tested: ${{ steps.tree.outputs.tested }}
    steps:
      - id: tree
        uses: zendern/gha-shared/tree-check@<sha> # v1.0.0
        with:
          merge-sha: ${{ github.event.pull_request.merge_commit_sha }}
          head-sha: ${{ github.event.pull_request.head.sha }}

  test:
    needs: tree-check
    if: ${{ needs.tree-check.outputs.tested == 'false' }}
    uses: ./.github/workflows/ci.yml
    with:
      ref: ${{ github.event.pull_request.merge_commit_sha }}
```

`tested` is `true` only when the merge commit's tree equals the PR head's tree
**and** the gate check (`check-name`, default `workflow-summary`) succeeded on
that head. Point `check-name` at an all-green gate job, not at a whole-run
conclusion: a run whose jobs were all skipped (draft PRs, title edits) still
concludes `success`.

The whole merged workflow can't be shared as a reusable workflow, because the
re-test has to call each repository's own CI workflow and `uses:` must be a
static path.

## Renovate presets

The Renovate app must have access to this repository to read them.

`github>zendern/gha-shared` (`default.json`) is the whole shared behaviour, so
every repo updates the same way. A repo's `renovate.json` extends it and adds
only its own custom managers, groups and host rules:

- `config:recommended`, a 7-day `minimumReleaseAge` and
  `internalChecksFilter: strict`.
- A weekly schedule, with no updates to existing PRs outside it
  (`updateNotScheduled: false`).
- The `pre-commit` manager, so prek hook revs are bumped.
- GHCR images allowed through the release-age check, since GHCR returns no
  timestamps.
- All GitHub Actions updates grouped into one PR.
- Major updates held for approval on the Dependency Dashboard. A repo opts files
  out with a later packageRule setting `dependencyDashboardApproval: false`.

Repo rules come after the preset's, so a repo rule that sets the same option
wins.

## Rulesets

`rulesets/default-branch.json` is the `default-branch` ruleset every repo in
`rulesets/repos.txt` should carry: PR required (no approvals), signed commits,
linear history, no force-push or deletion, and a passing `workflow-summary`
check from the GitHub Actions app. Every listed repo therefore needs an
all-green gate job (e.g. `re-actors/alls-green`) named exactly
`workflow-summary`. A PR that adds the gate reports the check on its own run;
other PRs wait until it merges.

`apply` renames a legacy ruleset called `main` to `default-branch` instead of
creating a duplicate.

- `rulesets/ruleset.sh check`: read-only; reports missing or drifted rulesets
  and exits 1 on drift.
- `rulesets/ruleset.sh apply`: creates or updates them. Run it locally with your
  own `gh` login; no write credential lives in CI.

The `ruleset drift` workflow runs `check` weekly (and on demand) with a token
from a private GitHub App installed on those repos with Repository >
Administration: read. It needs the variable `RULESET_APP_CLIENT_ID` and the
secret `RULESET_APP_PRIVATE_KEY`. The token is scoped to the repos in
`repos.txt`, so a repo added there must also be added to the app installation.

## Versioning

Callers pin a full commit SHA with the tag as a comment. Tag releases `vX.Y.Z`
so Renovate's github-actions manager can bump the pins.
