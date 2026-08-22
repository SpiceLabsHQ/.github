# Per-workflow release packages

Each directory here is the [release-please](https://github.com/googleapis/release-please)
package for the reusable workflow of the same name at `.github/workflows/<name>.yml`.
The workflow YAML itself cannot live here — GitHub requires reusable workflows to sit
flat in `.github/workflows/` — so these directories hold only release metadata:

- `version.txt` — current released version (managed by release-please)
- `CHANGELOG.md` — per-workflow changelog (managed by release-please)
- `workflow.sha256` — checksum of the workflow file (managed by `scripts/sync-workflow-checksums.sh`)
- `pins.yml` — mirror of the workflow's Renovate-visible dependencies (also managed by
  `scripts/sync-workflow-checksums.sh`). Present and tracked for all twelve workflows
  since DEV-1314. The sync script rewrites them in place, so re-running it on a clean
  tree changes nothing.

## Why `workflow.sha256` exists (do not delete)

release-please assigns commits to packages by **directory path prefix** — it has no
way to route a commit that only touches `.github/workflows/secret-scan.yml` to the
`workflows/secret-scan` package. The checksum file is the routing bridge: every
change to a workflow file must be accompanied by its regenerated checksum, which
places the commit inside the package directory and lets release-please version,
changelog, and tag that workflow independently.

**After editing any reusable workflow, run:**

```bash
scripts/sync-workflow-checksums.sh
```

CI (`repo-checks.yml`) fails any PR that changes a reusable workflow — or a file it
ships, such as `pepper-pr-review`'s prompts — without also changing something under
`workflows/<name>/`, so the routing can't silently rot. It also fails any PR that
leaves a package directory orphaned, or the release-please config/manifest not
matching the workflow inventory.

What CI does **not** assert is that a stored checksum is current. Nothing reads the
hash — it exists so that running the sync script produces a file inside the package
directory — so a checksum whose workflow was last touched by a bot bump can sit
stale on `main` indefinitely. That is expected. Enforcing the hash repo-wide meant
one stale file failed every unrelated open PR.

## Why `pins.yml` exists (do not edit by hand)

`workflow.sha256` is how a **human** routes a workflow edit: run the script, commit
the file. `pins.yml` is how a **bot** does it with nobody watching — live for all
twelve workflows since DEV-1314.

Renovate is pointed at `workflows/*/pins.yml` by `managerFilePatterns` in
[`.github/renovate.json`](../.github/renovate.json), so each dependency is managed in
two places at once — the workflow YAML and this mirror inside the package directory.
Nothing syncs the two files to each other; both are simply managed, so a single bump
PR edits both and the bot's own commit lands inside `workflows/<name>/` and routes.
Without it, a bump would touch only `.github/workflows/<name>.yml`, reach no package,
cut no release, and leave every repo pinned to the moving `<name>-vN` alias sitting on
the old action.

That is why the mirror has to be **complete**, and "complete" is broader than the
SHA-pinned third-party actions — broader, in fact, than the `uses:` lines. Renovate's
`github-actions` manager runs **two** extraction passes over every file: a line regex,
which is where plain `uses:` action refs come from, and a real YAML parse, which is
where `runs-on`, `container`, `services` and `uses-with` deps come from. So the mirror
carries:

- every `uses:` ref, including first-party major tags — `actions/checkout@v7` is
  bumpable (`v7` → `v8`) exactly like a pinned SHA is;
- the `with:` values Renovate reads as versions — `python-version` on
  `actions/setup-python`, `node-version`, `go-version`, and the version input of each
  community action Renovate knows. `sast.yml`'s `python-version: "3.14"` is one of
  these, and it is a real dep with a real datasource.

Local refs (`uses: ./.github/actions/foo`) are the one deliberate exclusion — they
carry no version and no datasource, so Renovate can never bump them. Everything else in
a `with:` block is configuration Renovate never reads, and is left out so secrets,
tokens and multi-line prompts do not get copied into a committed file.

There is one **known limitation**: a `pins.yml` cannot mirror a `runs-on:`,
`container:` or `services:` dependency, because those live under a `jobs:` key and
giving this file a `jobs:` key would manufacture a runner dependency with no twin in
any workflow. `runs-on: ubuntu-latest` is not affected (Renovate skips it as
`invalid-version`), but `runs-on: ubuntu-24.04` would be — so the generator warns
loudly if a workflow ever grows one.

GitHub Actions never executes `pins.yml`. The composite-action shape is deliberate for
that same reason: its schema has no runner, container or service concept, so the file
cannot acquire a dependency no workflow actually has.

Staleness is checked by `scripts/sync-workflow-checksums.sh --check` — which nothing in
CI runs today, so this is a check you perform, not one that performs itself. It is
deliberately **not** part of the PR gate: a stale mirror is whole-repo drift, and letting
whole-repo drift fail PRs that touched none of it is the DEV-726 mistake.
(`repo-checks.yml` does run a diff-scoped agreement step over the pins files a PR
actually touches, which is a different thing from re-running `--check` repo-wide.)
A *missing* `pins.yml` is only a warning: it degrades to the pre-`pins.yml` world,
where the consequence shows up loudly as a red routing check on the bot PR itself.

See the [Versioning & releases](../README.md#versioning--releases) section of the
main README for the full policy and consumer pinning guidance.
