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

### Secret Scan (`secret-scan.yml`)

Gitleaks-based scanner for repo secrets, layered to catch what GitHub's native push-protection misses (custom token formats, secrets that already landed in history). The reusable workflow drives `gitleaks/gitleaks-action` in two complementary modes; callers wire each mode to the appropriate triggers.

The two modes:

- **`pr-diff`** (fast): scans only the lines a PR changes. Findings post as inline review comments on the PR. Run on every `pull_request` for sub-minute author feedback.
- **`full-history`** (slow): scans the entire git history. Run on `push` to the default branch and on a weekly cron. Catches secrets that pr-diff can't see — e.g., committed and "fixed" within the same PR (the secret is still in history forever) or committed before the repo adopted scanning.

**1. Add the caller workflow** to each repo at `.github/workflows/secret-scan.yml`. Copy-paste-ready version at [`examples/caller-secret-scan.yml`](examples/caller-secret-scan.yml). The example wires up all three triggers (PR, push to main, weekly cron) as separate jobs that select the right mode.

**2. (Optional) Add a Gitleaks config** at `.gitleaks.toml` for repo-specific custom rules and allowlists. The reusable workflow auto-detects the file; absent file → Gitleaks built-in default ruleset.

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