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

### Dependency Review (`dependency-review.yml`)

Wraps [`actions/dependency-review-action`](https://github.com/actions/dependency-review-action) with org-standard severity threshold and license policy. Designed to fail PRs that introduce (a) dependencies with CVEs at/above the configured severity, or (b) dependencies carrying denied licenses.

**1. Add the caller workflow** to each repo at `.github/workflows/dependency-review.yml`. Copy-paste-ready version at [`examples/caller-dependency-review.yml`](examples/caller-dependency-review.yml).

**2. Inputs** (all optional, override via `with:`):

| Input | Default | Notes |
|---|---|---|
| `fail_on_severity` | `high` | Minimum CVE severity that fails the check. One of `low`, `moderate`, `high`, `critical` |
| `deny_licenses` | `GPL-2.0,AGPL-3.0,LGPL-2.0,LGPL-2.1,LGPL-3.0,AGPL-1.0` | Comma-separated SPDX identifiers denied org-wide. Conservative copyleft default; legal/eng input may refine |
| `allow_licenses` | _(empty)_ | Optional allow-list. When non-empty, the action switches to allow-list mode and `deny_licenses` is ignored — see precedence below |
| `comment_summary_in_pr` | `true` | Post the action's built-in vulnerability + license summary as a PR comment |

**Precedence — `allow_licenses` vs `deny_licenses`:** `actions/dependency-review-action` rejects callers that pass both at once. When `allow_licenses` is set the reusable workflow drops `deny_licenses`, putting the action into allow-list mode (stricter — only listed licenses pass). When `allow_licenses` is empty the org-default deny-list applies. To override the deny-list, pass your own `deny_licenses` value; to switch policies entirely, set `allow_licenses`.

**3. Required permissions** in the caller (already shown in the example):

```yaml
permissions:
  contents: read
  pull-requests: write   # only used when comment_summary_in_pr is true
```

**4. Requirements:** Dependency Review API is free on public repos. On private repos it requires GitHub Advanced Security.

**Versioning:** Callers pin the reusable workflow with `@v1`; the reusable workflow SHA-pins the underlying `actions/dependency-review-action` ref. Action upgrades happen in one place.