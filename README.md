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

### CodeQL (`codeql.yml`)

Reusable wrapper around GitHub's first-party `github/codeql-action` for deep static analysis. Auto-detects supported languages, runs the `security-extended` query suite by default, scans the PR diff on `pull_request` events and the full repo on `push` / `schedule`, and uploads SARIF to the Security tab.

> **GHAS requirement:** **Private repos require [GitHub Advanced Security (GHAS)](https://docs.github.com/en/get-started/learning-about-github/about-github-advanced-security)**. Without GHAS, the SARIF-upload step inside `analyze@v3` returns 403. Public repos work without GHAS — Code Scanning is free for public repos. If your private repo can't enable GHAS, use [`sast.yml`](#sast-semgrep-sastyml) (Semgrep-based) instead.

**1. Add the caller workflow** to each repo at `.github/workflows/codeql.yml`. Copy-paste-ready version at [`examples/caller-codeql.yml`](examples/caller-codeql.yml). Triggers: every PR (diff-scoped), every push to `main` (full repo), and weekly on Mondays.

**2. Auto-detected languages:** the workflow probes the worktree for source files and emits one matrix job per detected language. CodeQL language IDs: `javascript-typescript`, `python`, `go`, `java-kotlin`, `csharp`, `ruby`, `swift`, `cpp`. JS+TS share a single `javascript-typescript` analyzer; Java+Kotlin share `java-kotlin`. No caller configuration needed for the common cases.

**3. Inputs** (all optional, override via `with:`):

| Input | Default | Notes |
|---|---|---|
| `languages` | (empty → auto-detect) | Comma-separated CodeQL language IDs to override auto-detect. Use the IDs listed above |
| `query_suite` | `security-extended` | One of `default`, `security-extended`, `security-and-quality`. Pick `security-and-quality` if you want lint-style code-quality findings alongside security findings |
| `build_command` | (empty) | Custom shell command to build compiled-language sources (Java/Kotlin, C#, C/C++, Swift) when CodeQL's `autobuild` can't figure out your project. Empty → autobuild for compiled languages, no-op for interpreted languages |

**4. No secrets required.** SARIF upload uses the standard `GITHUB_TOKEN` with `security-events: write`.

**Versioning:** Callers pin the reusable workflow with `@v1`; the reusable workflow pins `github/codeql-action` to `@v3`. Engine upgrades happen in one place.