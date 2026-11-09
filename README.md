# gha-shared

[![ci](https://github.com/zendern/gha-shared/actions/workflows/ci.yml/badge.svg)](https://github.com/zendern/gha-shared/actions/workflows/ci.yml)
[![GitHub Actions](https://img.shields.io/badge/GitHub_Actions-2088FF?logo=githubactions&logoColor=white)](https://docs.github.com/actions) [![prek](https://img.shields.io/badge/prek-enabled-DE611A?logo=precommit&logoColor=white)](https://github.com/j178/prek) [![Renovate](https://img.shields.io/badge/Renovate-enabled-1A1F6C?logo=renovate&logoColor=white)](https://docs.renovatebot.com)

Composite GitHub Actions and a Renovate preset shared across zendern's
repositories and maybe others if you like the setup.

## Contents

- [GitHub Actions](#github-actions)
  - [`setup` and `checks`](#setup-and-checks): the start of every CI job
  - [Caches](#caches): saved on main only, restored everywhere
  - [`tree-check`](#tree-check): skip re-testing a merge that main already holds
- [Renovate presets](#renovate-presets): `github>zendern/gha-shared`
- [Versioning](#versioning)
- [Development](#development)

## GitHub Actions

Composite actions, called as `zendern/gha-shared/<action>@<tag>`. Each caller's
workflow lockfile pins the tag and every action inside it to a commit (see
[Versioning](#versioning)).

### `setup` and `checks`

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
it also sets up Go and restores the Go build and module caches and the `./bin`
cache that Task's `go install` tasks build into (see [Caches](#caches)).
`go-cache-dependency-path` (one glob per line) and `tools-cache-key` cover
modules outside the repository root and jobs that build different tools.

`checks` restores the prek hook cache, runs every prek hook at `PREK_VERSION`, then
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
transitive dependencies; a caller without one runs them by tag. zizmor can't
see a lockfile, so each of those `uses:` lines carries
`# zizmor: ignore[unpinned-uses]`. That covers only steps this repo's own CI
reaches through `$/`, which `ci.yml`'s lockfile pins. A new action, or one no
workflow here calls, is still flagged until it is dogfooded and locked.
`gh actions-lock` keeps the comment when it relocks, including after a tag
bump. If a bump ever drops it, zizmor fails the PR, so it can't go unnoticed.

The gate job (`workflow-summary`) stays in each repo:
it lists the repo's own jobs in `needs:`, which an action can't do.

### Caches

`setup` and `checks` save their caches only from a run on the default branch
(a push, or a scheduled run), and every other run only restores them. A cache
a pull request saves is visible to that pull request alone, while every pull
request can restore the default branch's. GitHub caps a repository at 10 GB
and evicts the oldest caches first, so throwaway PR caches would push out the
ones that matter. `save-cache: true` or `false` on either action overrides the
rule.

| Cache | Key | Fallback on a miss |
| --- | --- | --- |
| Go build and module (`setup`) | `gha-shared-go-<os>-<arch>-go<version>-<job>-<spec>-<go.sum hash>` | newest for the same job and spec, then for the same Go version |
| `./bin` tools (`setup`) | `gha-shared-tools-<tools-cache-key or job>-<os>-<arch>-go<version>-<go-version-file + Taskfile.yml hash>` | none |
| prek hooks (`checks`) | `gha-shared-prek-<os>-<arch>-<prek version>-<config hash>` | newest for the same prek version; `prek cache gc` trims it before a save |

The Go fallback is what makes a dependency bump cheap: Go looks up each
compiled package by its content, so a cache built against older dependencies
recompiles only the packages that changed. A new Go version starts cold, which
also stops the module cache from piling up old versions.

So CI has to run on the default branch for pull requests to have anything to
restore. A repo whose CI runs on `push` to main gets that for free. A repo
that runs CI on pull requests only should run [`tree-check`](#tree-check) on
push to main with `before-sha`, which re-runs CI exactly when main's caches
need refreshing.

### `tree-check`

Decides whether a commit that landed on main needs CI run on it. CI runs on
pull requests; a workflow on push to main uses this to skip the re-run when
main already holds exactly the tested content and its caches are current:

```yaml
on:
  push:
    branches: [main]

jobs:
  tree-check:
    runs-on: ubuntu-24.04-arm
    permissions:
      contents: read
      checks: read
      actions: read # list main's caches
    outputs:
      tested: ${{ steps.tree.outputs.tested }}
      run-checks: ${{ steps.tree.outputs.run-checks }}
    steps:
      - id: tree
        uses: zendern/gha-shared/tree-check@<tag>
        with:
          merge-sha: ${{ github.sha }}
          before-sha: ${{ github.event.before }}

  test:
    needs: tree-check
    if: ${{ needs.tree-check.outputs.run-checks == 'true' }}
    uses: ./.github/workflows/ci.yml
    with:
      ref: ${{ github.sha }}
```

`tested` is `true` only when the commit's tree equals the head tree of the
merged PR it came from **and** the most recent gate check (`check-name`,
default `workflow-summary`) on that head succeeded. An earlier success doesn't
count once a later re-run failed, and a check still in progress doesn't count
yet. Point `check-name` at an all-green gate job, not at a whole-run
conclusion: a run whose jobs were all skipped (draft PRs, title edits) still
concludes `success`. A commit no merged PR produced (a direct push) is
untested.

`run-checks` is `true` when the commit is untested, or, with `before-sha`, when
the push changed a file the shared [caches](#caches) are keyed on
(`cache-files`: go.sum, go.mod, go.work, Taskfile.yml and the prek configs) or
main has no `gha-shared-` caches left, for example after GitHub evicted them.
Running CI on main then re-saves them. A merge that changes none of those
files bills only `tree-check`.

Run on push, not on `pull_request: closed`: a run started by a pull_request
event saves caches under the PR's ref, where no other PR can restore them. The
`pull_request: closed` form still works (pass `head-sha` and leave out
`before-sha`; `run-checks` is then the inverse of `tested`), but it never
refreshes main's caches.

A gate that must hold for a release should require `checks` to succeed, or to
be skipped with `tested == 'true'`, so a failed cache-refresh run blocks it.

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

## Versioning

Callers reference a release tag (`zendern/gha-shared/setup@v2.1.0`), and their
workflow lockfile pins it to a commit. Renovate's github-actions manager bumps
the tag and relocks.

Merging to `main` releases automatically, once the merge is known checked: the
`merged` workflow runs on the push to `main`, calls [`tree-check`](#tree-check),
and re-runs `ci.yml`'s checks on the commit when `main` moved under the PR or
its caches need refreshing. Its `release` job then runs
[svu](https://github.com/caarlos0/svu) over the
[Conventional Commits](https://www.conventionalcommits.org/) since the last
tag: a `fix` is a patch, a `feat` a minor, a breaking change (`!` or
`BREAKING CHANGE`) a major. Other types release nothing, unless they change a
shipped file (`setup`, `checks`, `tree-check`, `default.json`), which is at
least a patch. `task next-version` prints what merging the current branch would
release. Releases are immutable: a published tag can't be moved or deleted, so
a bad release is fixed by the next one.

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
