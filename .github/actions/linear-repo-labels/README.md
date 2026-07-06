# Sync Linear repo labels

A composite GitHub Action that keeps a **Linear label group** in sync with the
repositories of a GitHub **org or user**. Point it at an owner and a group name;
every repo becomes a label in that group.

Its defining feature: **renames don't lose issues.** Each label's Linear
`description` carries the repository's immutable numeric GitHub ID
(`gh-repo-id:<id>`). Reconciliation keys on that ID, never on the name — so when
a repo is renamed, the existing label is **updated in place** and every issue
tagged with it stays tagged. Only genuinely deleted repos are ever pruned.

## Usage

```yaml
jobs:
  sync:
    runs-on: ubuntu-latest
    steps:
      # Pin to a commit SHA (see "Versioning" below — there is no `@v1` for this action).
      - uses: SpiceLabsHQ/.github/actions/linear-repo-labels@<commit-sha>
        with:
          linear-api-key: ${{ secrets.LINEAR_API_KEY }}
          github-token: ${{ secrets.ORG_REPO_READ_TOKEN }}   # see "Tokens" below
          owner: your-org-or-username
          group-name: repo
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
- uses: SpiceLabsHQ/.github/actions/linear-repo-labels@<full-commit-sha>
```

A commit SHA is the repo's strongest, recommended pin anyway. Internal callers
may use `@main` for hands-off updates, accepting that it moves.

## Inputs

| Input | Default | Description |
|---|---|---|
| `linear-api-key` | — (required) | Linear personal API key or OAuth token with label read/write. Sent verbatim as the `Authorization` header — **do not** prefix with `Bearer`. |
| `github-token` | `${{ github.token }}` | Token used to **list the owner's repos**. The default `GITHUB_TOKEN` only sees the current repo — supply a PAT or App token to enumerate an org/user (see Tokens). |
| `owner` | `${{ github.repository_owner }}` | The org or user login whose repositories become labels. |
| `group-name` | `repo` | Name of the Linear label group to create and maintain. **Set this per runner** to maintain more than one group. |
| `team` | `''` (workspace) | Linear team key/name to scope the group to. Empty = workspace-level group. |
| `lowercase` | `true` | Lowercase repo names when writing them as labels. |
| `include-forks` | `true` | Include forked repositories. |
| `include-archived` | `false` | Include archived repositories. |
| `prune` | `report` | What to do with a managed label whose repo is gone: `report` (log only — safest), `archive` (soft-delete, recoverable), or `delete` (permanent; removes the label from issues). |
| `dry-run` | `false` | Compute and log the plan without mutating Linear. |

## Outputs

`created`, `renamed`, `adopted`, `pruned` — counts from the run. A per-run table
is also written to the job's **step summary**.

## How reconciliation works

For every repo, matched to a label **by GitHub ID**:

| Situation | Action |
|---|---|
| ID match, name matches | no-op |
| **ID match, name differs** | **rename the label in place — issues preserved** |
| No ID match, but a label with that name exists and is unmanaged | **adopt** it (stamp the ID into its description) |
| No match at all | create the label under the group |
| Label's ID no longer maps to any repo | prune per `prune` mode |

**Bootstrapping:** labels you created by hand are adopted on the first run
(matched by name, then stamped with their repo ID). Nothing is recreated or lost.

**Source of truth:** GitHub wins. If someone renames a managed label in Linear,
the next run reasserts the GitHub name. That's intentional.

**Conflicts:** if two repos would produce the same (lowercased) label name, the
second is skipped and logged rather than creating a duplicate.

## Tokens

- **Listing an org's repos** needs a token with org repo read. Either a
  fine-grained PAT (Repository access: All repos; Permissions: Metadata → read),
  or a **GitHub App installation token** minted at runtime (recommended for orgs
  — no long-lived secret). The default `GITHUB_TOKEN` is scoped to the current
  repo only and will not see the rest of the org.
- **Listing a personal user's repos** works with a fine-grained PAT
  (Metadata: read) on that account.
- **Linear:** create a personal API key in Linear → Settings → Security & access →
  Personal API keys, and store it as a secret. It **must have write scope** — this
  action creates and updates labels, so a read-only key fails every mutation with
  `Invalid scope: write required`. Because it needs write access, keep it as a
  dedicated secret rather than reusing a shared read-only key (least privilege).

## Requirements

Runs on `ubuntu-latest` (or any runner with `bash`, `gh`, `jq`, and `curl` —
all present on GitHub-hosted Linux runners).
