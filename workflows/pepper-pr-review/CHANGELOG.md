# Changelog

## [1.4.0](https://github.com/SpiceLabsHQ/.github/compare/pepper-pr-review-v1.3.0...pepper-pr-review-v1.4.0) (2026-07-06)


### Features

* **pepper-pr-review:** feed diff coverage to review as a non-gating input (DEV-526) ([081b9e2](https://github.com/SpiceLabsHQ/.github/commit/081b9e24ceb48ff73d43481a26db4bdfe9c2fe6e))

## [1.3.0](https://github.com/SpiceLabsHQ/.github/compare/pepper-pr-review-v1.2.1...pepper-pr-review-v1.3.0) (2026-07-06)


### Features

* **pepper-pr-review:** short-circuit re-review when head SHA is unchanged (DEV-523) ([#118](https://github.com/SpiceLabsHQ/.github/issues/118)) ([dbeb644](https://github.com/SpiceLabsHQ/.github/commit/dbeb6440149ace79ad7375f1826ec83286949a65))
* **pepper:** escalate to the `reviewers` team, not an individual (DEV-524) ([#119](https://github.com/SpiceLabsHQ/.github/issues/119)) ([4b72c61](https://github.com/SpiceLabsHQ/.github/commit/4b72c61577cea828b173102566b78497e5a2b882))


### Bug Fixes

* **pepper-pr-review:** fetch prompt from workflow's own SHA, not frozen v1 (DEV-235) ([#115](https://github.com/SpiceLabsHQ/.github/issues/115)) ([dcb2e72](https://github.com/SpiceLabsHQ/.github/commit/dcb2e724212e483ba2efa08f27d8280358577230))
* **pepper-pr-review:** native read/search tools + guardrails for review mode (DEV-235) ([#112](https://github.com/SpiceLabsHQ/.github/issues/112)) ([6d67628](https://github.com/SpiceLabsHQ/.github/commit/6d67628a02eebb14d22599c0439e85830d49259e))

## [1.2.1](https://github.com/SpiceLabsHQ/.github/compare/pepper-pr-review-v1.2.0...pepper-pr-review-v1.2.1) (2026-07-05)


### Bug Fixes

* **pepper-pr-review:** skip cleanly on non-allowlisted bot initiators (DEV-504) ([#103](https://github.com/SpiceLabsHQ/.github/issues/103)) ([dce0ab2](https://github.com/SpiceLabsHQ/.github/commit/dce0ab2df53ff092538c55d9dc14a4112c1cf328))

## [1.2.0](https://github.com/SpiceLabsHQ/.github/compare/pepper-pr-review-v1.1.2...pepper-pr-review-v1.2.0) (2026-07-04)


### Features

* **deps:** update actions/create-github-app-token action to v3.2.0 ([#72](https://github.com/SpiceLabsHQ/.github/issues/72)) ([19450f4](https://github.com/SpiceLabsHQ/.github/commit/19450f4e43dc37ba95b8530322431d15ee5fca5b))
* **deps:** update aws-actions/configure-aws-credentials action to v6 ([#78](https://github.com/SpiceLabsHQ/.github/issues/78)) ([596873b](https://github.com/SpiceLabsHQ/.github/commit/596873ba963ecda6f92a3142dc2a7874d6508a80))

## [1.1.2](https://github.com/SpiceLabsHQ/.github/compare/pepper-pr-review-v1.1.1...pepper-pr-review-v1.1.2) (2026-07-04)


### Bug Fixes

* **deps:** update actions/checkout action to v7 ([#61](https://github.com/SpiceLabsHQ/.github/issues/61)) ([f01862d](https://github.com/SpiceLabsHQ/.github/commit/f01862db624a28bce16f535b3c29a8b036927904))

## [1.1.1](https://github.com/SpiceLabsHQ/.github/compare/pepper-pr-review-v1.1.0...pepper-pr-review-v1.1.1) (2026-07-04)


### Bug Fixes

* **pepper-pr-review:** allow Renovate and Dependabot to trigger reviews [DEV-494] ([#59](https://github.com/SpiceLabsHQ/.github/issues/59)) ([80a01a0](https://github.com/SpiceLabsHQ/.github/commit/80a01a045a6973b75d2d7d87cfdc10aa79a92e3b))

## [1.1.0](https://github.com/SpiceLabsHQ/.github/compare/pepper-pr-review-v1.0.0...pepper-pr-review-v1.1.0) (2026-07-04)


### Features

* **pepper-pr-review:** default to Claude Sonnet 5 via new tagged inference profiles [DEV-492] ([#50](https://github.com/SpiceLabsHQ/.github/issues/50)) ([30eb0f6](https://github.com/SpiceLabsHQ/.github/commit/30eb0f66cfd752d93243f8652d9d655b3da3173e))

## 1.0.0 (2026-07-03)

Baseline release establishing per-workflow versioning ([DEV-408]). Functionally
identical to the legacy shared `v1` tag as of commit `60a48c1`. From here on,
`pepper-pr-review` versions independently: immutable tags `pepper-pr-review-vX.Y.Z` plus the
floating major alias `pepper-pr-review-v1`.

[DEV-408]: https://linear.app/spicelabshq/issue/DEV-408
