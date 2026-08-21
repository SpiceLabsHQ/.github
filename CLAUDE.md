# CLAUDE.md

This repository maintains the `.github` repo for the **SpiceLabsHQ** GitHub organization (`SpiceLabsHQ/.github`).

The `.github` repo is a special GitHub repository that provides organization-level defaults such as:
- Organization profile README (displayed on the org's GitHub page)
- Default community health files (issue templates, PR templates, contributing guidelines, etc.)
- Reusable GitHub Actions workflows

## CI app identities and secrets

The written policy for GitHub App identities, permission scoping, and CI secret naming lives in the
Eng-Cookbook (the "what/why"); this repo is its enforcement. Before wiring a workflow to an App token or
adding an `*_APP_ID` / `*_APP_PRIVATE_KEY` secret, follow it:

- **Standard:** [Secrets and configuration](https://github.com/SpiceLabsHQ/Eng-Cookbook/blob/main/standards/secrets-and-configuration.md)
  — each App is scoped to only the permissions it needs, no workflow consumes another App's credentials, and
  the `<PURPOSE>_APP_*` naming / org-level-secret rules.
- **Decision:** [ADR-0007 — Dedicated, least-privilege GitHub Apps for CI](https://github.com/SpiceLabsHQ/Eng-Cookbook/blob/main/decisions/ADR-0007-least-privilege-ci-apps.md)

## Pepper review audit data

Every Pepper PR review writes one structured record — configuration, outcome,
tokens, cost — to the CloudWatch log group `/pepper/pr-review/audit`. Read it
before answering any question about what a review cost, how often Pepper
escalates, or whether a change to the prompt, the model, the reasoning effort or
the claude-cli version moved either.

- **Query pack:** [`docs/pepper-audit.md`](docs/pepper-audit.md) — the schema and
  working CloudWatch Logs Insights queries. Readable today with the existing
  read-only SSO profile (`spice-ro`, `us-west-2`); no new access needed.
- **Infrastructure:** [`infrastructure/README.md`](infrastructure/README.md) —
  deploying the log group and its missing-records alarm, and the IAM statement
  that lets the review job write.

Note that `cost_usd` may be `null`: the capture step never invents a price, so
cost is derived from the token split at query time.

## Renovate policy lives in two repos

Changing org Renovate policy usually means touching one of two files, and they
are not interchangeable:

- [`default.json`](default.json) (this repo) — the **shared preset**. Opt-in: a
  repo receives it only by naming it in `"extends": ["github>SpiceLabsHQ/.github"]`.
- `org-inherited-config.json` in
  [`SpiceLabsHQ/renovate-config`](https://github.com/SpiceLabsHQ/renovate-config)
  — the **org-inherited config** (DEV-1140). Renovate reads it for every repo
  *before* that repo's own config, so it reaches repos with no config at all.
  It extends the preset above, so a preset edit changes both paths at once.

Put dependency policy in the preset. Put org-wide bot behaviour that would be
surprising in an explicit `extends` — onboarding config, silent/full mode — in
the inherited config. Neither file can carry per-repo rules; those belong in the
repo's own `renovate.json`, which is merged over both and wins on conflict.

A per-repo `renovate.json` is still a MUST under `dependency-management.md`
rule 2. The inherited config removes the *silent* failure mode, not the rule.
