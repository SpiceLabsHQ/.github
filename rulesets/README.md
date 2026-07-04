# Org CI floor rulesets (DEV-499)

Infrastructure-as-code for the organization rulesets that enforce the CI floor.
These are **organization** rulesets (source: `SpiceLabsHQ`), applied with
[`scripts/apply-ci-floor-rulesets.sh`](../scripts/apply-ci-floor-rulesets.sh).
See the [CI floor & maturity ladder](../README.md#ci-floor--maturity-ladder)
section for the standard these enforce.

## The rulesets

| File | Ruleset | Targets | Requires |
|---|---|---|---|
| `spice-ci-floor-docs.json` | `spice-ci-floor-docs` | repos with property `ci-exception = docs` | `floor-hygiene`, `floor-secret-scan` |
| `spice-ci-floor-code.json` | `spice-ci-floor-code` | all repos **except** `.github` and `docs`-tagged | `floor-hygiene`, `floor-secret-scan`, `floor-sast`, `floor-pepper`, `floor-automerge` |
| `spice-ci-floor-public.json` | `spice-ci-floor-public` | the public repos (enumerated) | `floor-public` (scorecard-public; codeql + dependency-review are per-repo Silver guidance) |

Each ruleset uses GitHub's **"require workflows to pass"** rule to run the
central `floor-*.yml` workflows (in this repo, at `refs/heads/main`) on PRs in
the targeted repos — zero per-repo installation. `repository_id: 1150169232` is
this `.github` repo (where the floor workflows live).

## Mechanism notes

- **Team-plan verified:** the `workflows` rule type and `evaluate` (dry-run)
  enforcement both work on the org's Team plan (probed 2026-07-04).
- **`.github` is excluded** from the code floor and public overlay — it
  self-hosts the same checks via its `self-*` / `pepper-self-review` callers.
  The floor workflows also self-skip there (guarded on `github.repository`).
- **Renovate is floor but not here:** a ruleset can't require a *file* to
  exist, so `renovate.json` is enforced by the audit + dashboard, not a rule.
- **Public overlay targeting is enumerated** (rulesets have no visibility
  condition). When a public repo is added, add it here; the org-ci-audit
  dashboard flags drift.

## Staged rollout (the safe order)

Prereq: the `floor-*.yml` workflows must be merged to `main` first (GitHub
validates the workflow ref when the ruleset is created).

1. **Docs floor first** (smallest blast radius — proves property targeting on
   the handful of `docs` repos):
   ```bash
   # dry-run: non-blocking, produces rule insights on real PRs
   scripts/apply-ci-floor-rulesets.sh --evaluate rulesets/spice-ci-floor-docs.json
   # verify a PR in a docs repo runs floor-hygiene + floor-secret-scan against it, then:
   scripts/apply-ci-floor-rulesets.sh --active rulesets/spice-ci-floor-docs.json
   ```
2. **Code floor** (the bulk). Dry-run, confirm the untagged repos are matched
   and `.github` / `docs` repos are not, then flip active:
   ```bash
   scripts/apply-ci-floor-rulesets.sh --evaluate rulesets/spice-ci-floor-code.json
   scripts/apply-ci-floor-rulesets.sh --active  rulesets/spice-ci-floor-code.json
   ```
   > Watch the Pepper-as-required-check interaction with bot-initiated events
   > (rosemary-releaser is skipped in `floor-pepper.yml`; other bots touching a
   > human PR remain a known risk tracked with DEV-493). Consider flipping the
   > Pepper workflow into the code-floor list last.
3. **Public overlay** (additive):
   ```bash
   scripts/apply-ci-floor-rulesets.sh --evaluate rulesets/spice-ci-floor-public.json
   scripts/apply-ci-floor-rulesets.sh --active  rulesets/spice-ci-floor-public.json
   ```

Re-running the script updates an existing ruleset in place (upsert by name); it
never touches `spice-branch-protection`.

## Auto-merge rollout (DEV-502)

Pepper-gated auto-merge on every PR. The **code artifacts** (the shared Renovate
preset `default.json`, this repo's `renovate.json` extending it,
`floor-automerge.yml`, and `floor-automerge` added to `spice-ci-floor-code.json`)
ship in the DEV-502 PR. The steps below are the **live, org-wide mutations** a
human applies after that PR merges to `main` — outward-facing and staged on
purpose. See [Auto-merge policy](../README.md#auto-merge-policy-pepper-gated-dev-502)
for the philosophy.

**Prereq:** `floor-automerge.yml` must be on `main` first (GitHub validates the
workflow ref when the ruleset references it).

1. **The unlock — drop `require_code_owner_review` from `spice-branch-protection`
   (id `12466693`).** Keeps `required_approving_review_count: 1` and
   `require_last_push_approval: true`, so Pepper's approval becomes sufficient
   while its deferral (no approval) still forces a human. This ruleset is **not**
   managed by `apply-ci-floor-rulesets.sh`; apply it directly, reading the live
   value and flipping only the one flag:

   ```bash
   gh api /orgs/SpiceLabsHQ/rulesets/12466693 \
     | jq '(.rules[] | select(.type=="pull_request") | .parameters.require_code_owner_review) = false
           | {name, target, enforcement, conditions, rules, bypass_actors}' \
     | gh api -X PUT /orgs/SpiceLabsHQ/rulesets/12466693 --input -
   ```

   > ⚠️ **Solo-reviewer trap** (DEV-498 / project memory): with
   > `require_last_push_approval`, pushing to a PR branch with your *own* creds
   > invalidates your approval. Prefer bot pushes; else admin-merge with
   > authorization.

2. **Register `floor-automerge` on the code floor.** It's already in
   `spice-ci-floor-code.json`. Because the code floor is already **active**,
   re-apply it **directly with `--active`** — do *not* pass `--evaluate`, which
   would regress the whole live floor (pepper/sast/…) to non-blocking. The added
   `floor-automerge` job is best-effort and cannot deadlock merge, so the direct
   apply is low-risk:

   ```bash
   scripts/apply-ci-floor-rulesets.sh --active rulesets/spice-ci-floor-code.json
   ```

3. **Enable `allow_auto_merge` per repo** where missing (already on `.github`,
   `Reaper`, `Lumen-BI`):

   ```bash
   gh api -X PATCH /repos/SpiceLabsHQ/<repo> -F allow_auto_merge=true
   ```

4. **Prove end-to-end on `Reaper` first** (public, no CODEOWNERS → simplest
   proof) before trusting it org-wide: open a trivial PR, confirm Pepper reviews
   it, that a high-confidence approval fires the merge with no human click, and
   that forcing a deferral makes the PR wait for `@SpiceLabsHQ/reviewers`.

5. **Gate on repo tests where they exist** (Step 3 of the plan): make each repo's
   test CI a required status check — org ruleset `required_status_checks` by
   check name, or a floor-style required workflow. Objective correctness backstop
   for changes Pepper structurally can't fully judge (e.g. a lockfile bump).

Then monitor Pepper's approve-vs-defer precision — the load-bearing trust
boundary — and extend the org-ci-audit dashboard (issue #98) to surface
auto-merge coverage per repo.
