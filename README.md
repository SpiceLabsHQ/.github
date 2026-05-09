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
