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

### SAST (Semgrep) (`sast.yml`)

Reusable Semgrep scan that runs the SpiceLabs-curated default ruleset, layers on auto-detected language packs, and uploads SARIF to GitHub Code Scanning (Security tab). Catches OWASP Top Ten classes — including A03 injection — across any caller language without per-repo wiring.

Semgrep is installed via `pip install semgrep==<pinned-version>` so the rule engine version is plain-text auditable in the reusable workflow. No third-party Semgrep Action is used. The pinned version is bumped deliberately when the org wants new rules.

**1. Add the caller workflow** to each repo at `.github/workflows/sast.yml`. Copy-paste-ready version at [`examples/caller-sast.yml`](examples/caller-sast.yml). Triggers: every PR, every push to `main`, and weekly on Mondays.

**2. (Optional) Add repo-specific custom rules** at `.semgrep.yml`. The reusable workflow auto-detects the file at the configured `config_path` and layers it on top of the curated rulesets. Absent file → curated rulesets only.

**3. Auto-detected language packs:** the workflow probes the worktree for source files and adds `p/javascript`, `p/python`, `p/golang`, or `p/java` when it finds matching files. No caller configuration needed for the common cases.

**4. Inputs** (all optional, override via `with:`):

| Input | Default | Notes |
|---|---|---|
| `additional_rulesets` | (empty) | Comma-separated extra Semgrep ruleset IDs (e.g. `p/javascript,p/golang`). Each becomes its own `--config` flag. Layered on top of the curated defaults and auto-detected packs |
| `config_path` | `.semgrep.yml` | Path to a caller-maintained custom-rules file. Tolerated absent — workflow simply skips when the file isn't present |
| `fail_on_severity` | `error` | Severity gate. One of `info`, `warning`, `error`. Findings at or above this level fail the job. SARIF still uploads either way |

**5. No secrets required.** Semgrep runs against the checked-out tree; SARIF upload uses the standard `GITHUB_TOKEN` with `security-events: write`.

**Curated rulesets (always on):** `p/default`, `p/owasp-top-ten`, `p/secrets`.

**Versioning:** Callers pin the reusable workflow with `@v1`; the reusable workflow pins Semgrep to a specific PyPI release. Engine upgrades happen in one place.
