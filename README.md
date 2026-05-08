# .github

Organization-level defaults for [SpiceLabsHQ](https://github.com/SpiceLabsHQ). The `profile/README.md` is what shows on the org's GitHub page.

## Reusable workflows

### Claude PR Review (`claude-pr-review.yml`)

Centrally maintained Claude Code PR review running on AWS Bedrock. Each repo opts in with a ~15-line caller workflow and (optionally) carries its own review standards file.

The bot operates in two modes:

- **Auto-review** (PR opened / ready_for_review): performs a full review and chooses one of three outcomes — formal approve, formal request-changes, or comment-with-reviewer-assignment. Read-only on the filesystem.
- **On-demand** (`@claude` mention in a PR comment): treats the comment as a task and can edit files + push commits to the PR branch to satisfy the request.

**1. Add the caller workflow** to each repo at `.github/workflows/claude.yml`. Copy-paste-ready version at [`examples/caller-claude-pr-review.yml`](examples/caller-claude-pr-review.yml).

**2. (Optional) Add repo-specific review standards** at `.claude/pr-review-standards.md`. The reusable workflow auto-detects the file and substitutes it into the review prompt's `<project_specific_guidelines>` block (overriding org defaults on conflict). Absent file → org defaults only. `CLAUDE.md` is also picked up because the action runs in the checked-out workspace.

**3. Inputs** (all optional, override via `with:`):

| Input | Default | Notes |
|---|---|---|
| `model` | `us.anthropic.claude-sonnet-4-5-20250929-v1:0` | Bedrock inference profile or model ID |
| `aws_region` | `us-west-2` | Bedrock region |
| `trigger_phrase` | `@claude` | Comment phrase that triggers on-demand mode |
| `standards_path` | `.claude/pr-review-standards.md` | Override if your repo stores standards elsewhere |
| `default_reviewer` | `brodkin` | Fallback reviewer login when no other collaborator qualifies for assignment |
| `show_full_output` | `false` | When `true`, Claude's tool calls + reasoning + tool results stream into Actions logs. Useful for diagnosing permission denials or wasted turns. **Public-repo callers: anyone who can see the Actions run sees the full output** — use only on debug branches |

**4. Required secrets** (set once at the org level — they don't auto-inherit, the caller passes them explicitly):

| Secret | Purpose |
|---|---|
| `AWS_CLAUDE_BEDROCK_ROLE_ARN` | AWS role assumed via OIDC for Bedrock |
| `CLAUDE_REVIEW_APP_ID` | GitHub App ID. Required because `GITHUB_TOKEN` cannot approve PRs — the workflow mints an installation token from the App for formal approve / request-changes calls |
| `CLAUDE_REVIEW_APP_PRIVATE_KEY` | PEM private key for the same App |

**5. Optional secret:**

| Secret | Effect when set |
|---|---|
| `LINEAR_API_KEY` | Workflow exposes the key as env to the action; prompt instructs Claude to fetch the linked Linear issue (detected from branch name or PR title) and verify the PR's scope against it |

**6. Bulk rollout:** `scripts/rollout-claude-review.sh` opens an adoption PR in every non-archived org repo. Defaults to dry-run; pass `--apply` to actually create PRs.

**Versioning:** Callers pin the reusable workflow with `@v1`; the reusable workflow pins the underlying `anthropics/claude-code-action` ref. Action upgrades happen in one place.