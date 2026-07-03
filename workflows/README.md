# Per-workflow release packages

Each directory here is the [release-please](https://github.com/googleapis/release-please)
package for the reusable workflow of the same name at `.github/workflows/<name>.yml`.
The workflow YAML itself cannot live here — GitHub requires reusable workflows to sit
flat in `.github/workflows/` — so these directories hold only release metadata:

- `version.txt` — current released version (managed by release-please)
- `CHANGELOG.md` — per-workflow changelog (managed by release-please)
- `workflow.sha256` — checksum of the workflow file (managed by `scripts/sync-workflow-checksums.sh`)

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

CI (`repo-checks.yml`) fails any PR where a checksum is stale, a package directory
is orphaned, or the release-please config/manifest don't match the workflow
inventory — so the invariant can't silently rot.

See the [Versioning & releases](../README.md#versioning--releases) section of the
main README for the full policy and consumer pinning guidance.
