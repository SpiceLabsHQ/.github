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
| `spice-ci-floor-code.json` | `spice-ci-floor-code` | all repos **except** `.github` and `docs`-tagged | `floor-hygiene`, `floor-secret-scan`, `floor-sast`, `floor-pepper` |
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
