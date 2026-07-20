# Sync Linear GitHub labels

A composite GitHub Action that keeps a **Linear label group** in sync with a set
of GitHub objects. Two sources are supported:

| `source` | What becomes a label | Example label |
|---|---|---|
| `repos` | every repository of a GitHub org/user | `eng-cookbook` |
| `actions` | every **reusable workflow** (`on: workflow_call`) in one or more repos | `.github/sast` |

Its defining feature: **renames don't lose issues.** Each label's Linear
`description` carries a stable key for the object it mirrors — the repository's
immutable numeric GitHub ID (`gh-repo-id:<id>`), or
`gh-action:<repo-id>:<path>` for a reusable workflow. Reconciliation keys on
that, never on the name — so when the underlying object is renamed, the existing
label is **updated in place** and every issue tagged with it stays tagged. Only
genuinely deleted objects are ever pruned.

## Usage

```yaml
jobs:
  repos:
    runs-on: ubuntu-latest
    steps:
      # Pin to a commit SHA (see "Versioning" below — there is no `@v1` for this action).
      - uses: SpiceLabsHQ/.github/actions/linear-github-labels@<commit-sha>
        with:
          linear-api-key: ${{ secrets.LINEAR_API_KEY }}
          github-token: ${{ secrets.ORG_REPO_READ_TOKEN }}   # see "Tokens" below
          source: repos
          owner: your-org-or-username
          group-name: repo

  org-actions:
    runs-on: ubuntu-latest
    steps:
      - uses: SpiceLabsHQ/.github/actions/linear-github-labels@<commit-sha>
        with:
          linear-api-key: ${{ secrets.LINEAR_API_KEY }}
          github-token: ${{ secrets.ORG_REPO_READ_TOKEN }}
          source: actions
          owner: your-org-or-username
          action-repos: your-org/.github,your-org/other-action-host
          group-name: org-actions
```

Because `SpiceLabsHQ/.github` is public, any org or user can consume the action
via that `uses:` path — no install, no separate infrastructure.

## Versioning

