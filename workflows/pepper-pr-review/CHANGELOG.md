# Changelog

## [1.6.0](https://github.com/SpiceLabsHQ/.github/compare/pepper-pr-review-v1.5.1...pepper-pr-review-v1.6.0) (2026-07-26)


### Features

* **pepper-pr-review:** post draft-only guidance comment (DEV-666) ([#154](https://github.com/SpiceLabsHQ/.github/issues/154)) ([4b19a6f](https://github.com/SpiceLabsHQ/.github/commit/4b19a6ff335f2f6cdf2f5d177d07f463ee773c0b))


### Bug Fixes

* **pepper-pr-review:** advise pushing a commit for re-review, not commenting ([#148](https://github.com/SpiceLabsHQ/.github/issues/148)) ([52c0471](https://github.com/SpiceLabsHQ/.github/commit/52c047146b367e491c289bee846732786a5910c3))
* **pepper-pr-review:** stop ruling on CI status (DEV-637) ([#156](https://github.com/SpiceLabsHQ/.github/issues/156)) ([72a08db](https://github.com/SpiceLabsHQ/.github/commit/72a08db0749cd6ad7c4012c9ee140ccbb86f9c95))

## [1.5.1](https://github.com/SpiceLabsHQ/.github/compare/pepper-pr-review-v1.5.0...pepper-pr-review-v1.5.1) (2026-07-12)


### Bug Fixes

* **pepper-pr-review:** stop concurrency group racing across callers (DEV-561) ([#143](https://github.com/SpiceLabsHQ/.github/issues/143)) ([d8a23b0](https://github.com/SpiceLabsHQ/.github/commit/d8a23b0e1e1d97590c3209c8ab71e978766169be))

## [1.5.0](https://github.com/SpiceLabsHQ/.github/compare/pepper-pr-review-v1.4.0...pepper-pr-review-v1.5.0) (2026-07-07)


### Features

* **pepper-pr-review:** configurable review timeout + advertise budget to prompt (DEV-534) ([#136](https://github.com/SpiceLabsHQ/.github/issues/136)) ([c32bf5f](https://github.com/SpiceLabsHQ/.github/commit/c32bf5f765f1b6755544b10ef3d539f0290db659))

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
