# .github

Organization-level defaults for [SpiceLabsHQ](https://github.com/SpiceLabsHQ). The `profile/README.md` is what shows on the org's GitHub page.

## Reusable workflows

### Pepper PR Review (`pepper-pr-review.yml`)

Pepper is the SpiceLabs PR review bot, powered by Claude Sonnet 4.5 on AWS Bedrock. The reusable workflow is centrally maintained here; each repo opts in with a ~15-line caller workflow and (optionally) carries its own review standards file.

**Naming legend:** workflow display name is **Pepper PR Review**, status check appears as **Pepper PR Review / Pepper review**, and humans invoke on-demand mode by typing `@pepper` in a PR comment.

The bot operates in two modes:

- **Auto-review** (PR opened / ready_for_review): performs a full review and chooses one of three outcomes — formal approve, formal request-changes, or comment-with-reviewer-assignment. Read-only on the filesystem.
- **On-demand** (`@pepper` mention in a PR comment): treats the comment as a task and can edit files + push commits to the PR branch to satisfy the request.

**1. Add the caller workflow** to each repo at `.github/workflows/pepper-pr-review.yml`. Copy-paste-ready version at [`examples/caller-pepper-pr-review.yml`](examples/caller-pepper-pr-review.yml).

**2. (Optional) Add repo-specific review standards** at `.pepper/pr-review-standards.md`. The reusable workflow auto-detects the file and substitutes it into the review prompt's `<project_specific_guidelines>` block (overriding org defaults on conflict). Absent file → org defaults only. `CLAUDE.md` is also picked up because the action runs in the checked-out workspace.

**3. Inputs** (all optional, override via `with:`):

| Input | Default | Notes |
|---|---|---|
| `model` | `us.anthropic.claude-sonnet-4-5-20250929-v1:0` | Bedrock inference profile or model ID |
| `aws_region` | `us-west-2` | Bedrock region |
| `trigger_phrase` | `@pepper` | Comment phrase that triggers on-demand mode |
| `standards_path` | `.pepper/pr-review-standards.md` | Override if your repo stores standards elsewhere |
| `default_reviewer` | `brodkin` | Fallback reviewer login when no other collaborator qualifies for assignment |
| `show_full_output` | `false` | When `true`, Pepper's tool calls + reasoning + tool results stream into Actions logs. Useful for diagnosing permission denials or wasted turns. **Public-repo callers: anyone who can see the Actions run sees the full output** — use only on debug branches |

**4. Required secrets** (set once at the org level — they don't auto-inherit, the caller passes them explicitly):

| Secret | Purpose |
|---|---|
| `AWS_CLAUDE_BEDROCK_ROLE_ARN` | Shared AWS role assumed via OIDC for Bedrock. Used by Pepper and any other Claude-on-Bedrock workload at the org |
| `PEPPER_PR_REVIEW_APP_ID` | GitHub App ID for the **Pepper PR Review** App. Required because `GITHUB_TOKEN` cannot approve PRs — the workflow mints an installation token from the App for formal approve / request-changes calls |
| `PEPPER_PR_REVIEW_APP_PRIVATE_KEY` | PEM private key for the same App |

**5. Optional secret:**

| Secret | Effect when set |
|---|---|
| `LINEAR_API_KEY` | Workflow exposes the key as env to the action; prompt instructs Pepper to fetch the linked Linear issue (detected from branch name or PR title) and verify the PR's scope against it |

**6. Bulk rollout:** `scripts/rollout-pepper-pr-review.sh` opens an adoption PR in every non-archived org repo. Defaults to dry-run; pass `--apply` to actually create PRs.

**Versioning:** Callers pin the reusable workflow with `@v1`; the reusable workflow pins the underlying `anthropics/claude-code-action` ref. Action upgrades happen in one place.

### Actions Audit (`actions-audit.yml`)

Audits a calling repo's `.github/workflows/**` for supply-chain risk. Two layers:

1. **zizmor static analysis** — runs [zizmor](https://github.com/zizmorcore/zizmor) against the workflows, surfacing dangerous GHA patterns (template injection, excessive `GITHUB_TOKEN` permissions, pwn requests, self-hosted runner misuse, etc.). Findings at or above `min_severity` fail the job. SARIF is uploaded to the Security tab so issues persist across runs.
2. **SHA-pin enforcement** — every `uses:` referencing a third-party action must be pinned to a 40-char commit SHA. Owner globs in `allow_tags_for` may use major-version tags (e.g. `actions/checkout@v4`). Implemented as a small inline shell script — no new third-party action just for this check.

The reusable workflow leads by example: every third-party action it invokes is pinned to a 40-char SHA. First-party `actions/*` and `github/*` use major tags.

**1. Add the caller workflow** to each repo at `.github/workflows/actions-audit.yml`. Copy-paste-ready version at [`examples/caller-actions-audit.yml`](examples/caller-actions-audit.yml).

### Dependency Review (`dependency-review.yml`)

Wraps [`actions/dependency-review-action`](https://github.com/actions/dependency-review-action) with org-standard severity threshold and license policy. Designed to fail PRs that introduce (a) dependencies with CVEs at/above the configured severity, or (b) dependencies carrying denied licenses.

**1. Add the caller workflow** to each repo at `.github/workflows/dependency-review.yml`. Copy-paste-ready version at [`examples/caller-dependency-review.yml`](examples/caller-dependency-review.yml).

**2. Inputs** (all optional, override via `with:`):

| Input | Default | Notes |
|---|---|---|
| `min_severity` | `medium` | zizmor severity threshold. One of `low`, `medium`, `high`. Findings at or above this level fail the job |
| `allow_tags_for` | `actions/*,github/*` | Comma-separated owner globs allowed to use tags instead of SHA pins. Add e.g. `aws-actions/*` if you trust other publishers |

**3. Required permissions** (caller declares them in its job block — see the example):

| Permission | Purpose |
|---|---|
| `contents: read` | Checkout the caller repo |
| `security-events: write` | Upload zizmor SARIF to the Security tab |
| `actions: read` | Lets zizmor read workflow metadata for some audits |

**4. No secrets required.** The audit runs entirely against the caller's checked-out workspace and uses `GITHUB_TOKEN` for SARIF upload.

**Versioning:** Callers pin with `@v1`. The reusable workflow pins zizmor to an exact version (`ZIZMOR_VERSION` env in the workflow) so audit results are reproducible across runs.

### PR Hygiene (`pr-hygiene.yml`)

Two PR checks bundled into one reusable workflow. Drop the [caller workflow](examples/caller-pr-hygiene.yml) into any repo at `.github/workflows/pr-hygiene.yml`.

- **Conventional Commits title check (blocking).** Enforces a [Conventional Commits](https://www.conventionalcommits.org/) header on the PR title — required so `release-please` can classify the change at squash-merge time. On failure the workflow posts a sticky comment with a fix example; the comment is deleted automatically once the title is corrected.
- **Large-PR size warning (non-blocking).** Posts an informational sticky comment when additions + deletions exceed the soft threshold. The check exits 0 either way — branch protection should not require it.

**Inputs** (all optional, override via `with:`):

| Input | Default | Notes |
|---|---|---|
| `types` | `feat,fix,chore,docs,refactor,test,build,ci,perf,style,revert` | Comma-separated allowed CC types (converted internally to the action's newline format) |
| `require_scope` | `false` | When `true`, PR titles must include a scope, e.g. `feat(api): ...` |
| `large_pr_threshold` | `500` | Changed-lines threshold (additions + deletions) for the soft size warning |

No secrets needed. The caller passes `permissions: { contents: read, pull-requests: write }` so the workflow can read the PR payload and post the sticky comments.

### Secret Scan (`secret-scan.yml`)

Gitleaks-based scanner for repo secrets, layered to catch what GitHub's native push-protection misses (custom token formats, secrets that already landed in history). The reusable workflow drives `gitleaks/gitleaks-action` in two complementary modes; callers wire each mode to the appropriate triggers.

The two modes:

- **`pr-diff`** (fast): scans only the lines a PR changes. Findings post as inline review comments on the PR. Run on every `pull_request` for sub-minute author feedback.
- **`full-history`** (slow): scans the entire git history. Run on `push` to the default branch and on a weekly cron. Catches secrets that pr-diff can't see — e.g., committed and "fixed" within the same PR (the secret is still in history forever) or committed before the repo adopted scanning.

**1. Add the caller workflow** to each repo at `.github/workflows/secret-scan.yml`. Copy-paste-ready version at [`examples/caller-secret-scan.yml`](examples/caller-secret-scan.yml). The example wires up all three triggers (PR, push to main, weekly cron) as separate jobs that select the right mode.

**2. (Optional) Add a Gitleaks config** at `.gitleaks.toml` for repo-specific custom rules and allowlists. The reusable workflow auto-detects the file; absent file → Gitleaks built-in default ruleset.

### CodeQL (`codeql.yml`)

Reusable wrapper around GitHub's first-party `github/codeql-action` for deep static analysis. Auto-detects supported languages, runs the `security-extended` query suite by default, scans the PR diff on `pull_request` events and the full repo on `push` / `schedule`, and uploads SARIF to the Security tab.

> **GHAS requirement:** **Private repos require [GitHub Advanced Security (GHAS)](https://docs.github.com/en/get-started/learning-about-github/about-github-advanced-security)**. Without GHAS, the SARIF-upload step inside `analyze@v3` returns 403. Public repos work without GHAS — Code Scanning is free for public repos. If your private repo can't enable GHAS, use [`sast.yml`](#sast-semgrep-sastyml) (Semgrep-based) instead.

**1. Add the caller workflow** to each repo at `.github/workflows/codeql.yml`. Copy-paste-ready version at [`examples/caller-codeql.yml`](examples/caller-codeql.yml). Triggers: every PR (diff-scoped), every push to `main` (full repo), and weekly on Mondays.

**2. Auto-detected languages:** the workflow probes the worktree for source files and emits one matrix job per detected language. CodeQL language IDs: `javascript-typescript`, `python`, `go`, `java-kotlin`, `csharp`, `ruby`, `swift`, `cpp`. JS+TS share a single `javascript-typescript` analyzer; Java+Kotlin share `java-kotlin`. No caller configuration needed for the common cases.

**3. Inputs** (all optional, override via `with:`):

| Input | Default | Notes |
|---|---|---|
| `mode` | `pr-diff` | `pr-diff` (PR diff only, inline review comments) or `full-history` (entire git history) |
| `config_path` | `.gitleaks.toml` | Path to a Gitleaks config file. Tolerated absent — falls back to built-in defaults |

**4. Optional secret:**

| Secret | Effect when set |
|---|---|
| `GITLEAKS_LICENSE` | Required by `gitleaks-action@v2` for repos under an **organization** account; not required for personal-account repos. Pass via `secrets: inherit` (simplest) or explicitly as `GITLEAKS_LICENSE: ${{ secrets.GITLEAKS_LICENSE }}`. If absent and the repo is under an org, the action fails fast with its own diagnostic — that's intentional, do not silently no-op a secret scanner |

**Versioning:** Callers pin the reusable workflow with `@v1`; the reusable workflow pins `gitleaks/gitleaks-action` to a 40-char SHA. Action upgrades happen in one place.

### Release Please (`release-please.yml`)

[`googleapis/release-please-action`](https://github.com/googleapis/release-please-action) wrapped as a reusable workflow. Listens on push to the default branch, ingests Conventional Commits since the last tag, and maintains a single rolling **release PR** that bumps the version in every file the consuming repo declares. Merging that PR cuts a tag and a GitHub Release — which is the trigger point for `release-artifacts.yml` (DEV-223).

**1. Add the caller workflow** at `.github/workflows/release-please.yml` (copy-paste-ready: [`examples/caller-release-please.yml`](examples/caller-release-please.yml)).

**2. Add a release-please config** at the repo root.

> **The config file is parsed as strict JSON.** release-please reads it via `JSON.parse()` — no comments, no trailing commas, no JSON5/JSONC tolerance. The starter examples below are pure JSON; do not add `//` lines when copying them. Ditto for the manifest file (see step 3) — release-please rewrites the manifest on every run and would silently strip any comments anyway.

Single-package starter ([`examples/release-please-config.json`](examples/release-please-config.json)):

```json
{
  "$schema": "https://raw.githubusercontent.com/googleapis/release-please/main/schemas/config.json",
  "release-type": "node",
  "include-component-in-tag": false,
  "separate-pull-requests": false,
  "packages": {
    ".": {
      "package-name": "my-app",
      "extra-files": [
        "src/version.ts",
        {
          "type": "json",
          "path": "packages/cli/package.json",
          "jsonpath": "$.version"
        }
      ]
    }
  },
  "plugins": []
}
```

The `"."` key means "the repo root" — manifest mode requires every package to be listed here, even single-package repos. `release-type: node` covers most JS/TS repos (bumps `package.json`, generates `CHANGELOG.md`, tags as `v<semver>`); other common values are `python`, `rust`, `go`, and `simple`. The two `extra-files` entries above demonstrate the two shapes you'll reach for most: an inline-marker file (release-please rewrites the line tagged `x-release-please-version`) and a JSON+JSONPath bump for a sibling `package.json`. Step 6 below covers the remaining marker forms.

Monorepo starter ([`examples/release-please-config.monorepo.json`](examples/release-please-config.monorepo.json)):

```json
{
  "$schema": "https://raw.githubusercontent.com/googleapis/release-please/main/schemas/config.json",
  "separate-pull-requests": false,
  "include-component-in-tag": true,
  "packages": {
    "packages/api": {
      "release-type": "node",
      "package-name": "@example/api",
      "extra-files": [
        { "type": "yaml", "path": "packages/api/openapi.yaml", "jsonpath": "$.info.version" },
        { "type": "yaml", "path": "deploy/api/values.yaml", "jsonpath": "$.image.tag" }
      ]
    },
    "packages/web": {
      "release-type": "node",
      "package-name": "@example/web",
      "extra-files": [
        "packages/web/src/version.ts",
        { "type": "yaml", "path": "deploy/web/values.yaml", "jsonpath": "$.image.tag" }
      ]
    },
    "packages/shared": {
      "release-type": "node",
      "package-name": "@example/shared"
    }
  },
  "plugins": ["node-workspace"]
}
```

Two flags shape the monorepo behavior. `separate-pull-requests: false` keeps a single rolling release PR for the repo (flip to `true` if reviewers prefer one PR per package — the trade-off is more open PRs at any given moment). `include-component-in-tag: true` produces unambiguous tags like `api-v1.2.3`, `web-v0.5.0`. The `node-workspace` plugin keeps internal dependencies in sync — when `api` bumps `shared`, the plugin updates `api/package.json`'s dependency on `@example/shared` so the workspace install resolves to the new version. Drop the plugin for non-Node monorepos (`cargo-workspace` is the Rust analogue; Go/Python have no equivalent).

**3. Add the manifest** at the repo root as `.release-please-manifest.json`. release-please rewrites it on every release; do NOT add comments — they would be silently dropped. [`examples/.release-please-manifest.json`](examples/.release-please-manifest.json) shows the multi-key (monorepo) shape:

```json
{
  "packages/api": "0.0.0",
  "packages/web": "0.0.0",
  "packages/shared": "0.0.0"
}
```

For a single-package repo, use the single-key form instead: `{".": "0.0.0"}`. **The keys here MUST exactly match the `packages` keys in your config file.** A typo (`packages/api` vs `packages/api/`) silently no-ops for that package on every run; release-please does not warn.

**4. Inputs** (all optional, override via `with:`):

| Input | Default | Notes |
|---|---|---|
| `config_file` | `release-please-config.json` | Path to the release-please config |
| `manifest_file` | `.release-please-manifest.json` | Path to the manifest. Auto-rewritten by the action |
| `target_branch` | `main` | Branch the release PR opens against; pair with the caller's `on.push.branches` |

**5. Token strategy — pick one:**

| Path | Setup | Behavior |
|---|---|---|
| `GITHUB_TOKEN` (default) | Empty `secrets:` block in caller | Release PR + tag are created, but **the tag-push event does not trigger downstream workflows**. GitHub deliberately suppresses event cascades from `GITHUB_TOKEN` to prevent recursion |
| GitHub App | Set `RELEASE_APP_ID` + `RELEASE_APP_PRIVATE_KEY` org secrets, pass them through | PR + tag authored by the App. Downstream `push: tags:` workflows (release-artifacts.yml) **do** fire |

Repos that depend on the release-artifacts pipeline must use the GitHub App path. The App needs `contents: write` and `pull-requests: write` on the org's repos.

**6. Marker syntax for generic files:**

For files release-please doesn't understand structurally (Dockerfile, README, .ts, .py), tag the line with an inline marker:

```ts
// In src/version.ts
export const VERSION = "0.0.0"; // x-release-please-version
```

Or wrap a block (useful for README badges):

```markdown
<!-- x-release-please-start-version -->
0.0.0
<!-- x-release-please-end -->
```

**7. Bootstrap behavior (`bootstrap-sha`):**

When you onboard a repo with existing history, the first release PR scans every commit on the target branch since the beginning of time. For repos with months or years of pre-release-please history, the resulting changelog is unmanageable. `bootstrap-sha` tells release-please to ignore commits at-or-before that SHA on the very first run only — subsequent runs use the last release tag as the lower bound and ignore the field. Pick the commit just before you want release-please to start tracking.

Add it as a top-level sibling to `packages` and `plugins`:

```json
{
  "$schema": "https://raw.githubusercontent.com/googleapis/release-please/main/schemas/config.json",
  "release-type": "node",
  "bootstrap-sha": "0000000000000000000000000000000000000000",
  "packages": {
    ".": { "package-name": "my-app" }
  },
  "plugins": []
}
```

You can drop the field once the first release PR has merged; release-please ignores it after that.

**8. Sharp edges:**

- **Manifest mode is sticky.** Once you've onboarded with a manifest, you can't switch back to non-manifest mode without manual cleanup. Manifest is the path forward for any new repo regardless.
- **Manifest keys must match config keys exactly.** A typo (`packages/api` vs `packages/api/`) will silently no-op for that package on every run.
- **The config and manifest are strict JSON.** No comments, no trailing commas. release-please uses raw `JSON.parse()` and a parse failure aborts the whole run — no release PR opens until the file is fixed.
- **Versioning:** Callers pin the reusable workflow with `@v1`; the reusable workflow SHA-pins both `googleapis/release-please-action` and `actions/create-github-app-token`. Action upgrades happen in one place.

| `languages` | (empty → auto-detect) | Comma-separated CodeQL language IDs to override auto-detect. Use the IDs listed above |
| `query_suite` | `security-extended` | One of `default`, `security-extended`, `security-and-quality`. Pick `security-and-quality` if you want lint-style code-quality findings alongside security findings |
| `build_command` | (empty) | Custom shell command to build compiled-language sources (Java/Kotlin, C#, C/C++, Swift) when CodeQL's `autobuild` can't figure out your project. Empty → autobuild for compiled languages, no-op for interpreted languages |

**4. No secrets required.** SARIF upload uses the standard `GITHUB_TOKEN` with `security-events: write`.

**Versioning:** Callers pin the reusable workflow with `@v1`; the reusable workflow pins `github/codeql-action` to `@v3`. Engine upgrades happen in one place.

### OpenSSF Scorecard (`scorecard.yml`)

Internal Scorecard scan: runs the [OpenSSF Scorecard](https://scorecard.dev) against the calling repo on a weekly schedule and uploads the SARIF findings to GitHub Code Scanning so they appear in the repo's **Security** tab. Raw SARIF is also kept as a workflow artifact for 30 days.

**Scope:** This workflow is intentionally scoped to **internal use only**. It does not publish to OpenSSF's public dashboard at [scorecard.dev](https://scorecard.dev) — Spice Labs doesn't currently ship public OSS that would benefit from the public badge, and the publish path requires `id-token: write` plus a strict step allowlist that this workflow doesn't satisfy. If Spice Labs ever ships public OSS, add a separate public-Scorecard workflow that meets Scorecard's `post_results.go` requirements; don't extend this one.

**1. Add the caller workflow** to each repo at `.github/workflows/scorecard.yml`. Copy-paste-ready version at [`examples/caller-scorecard.yml`](examples/caller-scorecard.yml).

**2. Scheduling lives in the caller, not the reusable workflow.** GitHub's `workflow_call` mechanism can't dictate a `schedule:` to its parent, so the example caller wires the cron itself (default: Monday 06:00 UTC). Adjust to taste — staggering across repos avoids hitting Scorecard's analysis runners at the same minute. The caller also wires `workflow_dispatch` (for ad-hoc runs) and `branch_protection_rule` (Scorecard's preferred trigger so the Branch-Protection check re-scores immediately when protection settings change).

**3. Inputs:** None. The reusable workflow always runs Scorecard, emits SARIF, uploads it to Code Scanning, and stashes the raw SARIF as an artifact. There's nothing to configure per-call.

**4. Required permissions on the calling job:**

| Permission | Why |
|---|---|
| `contents: read` | Scorecard reads repo files, branch protection, releases |
| `security-events: write` | SARIF upload to Code Scanning |
| `actions: read` | Scorecard's Token-Permissions / Pinned-Dependencies checks read workflow files via the Actions API |

`id-token: write` is intentionally **not** required — this workflow doesn't sign or upload anything to the public dashboard, so OIDC issuance is unnecessary. Granting it would expose a high-impact cloud-auth primitive on every weekly run for no functional benefit.

No secrets required — Scorecard runs entirely with the workflow's own `GITHUB_TOKEN`.

**Versioning:** Callers pin with `@v1`. The reusable workflow SHA-pins `ossf/scorecard-action` to the latest stable tag (currently v2.4.3) and tracks `actions/*` and `github/*` at major-version tags per the actions-audit policy.

| `fail_on_severity` | `high` | Minimum CVE severity that fails the check. One of `low`, `moderate`, `high`, `critical` |
| `deny_licenses` | `GPL-2.0,GPL-3.0,AGPL-1.0,AGPL-3.0,LGPL-2.0,LGPL-2.1,LGPL-3.0` | Comma-separated SPDX identifiers denied org-wide. See **License policy rationale** below |
| `allow_licenses` | _(empty)_ | Optional allow-list. When non-empty, the action switches to allow-list mode and `deny_licenses` is ignored — see precedence below |
| `comment_summary_in_pr` | `true` | Post the action's built-in vulnerability + license summary as a PR comment |

**License policy rationale:** Spice Labs maintains All Rights Reserved on its own code. The default `deny_licenses` blocks all GPL/AGPL/LGPL variants because their copyleft obligations would force giving up the ARR posture if a covered dependency were linked into a SpiceLabs product. The default explicitly enumerates all seven copyleft variants the dependency-review-action will currently see in the wild:

- `GPL-2.0`, `GPL-3.0` — strong copyleft
- `AGPL-1.0`, `AGPL-3.0` — strong copyleft, network-use trigger
- `LGPL-2.0`, `LGPL-2.1`, `LGPL-3.0` — weak copyleft

LGPL is included in the default deny list because dynamic-linking compliance is hard to guarantee in SaaS / containerized deployments. Repos with audited LGPL deps and a clean dynamic-linking story can override via `allow_licenses` (or by passing a narrower `deny_licenses`).

**Precedence — `allow_licenses` vs `deny_licenses`:** `actions/dependency-review-action` rejects callers that pass both at once. When `allow_licenses` is set the reusable workflow drops `deny_licenses`, putting the action into allow-list mode (stricter — only listed licenses pass). When `allow_licenses` is empty the org-default deny-list applies. To override the deny-list, pass your own `deny_licenses` value; to switch policies entirely, set `allow_licenses`.

**Misuse warning:** The reusable workflow's silent drop of `deny_licenses` when both inputs are set could mask a caller mistake, so it emits a `::warning::` to the Actions log when both `allow_licenses` and `deny_licenses` are non-empty. The warning records that `deny_licenses` was ignored and asks the caller to pass only one.

**3. Required permissions** in the caller (already shown in the example):

```yaml
permissions:
  contents: read
  pull-requests: write   # only used when comment_summary_in_pr is true
```

**4. Requirements:** Dependency Review API is free on public repos. On private repos it requires GitHub Advanced Security.

**Versioning:** Callers pin the reusable workflow with `@v1`; the reusable workflow SHA-pins the underlying `actions/dependency-review-action` ref. Action upgrades happen in one place.