**Pin to a commit SHA.** This action is not (yet) wired into the repo's
component release pipeline — [release-please + the `<name>-vN` tag aliases](../../../README.md#versioning--releases)
cover only the reusable workflows under `workflows/`, so **no tag is ever cut
for anything under `.github/actions/`**. In particular the bare `@v1` tag is
frozen legacy (DEV-404) and does **not** contain this action — it will 404.

Until per-action release tags exist (tracked as a follow-up on
[DEV-518](https://linear.app/spicelabshq/issue/DEV-518)):

```yaml
- uses: SpiceLabsHQ/.github/actions/linear-github-labels@<full-commit-sha>
```

A commit SHA is the repo's strongest, recommended pin anyway. Internal callers
may use `@main` for hands-off updates, accepting that it moves.

## Inputs

| Input | Default | Description |
|---|---|---|
| `linear-api-key` | — (required) | Linear personal API key or OAuth token with label read/write. Sent verbatim as the `Authorization` header — **do not** prefix with `Bearer`. |
| `github-token` | `${{ github.token }}` | Token used to enumerate GitHub. The default `GITHUB_TOKEN` only sees the current repo — supply a PAT or App token to enumerate an org/user (see Tokens). |
| `source` | `repos` | `repos` or `actions` — what becomes a label. |
| `owner` | `${{ github.repository_owner }}` | The org or user login to enumerate. |
| `action-repos` | `<owner>/.github` | **`source=actions` only.** Comma-separated repos to scan. Entries may be `owner/repo` or a bare `repo`. A repo with no `.github/workflows` directory is skipped. |
| `group-name` | `repo` | Name of the Linear label group to create and maintain. **Set this per runner** to maintain more than one group. |
| `team` | `''` (workspace) | Linear team key/name to scope the group to. Empty = workspace-level group. |
| `name-separator` | `/` | **`source=actions` only.** Joins host repo and workflow name (`.github` + `/` + `sast`). |
| `color` | `''` | Hex color applied to labels this action **creates**. Empty = Linear assigns one. Existing labels are never recolored. |
| `lowercase` | `true` | Lowercase names when writing them as labels. |
| `include-forks` | `true` | **`source=repos` only.** Include forked repositories. |
| `include-archived` | `false` | **`source=repos` only.** Include archived repositories. |
| `prune` | `report` | What to do with a managed label whose object is gone: `report` (log only — safest), `archive` (soft-delete, recoverable), or `delete` (permanent; removes the label from issues). |
| `dry-run` | `false` | Compute and log the plan without mutating Linear. |

## Outputs

`created`, `renamed`, `adopted`, `pruned` — counts from the run. A per-run table
is also written to the job's **step summary**.

## How reconciliation works

Every item is matched to a label **by its stable key**, never its name:

| Situation | Action |
|---|---|
| Key match, name matches | no-op |
| **Key match, name differs** | **rename the label in place — issues preserved** |
| No key match, but a label with that name exists and is unmanaged | **adopt** it (stamp the key into its description) |
| No match at all | create the label under the group |
| Label's key no longer maps to any item | prune per `prune` mode |

`plan.jq` implements this and treats the key as an **opaque token**, so adding a
new source needs no change there. The fixture test runs that exact program over
both key formats.

**Bootstrapping:** labels you created by hand are adopted on the first run
(matched by name, then stamped). Nothing is recreated or lost.

**Source of truth:** GitHub wins. If someone renames a managed label in Linear,
the next run reasserts the GitHub name. That's intentional.

**Conflicts:** if two items would produce the same label name, the second is
skipped and logged rather than creating a duplicate. A duplicate-name warning is
also emitted up front, before any mutation.

**Group isolation:** the key pattern is source-specific, so a `repos` run can
never read or prune a label stamped by an `actions` run, even in the same group.

### Caveat: path renames under `source=actions`

A reusable workflow's key includes its path, so **renaming the workflow file
breaks the key** — the old label is reported stale and a new one is created.
This is deliberate: renaming `.github/workflows/sast.yml` is already a breaking
change for every consumer pinning `@sast-v1`, so it's a loud, intentional event
where relabeling by hand is proportionate. Repo renames are still lossless,
because the key carries the repo's numeric ID, not its name.

## Detecting reusable workflows

`detect.sh` decides what counts, using a text heuristic (the runner is
guaranteed `bash`/`grep`/`sed`, but not a YAML processor). It recognizes both
the block form and the inline-list form, and strips comments first so a mention
in prose can't produce a false positive.

Its block-form pattern is deliberately identical to `reusable_workflows()` in
`scripts/sync-workflow-checksums.sh` — this repo's canonical definition, already
CI-enforced 1:1 against the release-please inventory. **If one changes, change
the other.** They can't share code: that one greps local files, this one takes
content fetched over the API from a possibly-remote repo.

## Tokens

- **Listing an org's repos** needs a token with org repo read. Either a
  fine-grained PAT (Repository access: All repos; Permissions: Metadata → read),
  or a **GitHub App installation token** minted at runtime (recommended for orgs
  — no long-lived secret). The default `GITHUB_TOKEN` is scoped to the current
  repo only and will not see the rest of the org.
- **Listing a personal user's repos** works with a fine-grained PAT
  (Metadata: read) on that account.
- **`source=actions`** additionally reads file contents, so the token needs
  Contents → read on each repo in `action-repos`.
- **Linear:** create a personal API key in Linear → Settings → Security & access →
  Personal API keys, and store it as a secret. It **must have write scope** — this
  action creates and updates labels, so a read-only key fails every mutation with
  `Invalid scope: write required`. Because it needs write access, keep it as a
  dedicated secret rather than reusing a shared read-only key (least privilege).

## Tests

```bash
.github/actions/linear-github-labels/test/plan_test.sh    # reconciliation branches, both key formats
.github/actions/linear-github-labels/test/detect_test.sh  # reusable-workflow detection
```

Both run in CI on any PR touching this action (`.github/workflows/linear-labels-test.yml`).

## Requirements

Runs on `ubuntu-latest` (or any runner with `bash`, `gh`, `jq`, `curl`, and
`base64` — all present on GitHub-hosted Linux runners).
