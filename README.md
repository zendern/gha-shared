# gha-shared

[![ci](https://github.com/zendern/gha-shared/actions/workflows/ci.yml/badge.svg)](https://github.com/zendern/gha-shared/actions/workflows/ci.yml)
[![ruleset drift](https://github.com/zendern/gha-shared/actions/workflows/ruleset-drift.yml/badge.svg?branch=main)](https://github.com/zendern/gha-shared/actions/workflows/ruleset-drift.yml)
[![GitHub Actions](https://img.shields.io/badge/GitHub_Actions-2088FF?logo=githubactions&logoColor=white)](https://docs.github.com/actions) [![prek](https://img.shields.io/badge/prek-enabled-DE611A?logo=precommit&logoColor=white)](https://github.com/j178/prek) [![Renovate](https://img.shields.io/badge/Renovate-enabled-1A1F6C?logo=renovate&logoColor=white)](https://docs.renovatebot.com)

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

## `setup` and `checks` actions

The common start of every CI job. Each repo pins its tool versions in a
`Taskfile.yml` under `vars:`, and both actions read them from there, so CI runs
the same versions as `task` does locally:

```yaml
vars:
  # renovate: datasource=github-releases depName=go-task/task extractVersion=^v(?<version>.+)$
  TASK_VERSION: 3.54.0
  # renovate: datasource=github-releases depName=j178/prek extractVersion=^v(?<version>.+)$
  PREK_VERSION: 0.5.10
```

```yaml
jobs:
  checks:
    runs-on: ubuntu-24.04-arm
    timeout-minutes: 10
    permissions:
      contents: read
    steps:
      - uses: zendern/gha-shared/setup@v2.1.0
        with:
          go-version-file: go.mod # omit in a repo without Go
      - uses: zendern/gha-shared/checks@v2.1.0
```

`setup` checks out the repository (`persist-credentials: false`; inputs `ref`
and `fetch-depth`) and installs Task at `TASK_VERSION`. With `go-version-file`
it also sets up Go and restores the `./bin` cache that Task's `go install`
tasks build into, keyed on the Go version, `go-version-file` and
`Taskfile.yml`. `go-cache-dependency-path` and `tools-cache-key` cover a module
outside the repository root and jobs that build different tools.

`checks` runs every prek hook at `PREK_VERSION`, then
`prek run --hook-stage manual gh-actions-lock-verify --all-files`, which checks
`.github/workflows/actions.lock` against GitHub. The verify step runs even when
a hook fails, so one run reports both. A repo using `checks` therefore needs:

- a lockfile: generate it with `gh actions-lock` after editing any `uses:` line;
- both lockfile hooks from
  [zendern/pre-commit-hooks](https://github.com/zendern/pre-commit-hooks#workflow-lockfile-gh-actions-lock)
  in its shared hooks block. `gh-actions-lock-verify` is the one CI runs, and
  the step fails if it isn't configured, so the check can't be skipped
  silently:

  ```yaml
      hooks:
        - id: gh-actions-lock-verify-local # offline, on every commit
        - id: gh-actions-lock-verify       # manual stage, run by checks
  ```

Steps inside both actions use version tags. The caller's lockfile pins them as
transitive dependencies; a caller without one runs them by tag.
`.github/zizmor.yml` suppresses zizmor's `unpinned-uses` for `action.yml` files
for that reason, since zizmor can't see a caller's lockfile.

The gate job (`workflow-summary`, see [Rulesets](#rulesets)) stays in each repo:
it lists the repo's own jobs in `needs:`, which an action can't do.

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
- A custom manager for `<NAME>_VERSION:` pins under a `# renovate:` comment, in
  `Taskfile.yml` and in `action.yml` files. A repo that defines its own copy of
  this manager should drop it, or each pin gets two PRs.
- Nothing extra for workflow lockfiles: once `.github/workflows/actions.lock`
  exists, the github-actions manager regenerates it on every action update
  (experimental in Renovate).
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

Callers reference a release tag (`zendern/gha-shared/setup@v2.1.0`), and their
workflow lockfile pins it to a commit. Tag releases `vX.Y.Z` so Renovate's
github-actions manager can bump the tags and relock.

## Development

Linting runs through [prek](https://prek.j178.dev/) using
`.pre-commit-config.yaml`, at the versions pinned in `Taskfile.yml`.

```sh
prek install  # once per clone: installs the pre-commit and pre-push hooks
task check    # lint everything (CI runs the same hooks through ./checks)
task lock     # regenerate .github/workflows/actions.lock after editing a `uses:`
```

CI calls `$/setup` and `$/checks`, so each PR tests its own versions of the
actions. `gh actions-lock` rewrites the pins inside actions reached through
`$/` to tags, which is why they aren't SHAs.
