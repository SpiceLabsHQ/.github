# .github

Organization-level defaults for [SpiceLabsHQ](https://github.com/SpiceLabsHQ). The `profile/README.md` is what shows on the org's GitHub page.

## CI floor & maturity ladder

Every repo in the org is held to a **mechanically enforced minimum CI tier** and guided up a **documented maturity ladder** — floor by enforcement, excellence by paved road (DEV-499). The floor is enforced by **org rulesets**, not by per-repo installation: a ruleset uses GitHub's *"require workflows to pass"* rule to run a central `floor-*.yml` workflow (defined in this repo) on every PR in the targeted repos. A brand-new repo created with zero setup is automatically held to the code floor — nothing to install, nothing to forget. This is the structural fix for the stranded-bot-PR problem (DEV-497): review automation is guaranteed to exist wherever bots open PRs.

### Enforcement matrix

| Level | Applies to | Contents | Enforced by |
|---|---|---|---|
| **Docs floor** | repos tagged `ci-exception: docs` | `pr-hygiene`, `secret-scan`, seeded `renovate.json` | ruleset `spice-ci-floor-docs` |
| **Code floor** | all untagged repos (incl. private) | `pr-hygiene`, `secret-scan`, `pepper-pr-review`, `sast`, `actions-audit`, `auto-merge enable`, seeded `renovate.json` | ruleset `spice-ci-floor-code` |
| **Public overlay** | public repos (additive) | `scorecard-public` | ruleset `spice-ci-floor-public` |
| **Silver** (guidance) | code repos | `scorecard` (where supported on private); `codeql` on public repos with a CodeQL-supported language; `dependency-review` on public repos with the Dependency Graph enabled — neither can be a blanket gate (an empty language matrix or a missing dependency graph fails the run) | audit flags the next rung on the dashboard |
| **Gold** (guidance) | code repos | `release-please` + `release-artifacts`, SHA-pinned third-party actions | audit flags the next rung on the dashboard |

The floor workflows live in [`.github/workflows/`](.github/workflows/) as `floor-hygiene.yml`, `floor-secret-scan.yml`, `floor-sast.yml`, `floor-pepper.yml`, `floor-automerge.yml`, and `floor-public.yml`. Each is a thin PR-triggered wrapper that calls the corresponding reusable workflow (pinned to its `<workflow>-v1` floating major) in the *target* repo's context — so `secret-scan` scans the target repo, `pepper` reviews the target repo's PR, and so on. They self-skip on this `.github` repo, which dogfoods the same workflows via its own `self-*` / `pepper-self-review` callers.

### The exception model (fail-safe by default)

Targeting is **exception-only**: the default assumption is that *every repo is a code repo*. There is no org-wide classification or backfill — only exceptions get tagged.

- A repo with **no tag** gets the **full code floor**. Forgetting to tag a repo gives it *more* CI, never less, and the miss is loud — this is deliberate (fail-safe).
- The `ci-exception` [organization custom property](https://github.com/organizations/SpiceLabsHQ/settings/custom-properties) (single-select, allowed value `docs`, **org-owners-only**) is the sole opt-*down*. Its complete value list is the auditable inventory of everything not held to the full standard.
- Tagging a repo `docs` is a deliberate, admin-only decision for genuinely static/docs repos (no application code). Set it in org settings → Custom properties, or:

  ```bash
  gh api -X PATCH orgs/SpiceLabsHQ/properties/values \
    -f 'repository_names[]=<repo>' \
    -f 'properties[][property_name]=ci-exception' -f 'properties[][value]=docs'
  ```

> **Known limit:** if a middle tier ever emerges, exception values multiply — at that point switch to a required `ci-tier` property with `default_value: code`; the rulesets carry over.

### Maturity ladder: Floor → Silver → Gold

The floor is the *minimum*; the ladder is the *paved road* up. **Silver** and **Gold** are guidance, not merge-blocking policy — a scheduled org-audit workflow ([`scripts/org-ci-audit.sh`](scripts/org-ci-audit.sh)) inventories each repo's installed callers and `renovate.json` against its tier and publishes a per-repo scorecard, **flagging the next missing rung for each repo** on the dashboard. It also flags exception-list honesty ("does anything tagged `docs` look like it grew code?"). Today the dashboard names the gap and a human opens the fix PR; auto-opening the next-rung PR is a planned enhancement, not yet implemented.

**Renovate is floor, not Silver** — it's a near-zero-cost JSON file and it's what keeps every other floor workflow current. But a ruleset can't require a *file* to exist, so Renovate's floor status is enforced by the audit (a missing `renovate.json` is a dashboard violation), not by merge blocking.

## Auto-merge policy: Pepper-gated (DEV-502)

Spice is **AI-first**, so the org merges on **review confidence, not change type**. A PR merges once **all required checks are green AND an approving review exists** — and there are deliberately **no semver tiers** (patch/minor/major auto-merge rules): that's the crutch for orgs without a trustworthy always-on reviewer. Spice has one.

The *merge gate* (review confidence) is uniform, but **what auto-arms auto-merge is author-class scoped** (ADR-0017, amending ADR-0008):

- **Bots, by default** — but only an **enumerated allowlist** (`renovate[bot]`, `dependabot[bot]`), never a `*[bot]` glob (every GitHub App login ends in `[bot]`). Bots arm automatically because no human reads Pepper's feedback on a bot's behalf.
- **Humans, per-repo opt-in** — a human PR self-arms only when the repo carries the org custom property **`automerge-humans` = `true`** (default absent/false). Arming *every* human PR was denying authors the experience of **reading Pepper's review**: a high-confidence approval merged instantly and the feedback was never seen. Where the repo hasn't opted in, the author still clicks GitHub's native **Enable auto-merge** button when they want it (a GitHub-native per-PR override — no new machinery).

**Pepper is the gate.** [`pepper-pr-review`](#pepper-pr-review-pepper-pr-reviewyml) (Claude Sonnet 5) is a *high-confidence-or-defer* reviewer. High-confidence → it approves → the pending merge fires. Not confident → it **defers to `@SpiceLabsHQ/reviewers`** and does not approve → the PR waits for a human. Pepper's deferral *is* the human fallback — automatic, no rules to maintain. Majors, security bumps, and anomalies are all handled by that judgment + deferral, not by version-delta rules.

How the pieces fit:

- **The unlock** — `spice-branch-protection` keeps `required_approving_review_count: 1` and `require_last_push_approval: true` but **drops `require_code_owner_review`**. A GitHub App cannot be a code owner, so code-owner review would force a human on every PR; without it, Pepper's approval is sufficient while its *deferral* (no approval) still forces a human. **CODEOWNERS files are retained** — they now just *route* Pepper's deferrals to the right reviewers.
- **Enabling auto-merge** — [`floor-automerge.yml`](.github/workflows/floor-automerge.yml) arms GitHub native auto-merge (squash) on code-tier PRs, injected zero-install by the `spice-ci-floor-code` ruleset. The author-class test lives in the **job-level `if:`**, so a non-arming PR (a human PR in a non-opt-in repo, or an unlisted bot) **skips with zero runner minutes** — a skipped required workflow counts as *passing*, so it never deadlocks merge. Opt-in is read from the payload at `github.event.repository.custom_properties['automerge-humans']` (hyphenated → bracket syntax; values are strings). It is best-effort (never fails its required check) and also skips drafts, this `.github` repo, and `rosemary-releaser` release PRs (the rosemary skip is *kept*, not redundant — the opt-in clause is repo-scoped and would otherwise arm a release PR in an opt-in repo).
- **Renovate PRs** self-enable auto-merge natively — a **second, consistent bots-by-default arming path**. The shared preset [`default.json`](default.json) (consumed via `"extends": ["github>SpiceLabsHQ/.github"]`) sets `platformAutomerge` + `automerge` on all update types, groups non-major updates into one PR (fewer Pepper runs, no lockfile-conflict cascade), and applies a `minimumReleaseAge` of 3 days as a supply-chain soak.
- **Objective backstop** — where a repo has meaningful tests, its test CI is made a required status check (an objective correctness signal Pepper structurally can't provide for e.g. a lockfile bump — automation, not a human gate, so it stays philosophy-consistent). Where there are no tests, Pepper + the release-age soak are the gate.

> **Trust boundary:** Pepper's approve-vs-defer calibration is load-bearing. Monitor its precision over time (the AI-first equivalent of "review quality"); required test CI + the release-age soak are the objective backstops. See [`rulesets/README.md`](rulesets/README.md#auto-merge-rollout-dev-502) for the staged rollout (pilot on `Reaper` first) and the exact `spice-branch-protection` change.

## Repo-settings reconciler (DEV-519)

Some per-repo settings **can't be enforced by org rulesets** — there is no ruleset rule for merge method, and the flags (`allow_squash_merge` / `allow_merge_commit` / `allow_rebase_merge`) are per-repo. The org-wide `required_linear_history` (in `spice-branch-protection`) forbids *merge commits* but still allows **rebase-merge**, which preserves per-commit messages and bypasses the Conventional-Commits PR-title check. So **squash-only genuinely needs API-level enforcement** — a scheduled reconciler, not a ruleset.

[`org-repo-settings-reconcile.yml`](.github/workflows/org-repo-settings-reconcile.yml) (running [`scripts/org-repo-settings-reconcile.sh`](scripts/org-repo-settings-reconcile.sh)) reconciles every non-archived org repo to a **declarative desired-state**, [`repo-settings.yml`](repo-settings.yml). It is general-purpose: each leaf key under `policies.<group>` is a literal field of GitHub's [update-a-repository](https://docs.github.com/en/rest/repos/repos#update-a-repository) API, so **adding a new enforced setting is a config edit, not code**. The reconciler diffs each field against the live repo and, on any drift within a group, PATCHes that group's fields together in one atomic call — GitHub validates some fields (like squash title/message) as a set against the request's defaults, so **co-validated fields must travel together** (idempotent — a no-op when a repo is already conformant). The planning logic lives in [`scripts/org-repo-settings-plan.jq`](scripts/org-repo-settings-plan.jq) and is fixture-tested in CI.

- **First policy — squash-only merge.** `allow_squash_merge=true`, `allow_merge_commit=false`, `allow_rebase_merge=false`, `squash_merge_commit_title=PR_TITLE`, `squash_merge_commit_message=PR_BODY`. This is what makes the native squash [auto-merge](#auto-merge-policy-pepper-gated-dev-502) coherent org-wide. `Eng-Cookbook` (DEV-515) was set to this state by hand as the reference.
- **Team access (DEV-525).** A second pass keeps the `reviewers` team's read access present on every repo — [Pepper's escalation target](#pepper-pr-review-pepper-pr-reviewyml). Granting a team access is a different API (`PUT /orgs/{org}/teams/{slug}/repos/…`), not a repo-update field, so `team_access` is reconciled separately with **floor semantics**: ensure each team has *at least* the configured permission, never downgrade a higher grant. Forks are included; archived repos aren't scanned. An unreadable/missing team **warns and skips** (it never fails the run red) — only a real grant failure errors.
- **Two modes** — `audit` (dry-run: report drift) and `apply` (reconcile). Manual `workflow_dispatch` defaults to `audit`; the nightly `schedule` runs `apply`. The drift/apply report lands in the run's job summary.
- **Exceptions** follow the same custom-property model as the [CI-floor exception](#the-exception-model-fail-safe-by-default): the `repo-settings-exception` property opts a repo out — value `all`/`*` skips the whole repo, a group name (e.g. `merge`) skips just that policy group, `team_access` skips just the team-access pass, comma-separated lists skip several. `options.exclude_forks` additionally excludes every fork.
- **Auth** — mints a short-lived org-scoped **GitHub App** token at runtime (same pattern as [`org-ci-audit.yml`](#ci-floor--maturity-ladder)), so there's no long-lived PAT. Its App needs `Administration: write` (to PATCH settings), `Metadata: read`, org `Custom properties: read`, and — for the team-access pass — org `Members: read` (detect drift) / `write` (grant on new repos); store `REPO_SETTINGS_APP_CLIENT_ID` / `REPO_SETTINGS_APP_PRIVATE_KEY` on this repo. The workflow no-ops with a warning until those secrets exist. See the workflow header for the one-time setup and staged rollout.

> The *written* policy (why squash-only) lives as a repo-configuration **standard** in `Eng-Cookbook` (DEV-515); this reconciler is that standard's **enforcement** — the standard↔enforcement pair. Keep the cookbook's enforcement link pointed here.

## Versioning & releases

Every reusable workflow in this repo is versioned **independently**, via [release-please](https://github.com/googleapis/release-please) in monorepo mode (one package per workflow under [`workflows/`](workflows/README.md)). A release — or a breaking change — in one workflow never affects consumers of another, and no human ever moves a tag by hand.

### Refs you can pin

| Ref | Mutability | Meaning |
|---|---|---|
| `<workflow>-vX.Y.Z` (e.g. `secret-scan-v1.2.3`) | **Immutable** | One specific release of one workflow. Cut automatically when that workflow's release PR merges |
| `<workflow>-vN` (e.g. `secret-scan-v1`) | Floats **within the major only** | The backward-compatibility line. Advanced automatically (`release-tag-aliases.yml`) to the latest release of major N — never across a breaking change |
| Commit SHA | Immutable | Strongest pin; pair with Renovate for reviewable upgrades |
| `v1`, `v1.0.0` | **Frozen — legacy, deprecated** | The old org-wide shared tags, permanently parked at commit `60a48c1`. They will never move again and receive no fixes. Migrate off them (see below) |

### Policy

- **A major alias is a backward-compatibility promise.** `<workflow>-vN` only ever advances to non-breaking releases within major N.
- **A breaking change requires a new major.** Mark it with Conventional Commits (`feat(secret-scan)!: …` or a `BREAKING CHANGE:` footer); release-please bumps to `(N+1).0.0` and a new `<workflow>-v(N+1)` alias appears. Consumers pinned to `-vN` are untouched until they opt in.
- **Tags advance only via the release automation.** Force-moving a shared mutable tag to ship changes — which broke every adopter at once during DEV-404 — is retired as a practice and structurally prevented: the alias workflow only moves an alias within its own major, and only forward (never to a lower version).
- **Platform-level immutability:** keep GitHub's immutable-releases setting enabled for this repo (and/or a tag ruleset matching `*-v[0-9]*.[0-9]*.[0-9]*`) so release tags can't be moved or deleted even accidentally. Do **not** protect the bare `<workflow>-vN` aliases — advancing within a major is their job.

### How consumers should pin

Strongest first:

1. **Commit SHA** — the same rigor these workflows apply to the third-party actions inside them:

   ```yaml
   uses: SpiceLabsHQ/.github/.github/workflows/secret-scan.yml@a1b2c3… # secret-scan-v1.2.3
   ```

   Caveat: automated updates of SHA pins are unproven for this repo's component-prefixed tags (Renovate's digest pinning has open issues with suffixed version tags — [renovate#35789](https://github.com/renovatebot/renovate/issues/35789)); verify before adopting at scale.

2. **Immutable release tag** — reproducible, human-readable, and the form Renovate reliably updates: `@secret-scan-v1.2.3`
3. **Floating major** (**org default** for internal repos, DEV-494) — hands-off non-breaking updates, trusting this repo's release process: `@secret-scan-v1`. No consumer PRs needed: the alias advances server-side on every non-breaking release; a new major is a deliberate, opt-in edit.

**Update automation is Renovate, not Dependabot** (evaluated in DEV-494). Renovate's github-actions manager [documents](https://docs.renovatebot.com/modules/manager/github-actions/) component-prefixed tags (`prefix-v1.2.3`); seed this config per repo (it cannot be inherited org-wide from this repo, and stays inert until the [Mend Renovate GitHub App](https://github.com/apps/renovate) is installed on the org — install it on the consumer repos *and* this one so it can list tags):

```json
// .github/renovate.json
{
  "$schema": "https://docs.renovatebot.com/renovate-schema.json",
  "extends": ["config:recommended"],
  "enabledManagers": ["github-actions"],
  "packageRules": [
    {
      "description": "SpiceLabsHQ reusable workflows: release-please monorepo tags like secret-scan-v1.2.3",
      "matchManagers": ["github-actions"],
      "matchDatasources": ["github-tags"],
      "matchPackageNames": ["SpiceLabsHQ/.github**"],
      "versionCompatibility": "^(?<compatibility>.*)-v(?<version>.*)$",
      "versioning": "semver"
    }
  ]
}
```

> **Why not Dependabot:** it cannot parse `<workflow>-vX.Y.Z` as a version (hyphen-prefixed tags fail its github-actions version class), it silently ignores floating `<workflow>-vN` aliases (no major-bump PRs, ever), and on SHA pins with a tag comment it degrades to bumping the SHA to branch HEAD while leaving the stale comment in place — unreviewed tip-of-main with a lying comment. Details and sources in DEV-494. Don't run it alongside Renovate for `github-actions` either, or the two will fight over third-party action pins.

### Migrating off the legacy `@v1`

1. In each consuming repo, find the pins: `grep -rn 'SpiceLabsHQ/.github/.github/workflows/' .github/workflows/`
2. Replace `@v1` with the per-workflow ref — e.g. `secret-scan.yml@v1` → `secret-scan.yml@secret-scan-v1`, or an immutable tag / SHA per above.
3. No urgency-forced breakage: legacy `v1` stays parked where it is today, so existing callers keep working — but it receives no fixes, so treat the migration as due promptly.

### Releasing (maintainers)

- **Conventional Commit PR titles drive everything** (this repo squash-merges): `fix(secret-scan): …` → patch, `feat(secret-scan): …` → minor, `!`/`BREAKING CHANGE` → major. `chore`/`docs` don't trigger releases. Enforced on this repo's own PRs by `self-pr-hygiene.yml`.
- **Keep a PR scoped to one workflow where possible.** The squash commit is attributed to every workflow whose files it touches, so a cross-workflow PR lands in multiple changelogs under a single (possibly mismatched) scope.
- **After editing any reusable workflow, run [`scripts/sync-workflow-checksums.sh`](scripts/sync-workflow-checksums.sh)** and commit the regenerated `workflows/<name>/workflow.sha256`. GitHub forces all workflow YAML into the flat `.github/workflows/` directory, while release-please routes commits to packages by directory path — the checksum file is the bridge that routes your commit to the right package. The same applies to files a workflow ships from outside its YAML: `pepper-pr-review` reads its review prompts from `prompts/` at the release commit, so those templates are hashed into its checksum file too and a prompt-only edit still cuts a release. `repo-checks.yml` fails any PR where it's stale, so you can't forget silently.
- On merge to main, `self-release.yml` (this repo dogfooding its own reusable `release-please.yml`) opens or updates a release PR **per changed workflow**. Merging a release PR cuts `<workflow>-vX.Y.Z` + a GitHub Release, and `release-tag-aliases.yml` advances `<workflow>-vN`.
- **Adding a new reusable workflow:** create `.github/workflows/<name>.yml`, run the sync script, and register `workflows/<name>` in `release-please-config.json` and `.release-please-manifest.json` (start at `0.1.0`; go `1.0.0` when the interface settles). CI enforces the registration.

## Reusable workflows

### Pepper PR Review (`pepper-pr-review.yml`)

Pepper is the Spice Labs PR review bot, powered by Claude Sonnet 5 on AWS Bedrock. The reusable workflow is centrally maintained here and reaches every code-tier repo **zero-install**: the `spice-ci-floor-code` org ruleset injects [`floor-pepper.yml`](.github/workflows/floor-pepper.yml) (see [`rulesets/`](rulesets/)). A repo optionally carries its own review standards file — nothing else.

**Naming legend:** workflow display name is **Pepper PR Review**, status check appears as **Pepper PR Review / Pepper review**, and formal approves and request-changes are authored by the **Pepper PR Review** GitHub App (the reviewer name shown on the PR, not the workflow bot account).

The bot operates in two modes:

- **Auto-review** (PR `opened` / `synchronize` / `reopened` — the only events GitHub delivers to ruleset-injected workflows; `ready_for_review` and `issue_comment` are dropped, see DEV-576): performs a full review and chooses one of three outcomes — formal approve, formal request-changes, or comment-with-reviewer-assignment. Read-only on the filesystem. **Pushing a commit is what triggers a fresh review** — a draft marked ready is reviewed on its next push.
- **On-demand** (`@pepper` mention in a PR comment): **dormant — no caller in the org wires `issue_comment`.** Floor repos never receive the event, and this repository's own `pepper-self-review.yml` deliberately matches the floor's event set so Pepper behaves one way everywhere (DEV-576). Pushing a commit is the only way to drive a review; removing the mode from the reusable is a DEV-576 follow-up.

**Draft guidance (DEV-666).** Neither mode reviews a draft, and from the PR surface that skip is indistinguishable from "Pepper never ran". So on a draft, Pepper posts a **sticky comment** saying how to get reviewed — mark it ready, then push a commit. One comment per PR, updated in place across pushes, and deleted once the PR is no longer a draft so a "still a draft" note never sits above an actual verdict. Non-blocking by construction: every step is `continue-on-error`, so it cannot fail the required floor check.

**Commit stamp (DEV-721).** Every review body ends with `Reviewed at <short-sha>.` — the PR head commit as it stood when the run started. A review can outlive the commit that started it: push while Pepper is still reading and GitHub stamps the filed verdict's `commit_id` with the *newer* head, so the PR surface credits the verdict to code Pepper never saw. The stamped line is the fixed record; compare it against the PR's current head to spot a stale verdict at a glance. The no-verdict escalation comment names the same SHA. Both drop the stamp rather than guess if the head can't be resolved.

**1. Nothing to install.** The floor injects Pepper into every code-tier repo. Do **not** commit a per-repo caller: it duplicates the required floor run (the two-caller concurrency shape fixed in DEV-561) and drifts from the centrally maintained one.

**2. (Optional) Add repo-specific review standards** at `.pepper/pr-review-standards.md`. The reusable workflow auto-detects the file and substitutes it into the review prompt's `<project_specific_guidelines>` block (overriding org defaults on conflict). Absent file → org defaults only. `CLAUDE.md` still reaches the reviewer — Claude Code auto-loads it from the checked-out workspace as agent guidance — but it has no guaranteed placement in the review prompt and no override authority on conflict; **review criteria** belong in the standards file, which is substituted verbatim and wins.

**3. Inputs** (all optional, override via `with:`):

| Input | Default | Notes |
|---|---|---|
| `review_model` | `arn:…application-inference-profile/xda66yqkegz4` (`pepper-pr-review-sonnet-5`) | Model used in review mode. Default is an AWS Application Inference Profile wrapping Claude Sonnet 5, tagged `Product=pepper, Mode=review` for cost allocation |
| `on_demand_model` | `arn:…application-inference-profile/lk2br1cu7fkj` (`pepper-on-demand-sonnet-5`) | Model used in on-demand mode. Same Claude Sonnet 5 underneath, tagged `Mode=on-demand` so AWS Cost Explorer can split spend by flow |
| `model` | `""` | Override that wins for **both** modes. Set only when testing a different model on a debug branch — bypassing the per-mode profiles forfeits cost attribution |
| `aws_region` | `us-west-2` | AWS region where the Bedrock role and inference profiles live |
| `trigger_phrase` | `@pepper` | Comment phrase that triggers on-demand mode |
| `standards_path` | `.pepper/pr-review-standards.md` | Override if your repo stores standards elsewhere |
| `reviewers_team` | `reviewers` | Slug of the org team Pepper requests review from on escalation. Must be a team in the repo's own org with read access to the repo; the App token needs org `members: read` to resolve it |
| `show_full_output` | `false` | When `true`, Pepper's tool calls + reasoning + tool results stream into Actions logs. Useful for diagnosing permission denials or wasted turns. **Public-repo callers: anyone who can see the Actions run sees the full output** — use only on debug branches |
| `coverage_review_enabled` | `false` | Opt in to the non-gating diff-coverage note (DEV-526). **Off by default** — a repo that doesn't publish coverage pays nothing (no poll, no added latency). Turn on only in repos that add the [`coverage-surface`](#diff-coverage--pepper-coverage-surface) step to their test job |
| `coverage_artifact` | `coverage-report` | Artifact Pepper polls for when `coverage_review_enabled` is on. Must match the `artifact-name` on the `coverage-surface` step |
| `coverage_poll_timeout_seconds` | `1200` | Ceiling on the **shell-only** wait for the coverage artifact (no inference runs during the wait). The poll also gives up early once no CI run for the head SHA is still active, so no-coverage repos resolve fast |
| `coverage_poll_grace_seconds` | `45` | Minimum wait before the "no active CI runs" early-exit can fire — lets sibling CI register after the PR event |
| `coverage_poll_interval_seconds` | `15` | Seconds between coverage-artifact poll attempts |

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

**Versioning:** Callers pin with `@pepper-pr-review-v1` (or harden with an immutable `pepper-pr-review-vX.Y.Z` tag / commit SHA — see [Versioning & releases](#versioning--releases)); the reusable workflow pins the underlying `anthropics/claude-code-action` ref. Action upgrades happen in one place.

#### Diff coverage → Pepper (`coverage-surface`)

DEV-526 feeds **diff coverage** into Pepper's review as a **non-gating** input, per [ADR-0004]. No coverage percentage is a required check and no `%`-bar auto-fails CI. Coverage still reaches the verdict: Pepper's review is itself a required gate, and the coverage note is an input to it, so Pepper **may withhold approval** when the signal shows new logic that, in its judgment, should be tested and isn't. The gate is the reviewer's judgment informed by coverage — never a coverage number.

One coverage file produces three surfaces:

| Surface | Where | Runs in |
|---|---|---|
| Diff-coverage note in Pepper's review | review prompt | Pepper job (polls the artifact) |
| Inline `::warning::` annotations on uncovered changed lines | Files-changed tab | test job (local disk) |
| Diff-coverage table | Actions job summary | test job (local disk) |

**Producer (per repo, one-time):** emit a coverage file in any [`diff-cover`](https://github.com/Bachmann1234/diff_cover)-supported format (LCOV / Cobertura / Clover / JaCoCo), then add the shared [`coverage-surface`](.github/actions/coverage-surface) composite action as one step in your **test job**. Copy-paste-ready: [`examples/caller-coverage-surface.yml`](examples/caller-coverage-surface.yml). Every runner already has the flag — no format conversion, no per-runner parser:

| Runner | Emit flag | Format |
|---|---|---|
| Vitest | `--coverage.reporter=lcov` | LCOV |
| pytest | `--cov-report=xml` | Cobertura |
| Go | `go test -coverprofile` → gocover-cobertura | Cobertura |
| PHPUnit | `--coverage-clover clover.xml` | Clover |
| Pester | `-CodeCoverage` | JaCoCo |

Rollout order is TS / Python / Go first, then PHP and PowerShell — but the action is language-agnostic, so any of the above works today.

**Consumer (opt-in):** set `coverage_review_enabled: true` on your `pepper-pr-review` caller (alongside adding the `coverage-surface` step). It's **off by default** so repos without coverage see no change — no poll, no added review latency. When on, `pepper-pr-review` polls for the `coverage-report` artifact by the PR head SHA with a **shell-only** loop (no inference runs while waiting — tests are the longest CI task, so Pepper never hard-`needs:` them), then runs `diff-cover` once and folds the note into the review prompt. Missing artifact, timeout, or an unsupported format → Pepper reviews off the diff as before. The poll gives up early once no CI run for the head SHA is still active. Tune with the `coverage_poll_*` inputs above.

**Non-gating, enforced by design:** the composite action is fail-open — a missing file, unsupported format, non-PR event, or `diff-cover` error each downgrades to a `::warning::` and exits `0`. A coverage hiccup can never block a merge.

**Versioning:** `coverage-surface` is a composite action (not a reusable workflow), consumed via `uses: SpiceLabsHQ/.github/.github/actions/coverage-surface@<ref>`. Pin it to a commit SHA the same way you pin any third-party action.

[ADR-0004]: https://linear.app/spicelabshq/issue/DEV-526

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
| `allow_tags_for` | `actions/*,github/*,SpiceLabsHQ/*` | Comma-separated owner globs allowed to use tags instead of SHA pins. Add e.g. `aws-actions/*` if you trust other publishers |

**3. Required permissions** (caller declares them in its job block — see the example):

| Permission | Purpose |
|---|---|
| `contents: read` | Checkout the caller repo |
| `security-events: write` | Upload zizmor SARIF to the Security tab |
| `actions: read` | Lets zizmor read workflow metadata for some audits |

**4. No secrets required.** The audit runs entirely against the caller's checked-out workspace and uses `GITHUB_TOKEN` for SARIF upload.

**Versioning:** Callers pin with `@actions-audit-v1` (or harden with an immutable `actions-audit-vX.Y.Z` tag / commit SHA — see [Versioning & releases](#versioning--releases)). The reusable workflow pins zizmor to an exact version (`ZIZMOR_VERSION` env in the workflow) so audit results are reproducible across runs.

### Dependency Review (`dependency-review.yml`)

Wraps [`actions/dependency-review-action`](https://github.com/actions/dependency-review-action) with org-standard severity threshold and license policy. Designed to fail PRs that introduce (a) dependencies with CVEs at/above the configured severity, or (b) dependencies carrying denied licenses.

**1. Add the caller workflow** to each repo at `.github/workflows/dependency-review.yml`. Copy-paste-ready version at [`examples/caller-dependency-review.yml`](examples/caller-dependency-review.yml).

**2. Inputs** (all optional, override via `with:`):

| Input | Default | Notes |
|---|---|---|
| `fail_on_severity` | `high` | Minimum CVE severity that fails the check. One of `low`, `moderate`, `high`, `critical` |
| `deny_licenses` | `GPL-2.0,GPL-3.0,AGPL-1.0,AGPL-3.0,LGPL-2.0,LGPL-2.1,LGPL-3.0` | Comma-separated SPDX identifiers denied org-wide. See **License policy rationale** below |
| `allow_licenses` | _(empty)_ | Optional allow-list. When non-empty, the action switches to allow-list mode and `deny_licenses` is ignored — see precedence below |
| `comment_summary_in_pr` | `true` | Post the action's built-in vulnerability + license summary as a PR comment |

**License policy rationale:** Spice Labs maintains All Rights Reserved on its own code. The default `deny_licenses` blocks all GPL/AGPL/LGPL variants because their copyleft obligations would force giving up the ARR posture if a covered dependency were linked into a Spice Labs product. The default explicitly enumerates all seven copyleft variants the dependency-review-action will currently see in the wild:

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

**Versioning:** Callers pin with `@dependency-review-v1` (or harden with an immutable `dependency-review-vX.Y.Z` tag / commit SHA — see [Versioning & releases](#versioning--releases)); the reusable workflow SHA-pins the underlying `actions/dependency-review-action` ref. Action upgrades happen in one place.

### PR Hygiene (`pr-hygiene.yml`)

Two PR checks bundled into one reusable workflow. Drop the [caller workflow](examples/caller-pr-hygiene.yml) into any repo at `.github/workflows/pr-hygiene.yml`.

- **Conventional Commits title check (blocking).** Enforces a [Conventional Commits](https://www.conventionalcommits.org/) header on the PR title — required so `release-please` can classify the change at squash-merge time. On failure the workflow posts a sticky comment with a fix example; the comment is deleted automatically once the title is corrected.
- **Large-PR size warning (non-blocking).** Posts an informational sticky comment when a PR is large by changed lines **or** by file count. Generated and vendored files (lockfiles, build output, and anything matching `size_exclude_pattern`) are excluded from both counts, so a dependency bump doesn't trip it. The comment names whichever dimension crossed and points to the [Eng Cookbook PR standard](https://github.com/SpiceLabsHQ/Eng-Cookbook/blob/main/standards/pull-requests.md). The check exits 0 either way — branch protection should not require it.

**Inputs** (all optional, override via `with:`):

| Input | Default | Notes |
|---|---|---|
| `types` | `feat,fix,chore,docs,refactor,test,build,ci,perf,style,revert` | Comma-separated allowed CC types (converted internally to the action's newline format) |
| `require_scope` | `false` | When `true`, PR titles must include a scope, e.g. `feat(api): ...` |
| `large_pr_threshold` | `1000` | Changed-lines threshold (additions + deletions, excluding generated/vendored files) for the soft size warning |
| `large_pr_file_threshold` | `25` | Changed-files threshold (excluding generated/vendored files) for the soft size warning; fires independently of `large_pr_threshold` |
| `size_exclude_pattern` | _(lockfiles, `vendor/`, `dist/`, `build/`, `*.min.js`, …)_ | Extended regex (`grep -E`) of paths excluded from both size counts |

No secrets needed. The caller passes `permissions: { contents: read, pull-requests: write }` so the workflow can read the PR payload and post the sticky comments.

### Markdown Lint (`markdownlint.yml`)

Runs [`markdownlint-cli2`](https://github.com/DavidAnson/markdownlint-cli2) over a repo's Markdown so the lint definition lives once org-wide instead of being copy-pasted per repo. The reusable workflow is deliberately **policy-free** — it ships no rules of its own. Each consuming repo keeps its own `.markdownlint-cli2.jsonc` (rules only, no `globs` key) and sets its own file scope via the `globs` input, so the caller, pre-commit hooks, and this workflow can each target a different surface without the rule set drifting between them.

**1. Add the caller workflow** to each repo at `.github/workflows/markdownlint.yml`. Copy-paste-ready version at [`examples/caller-markdownlint.yml`](examples/caller-markdownlint.yml). The example scopes the trigger to Markdown/config changes so it stays off the critical path for code-only PRs.

**2. Add the rule set** at `.markdownlint-cli2.jsonc` (repo root, or wherever `config_path` points). Rules only — omit `globs` so scope stays caller-controlled. Rules-only starter:

```jsonc
{
  "config": { "default": true, "MD013": false, "MD033": false },
  "ignores": ["node_modules", ".git"]
}
```

**3. Inputs** (all optional, override via `with:`):

| Input | Default | Notes |
|---|---|---|
| `globs` | `**/*.md` | Glob(s) of Markdown files to lint, passed straight to `markdownlint-cli2`. Narrow e.g. to `docs/**/*.md` for docs-only repos |
| `config_path` | `.markdownlint-cli2.jsonc` | Path to the markdownlint-cli2 config. Tolerated absent — falls back to auto-discovery / built-in defaults rather than failing |

No secrets required. The caller passes `permissions: { contents: read }`; the workflow only reads the checked-out tree.

**Versioning:** Callers pin with `@markdownlint-v1` (or harden with an immutable `markdownlint-vX.Y.Z` tag / commit SHA — see [Versioning & releases](#versioning--releases)); the reusable workflow SHA-pins the underlying `markdownlint-cli2-action`, so linter upgrades happen in one place. Keep the caller's job name `markdownlint` so repos requiring the status check by name don't drift.

### Secret Scan (`secret-scan.yml`)

Gitleaks-based scanner for repo secrets, layered to catch what GitHub's native push-protection misses (custom token formats, secrets that already landed in history). The reusable workflow runs the open-source **gitleaks CLI** directly in two complementary modes; callers wire each mode to the appropriate triggers. It does **not** use the paid `gitleaks-action` — there is **no license and no org secret to provision** (the CLI is free for organization accounts too).

The two modes:

- **`pr-diff`** (fast): scans only the commits a PR adds. Findings appear in the run's job summary and **fail the check** so a leak can't merge. Run on every `pull_request`.
- **`full-history`** (slow): scans the entire git history. Run on `push` to the default branch and on a weekly cron. Catches secrets that pr-diff can't see — e.g., committed and "fixed" within the same PR (the secret is still in history forever) or committed before the repo adopted scanning.

**1. Add the caller workflow** to each repo at `.github/workflows/secret-scan.yml`. Copy-paste-ready version at [`examples/caller-secret-scan.yml`](examples/caller-secret-scan.yml). The example wires up all three triggers (PR, push to main, weekly cron) as separate jobs that select the right mode.

**2. (Optional) Add a Gitleaks config** at `.gitleaks.toml` for repo-specific custom rules and allowlists. The reusable workflow auto-detects the file; absent file → Gitleaks built-in default ruleset.

**3. Inputs** (all optional, override via `with:`):

| Input | Default | Notes |
|---|---|---|
| `mode` | `pr-diff` | `pr-diff` (PR's new commits only, fails the check on a finding) or `full-history` (entire git history) |
| `config_path` | `.gitleaks.toml` | Path to a Gitleaks config file. Tolerated absent — falls back to built-in defaults |

**4. (Optional) Security-tab integration on public repos.** On **public** repos, findings are uploaded as SARIF to GitHub code scanning (the Security tab) for free — grant `security-events: write` on the calling job (the example does). On **private/internal** repos this upload is auto-skipped, because code scanning there requires paid [GitHub Advanced Security](https://docs.github.com/en/get-started/learning-about-github/about-github-advanced-security); the scan still runs and still fails the check. No license is required either way.

**Versioning:** Callers pin with `@secret-scan-v1` (or harden with an immutable `secret-scan-vX.Y.Z` tag / commit SHA — see [Versioning & releases](#versioning--releases)); the reusable workflow pins the gitleaks CLI to a release version and verifies the downloaded binary against the release's published checksums. Scanner upgrades happen in one place.

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

**Versioning:** Callers pin with `@codeql-v1` (or harden with an immutable `codeql-vX.Y.Z` tag / commit SHA — see [Versioning & releases](#versioning--releases)); the reusable workflow pins `github/codeql-action` to `@v4`. Engine upgrades happen in one place.

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
| GitHub App | Set `ROSEMARY_RELEASER_APP_ID` + `ROSEMARY_RELEASER_APP_PRIVATE_KEY` org secrets, pass them through | PR + tag authored by the App. Downstream `push: tags:` workflows (release-artifacts.yml) **do** fire |

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
- **Versioning:** Callers pin with `@release-please-v1` (or harden with an immutable `release-please-vX.Y.Z` tag / commit SHA — see [Versioning & releases](#versioning--releases)); the reusable workflow SHA-pins both `googleapis/release-please-action` and `actions/create-github-app-token`. Action upgrades happen in one place.

### SAST (Semgrep) (`sast.yml`)

Reusable Semgrep scan that runs the Spice Labs-curated default ruleset, layers on auto-detected language packs, and uploads SARIF to GitHub Code Scanning (Security tab). Catches OWASP Top Ten classes — including A03 injection — across any caller language without per-repo wiring.

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

**Versioning:** Callers pin with `@sast-v1` (or harden with an immutable `sast-vX.Y.Z` tag / commit SHA — see [Versioning & releases](#versioning--releases)); the reusable workflow pins Semgrep to a specific PyPI release. Engine upgrades happen in one place.

### Release Artifacts (`release-artifacts.yml`)

The second half of the release pipeline. `release-please.yml` cuts the tag and opens the GitHub Release; this workflow attaches the supply-chain artifacts to that Release. Triggered on `release: types: [published]`.

For every artifact (or for the GitHub-generated source tarball when no artifacts are passed), the workflow produces:

- **SBOMs** in every requested format — default `spdx-json` and `cyclonedx-json` — via `anchore/sbom-action`'s bundled `syft` binary
- **SLSA build provenance** via [`actions/attest-build-provenance`](https://github.com/actions/attest-build-provenance)
- **Sigstore keyless signatures** via `cosign sign-blob`, producing both a `.sig` and the Fulcio-issued `.pem` certificate per artifact

Every successfully produced output is uploaded to the triggering Release with `gh release upload --clobber`.

> **Trigger requirement.** GitHub Releases authored by `GITHUB_TOKEN` do **not** cascade. Pair this caller with the GitHub App path in `release-please.yml`'s caller (`ROSEMARY_RELEASER_APP_ID` + `ROSEMARY_RELEASER_APP_PRIVATE_KEY`) so release-please's tag → Release event fires this workflow.

**1. Add the caller workflow** to each repo at `.github/workflows/release-artifacts.yml`. Copy-paste-ready version at [`examples/caller-release-artifacts.yml`](examples/caller-release-artifacts.yml). The example shows two patterns side-by-side: the empty-`artifacts` default (source-tarball SBOM only) and an explicit-globs job for repos that produce build outputs.

**2. Inputs** (all optional, override via `with:`):

| Input | Default | Notes |
|---|---|---|
| `artifacts` | _(empty)_ | Newline OR comma-separated list of file globs to SBOM, attest, and sign. Empty triggers the source-tarball fallback (SBOM only — see below) |
| `sbom_formats` | `spdx-json,cyclonedx-json` | Comma-separated SBOM formats. Accepts the values supported by Anchore's sbom-action: `spdx-json`, `cyclonedx-json`, `spdx-tag-value`, `cyclonedx-xml`, `syft-json`, `syft-table` |
| `enable_provenance` | `true` | Set to `false` to skip the SLSA build-provenance phase. Auto-skipped in the source-fallback path |
| `enable_signing` | `true` | Set to `false` to skip the cosign signing phase. Auto-skipped in the source-fallback path |

**3. Required permissions** on the calling job:

| Permission | Why |
|---|---|
| `id-token: write` | Required for cosign keyless signing (Sigstore Fulcio mints a short-lived cert from the workflow's OIDC token) AND for `actions/attest-build-provenance`, which uses the same OIDC primitive to mint provenance |
| `attestations: write` | `actions/attest-build-provenance` writes its bundle into GitHub's attestation store via the Attestations API |
| `contents: write` | `gh release upload` attaches asset files to the Release |
| `actions: read` | `actions/attest-build-provenance` reads workflow run metadata to populate the provenance subject and builder fields |

No secrets required. The workflow uses the run's own `GITHUB_TOKEN` for `gh release upload` and the OIDC token minted at job time for cosign and the attestation action.

**4. Empty-artifacts fallback (default behavior).** When the caller does not pass `artifacts:`, the workflow downloads the GitHub-generated source tarball that ships with every Release (via `gh release download "$TAG" --pattern '*.tar.gz'`) and produces SBOMs against it, named `sbom-source.<format>` (e.g. `sbom-source.spdx.json`, `sbom-source.cdx.json`). The provenance and signing phases are **skipped** in this path: there is no caller-built subject to honestly attest, and signing a tarball this workflow did not produce buys nothing for downstream verifiers. Pass explicit `artifacts:` globs to opt in to provenance + signing.

**5. Failure semantics.** Each phase (SBOM, provenance, signing, upload) runs with `continue-on-error: true`. A failure in one phase emits an `::error::` annotation but does not stop the next phase from running, so adopters see partial artifacts whenever possible. A final summary step always runs, prints a phase outcome table to the job summary, and exits non-zero if any phase failed — so the job's overall status reflects the union of phase outcomes. The Release retains whatever artifacts succeeded.

**6. Verifying signatures.** Spice Labs releases are signed by this workflow's identity URL. The canonical verification command for any Spice Labs Release artifact:

```bash
cosign verify-blob \
  --certificate-identity-regexp '^https://github\.com/SpiceLabsHQ/[^/]+/\.github/workflows/release-artifacts\.yml@.*$' \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com \
  --certificate <artifact>.pem \
  --signature <artifact>.sig \
  <artifact>
```

For documentation completeness, the generic shape (any owner/repo) looks like:

```bash
cosign verify-blob \
  --certificate-identity-regexp '^https://github\.com/<owner>/<repo>/\.github/workflows/release-artifacts\.yml@.*$' \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com \
  --certificate <artifact>.pem \
  --signature <artifact>.sig \
  <artifact>
```

See the [cosign documentation](https://docs.sigstore.dev/cosign/verifying/verify/) for the full set of certificate-matching flags (`--certificate-identity` for an exact match, `--certificate-github-workflow-*` for the GitHub-specific subject extensions, etc.).

**7. Verifying SLSA provenance.** The provenance bundle is uploaded to the Release as `provenance.intoto.jsonl`. Verify with [`slsa-verifier`](https://github.com/slsa-framework/slsa-verifier):

```bash
slsa-verifier verify-artifact \
  --provenance-path provenance.intoto.jsonl \
  --source-uri github.com/<owner>/<repo> \
  <artifact>
```

**8. Pinning policy.** The reusable workflow SHA-pins all third-party actions (`anchore/sbom-action`, `sigstore/cosign-installer`) to 40-char commit SHAs per the actions-audit policy. `actions/attest-build-provenance` is first-party but is also SHA-pinned because it is an attestation primitive whose semantics we want to bump deliberately. `actions/checkout` follows the standard first-party major-tag policy. Callers pin with `@release-artifacts-v1` (or harden with an immutable `release-artifacts-vX.Y.Z` tag / commit SHA — see [Versioning & releases](#versioning--releases)).

### OpenSSF Scorecard

Two reusable workflows wrap the [OpenSSF Scorecard](https://scorecard.dev) for different audiences. Both run the same Scorecard analysis and upload SARIF to GitHub Code Scanning; the difference is whether results are also published to OpenSSF's public dashboard at [securityscorecards.dev](https://securityscorecards.dev).

**Which one to use:**

- Is this repo public OSS that benefits from a **public Scorecard badge** (e.g. on the README, in security marketing, on a project landing page)? → use [`scorecard-public.yml`](#public-scorecard-publicyml).
- Otherwise (private repos, public repos that don't want a public badge, or anything where you only want Scorecard findings in the **Security** tab)? → use [`scorecard.yml`](#internal-scorecardyml).

The two workflows are intentionally split rather than combined behind a `publish` input, because Scorecard's publish API enforces strict workflow-shape constraints (no workflow-level write permissions, only allowlisted steps) that we don't want to apply to the internal variant — and don't want a future maintainer to accidentally violate while extending the public variant. See the public subsection below for the full constraint list.

#### Internal (`scorecard.yml`)

Internal Scorecard scan: runs Scorecard against the calling repo on a weekly schedule and uploads the SARIF findings to GitHub Code Scanning so they appear in the repo's **Security** tab. Raw SARIF is also kept as a workflow artifact for 30 days. **Does not publish to the public dashboard** — use [`scorecard-public.yml`](#public-scorecard-publicyml) for that.

**1. Add the caller workflow** to each repo at `.github/workflows/scorecard.yml`. Copy-paste-ready version at [`examples/caller-scorecard.yml`](examples/caller-scorecard.yml).

**2. Scheduling lives in the caller, not the reusable workflow.** GitHub's `workflow_call` mechanism can't dictate a `schedule:` to its parent, so the example caller wires the cron itself (default: Monday 06:00 UTC). Adjust to taste — staggering across repos avoids hitting Scorecard's analysis runners at the same minute. The caller also wires `workflow_dispatch` (for ad-hoc runs) and `branch_protection_rule` (Scorecard's preferred trigger so the Branch-Protection check re-scores immediately when protection settings change).

**3. Inputs:** None. The reusable workflow always runs Scorecard, emits SARIF, uploads it to Code Scanning, and stashes the raw SARIF as an artifact. There's nothing to configure per-call.

**4. Required permissions on the calling job:**

| Permission | Why |
|---|---|
| `contents: read` | Scorecard reads repo files, branch protection, releases |
| `security-events: write` | SARIF upload to Code Scanning |
| `actions: read` | Scorecard's Token-Permissions / Pinned-Dependencies checks read workflow files via the Actions API |

`id-token: write` is intentionally **not** required — this workflow doesn't sign or upload anything to the public dashboard, so OIDC issuance is unnecessary. Granting it would expose a high-impact cloud-auth primitive on every weekly run for no functional benefit. (The public variant does require `id-token: write` because Scorecard signs results before uploading them.)

No secrets required — Scorecard runs entirely with the workflow's own `GITHUB_TOKEN`.

**Versioning:** Callers pin with `@scorecard-v1` (or harden with an immutable `scorecard-vX.Y.Z` tag / commit SHA — see [Versioning & releases](#versioning--releases)). The reusable workflow SHA-pins `ossf/scorecard-action` to the latest stable tag (currently v2.4.3) and tracks `actions/*` and `github/*` at major-version tags per the actions-audit policy.

#### Public (`scorecard-public.yml`)

Public Scorecard scan: runs Scorecard against the calling repo on a weekly schedule, **publishes the signed results to OpenSSF's public dashboard at [securityscorecards.dev](https://securityscorecards.dev)** so the repo earns the public Scorecard badge, and uploads the SARIF findings to GitHub Code Scanning so they also appear in the repo's **Security** tab. Raw SARIF is kept as a workflow artifact for 14 days (shorter than the internal variant's 30 days because published results already live on the public dashboard for long-term reference).

> **OSS only.** Use this workflow only for public OSS repos that should appear on the public Scorecard dashboard. For internal/private repos — or public repos that don't want a public badge — use [`scorecard.yml`](#internal-scorecardyml) instead.

**1. Add the caller workflow** to each public-OSS repo at `.github/workflows/scorecard-public.yml`. Copy-paste-ready version at [`examples/caller-scorecard-public.yml`](examples/caller-scorecard-public.yml).

**2. Scheduling lives in the caller, not the reusable workflow.** Same rationale as the internal variant — `workflow_call` can't dictate cron to its parent. The example caller wires `schedule` (Monday 06:00 UTC), `workflow_dispatch`, and `branch_protection_rule`.

**3. Inputs:** None. The reusable workflow always runs Scorecard, publishes results to the public dashboard, emits SARIF, uploads it to Code Scanning, and stashes the raw SARIF as an artifact. There's nothing to configure per-call — and intentionally so (see the publish-API constraints below).

**4. Required permissions on the calling job:**

| Permission | Why |
|---|---|
| `contents: read` | Scorecard reads repo files, branch protection, releases |
| `security-events: write` | SARIF upload to Code Scanning |
| `id-token: write` | Scorecard signs results with an OIDC token before uploading to securityscorecards.dev. This is the documented use of OIDC in the upstream Scorecard publish-flow template |
| `actions: read` | Scorecard's Token-Permissions / Pinned-Dependencies checks read workflow files via the Actions API |

No secrets required — Scorecard runs entirely with the workflow's own `GITHUB_TOKEN` (plus the OIDC token minted at job time).

**5. Publish-API constraints (do NOT violate when editing this workflow):**

Scorecard's publish endpoint (`post_results.go` in the upstream Scorecard repo) inspects the workflow YAML before accepting results. Workflows that don't match its expected shape get their results silently rejected. Future maintainers should treat the following as hard constraints:

- **No workflow-level `permissions:` block.** Scorecard rejects results from any workflow that grants write permissions at the workflow level. All permissions live at job level only — in both the reusable workflow and the caller. Adding even a read-only workflow-level block invites future drift toward broader scope and is forbidden by policy here.
- **Steps come ONLY from Scorecard's allowlist:**
  - `actions/checkout`
  - `actions/upload-artifact`
  - `github/codeql-action/upload-sarif`
  - `ossf/scorecard-action`
  - `step-security/harden-runner`

  No custom `run:` shell steps. No other actions. No matrix. No inputs that would require validation steps. The workflow is a clean four-step pipeline by design — keep it that way. If you need richer behavior (e.g. cosign-signing artifacts, posting Slack notifications), do it in a **separate** workflow that runs after this one, not by adding steps here.
- **`publish_results: true` is mandatory.** That's the whole point of this workflow. Flipping it to `false` silently turns this into a worse copy of the internal `scorecard.yml`.

**Versioning:** Callers pin with `@scorecard-public-v1` (or harden with an immutable `scorecard-public-vX.Y.Z` tag / commit SHA — see [Versioning & releases](#versioning--releases)). The reusable workflow SHA-pins `ossf/scorecard-action` to the same tag as the internal variant (currently v2.4.3) and tracks `actions/*` and `github/*` at major-version tags per the actions-audit policy.
