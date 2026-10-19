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

- `github>zendern/gha-shared`: weekly schedule, and no updates to existing PRs
  outside it (`updateNotScheduled: false`).
- `github>zendern/gha-shared:majors-approval`: major updates wait for approval
  on the Dependency Dashboard.

## Versioning

Callers pin a full commit SHA with the tag as a comment. Tag releases `vX.Y.Z`
so Renovate's github-actions manager can bump the pins.
