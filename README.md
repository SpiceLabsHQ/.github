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
