# Changelog

## [1.11.0](https://github.com/SpiceLabsHQ/.github/compare/pepper-pr-review-v1.10.0...pepper-pr-review-v1.11.0) (2026-08-21)


### Features

* **pepper:** review against released Eng-Cookbook standards ([#195](https://github.com/SpiceLabsHQ/.github/issues/195)) ([28b6096](https://github.com/SpiceLabsHQ/.github/commit/28b6096b8b9989bbe801098edc328eee35b1cb15))


### Bug Fixes

* **pepper:** read a cross-repo 404 as unverifiable, not missing ([#194](https://github.com/SpiceLabsHQ/.github/issues/194)) ([c51e210](https://github.com/SpiceLabsHQ/.github/commit/c51e210b804cb0be3366c6e18dd4d0d9ca303314))

## [1.10.0](https://github.com/SpiceLabsHQ/.github/compare/pepper-pr-review-v1.9.0...pepper-pr-review-v1.10.0) (2026-08-09)


### Features

* **pepper-pr-review:** emit a per-run audit record to CloudWatch (DEV-653) ([#184](https://github.com/SpiceLabsHQ/.github/issues/184)) ([e34b6e6](https://github.com/SpiceLabsHQ/.github/commit/e34b6e67e17ac1aad0faeb520732090789b3746c))


### Bug Fixes

* **pepper-pr-review:** mint App tokens with client-id, not the deprecated app-id ([#187](https://github.com/SpiceLabsHQ/.github/issues/187)) ([402b45d](https://github.com/SpiceLabsHQ/.github/commit/402b45dc70e05a538b859f2ea3e01da61349bb58))

## [1.9.0](https://github.com/SpiceLabsHQ/.github/compare/pepper-pr-review-v1.8.0...pepper-pr-review-v1.9.0) (2026-08-07)


### Features

* **pepper-pr-review:** remove the inert trigger_phrase input ([#181](https://github.com/SpiceLabsHQ/.github/issues/181)) ([bedee13](https://github.com/SpiceLabsHQ/.github/commit/bedee13d1cdbf8e1868045f0d49cc31d6a047aba))

## [1.8.0](https://github.com/SpiceLabsHQ/.github/compare/pepper-pr-review-v1.7.0...pepper-pr-review-v1.8.0) (2026-08-07)


### Features

* **pepper-pr-review:** remove dead on-demand mode ([#180](https://github.com/SpiceLabsHQ/.github/issues/180)) ([897b52d](https://github.com/SpiceLabsHQ/.github/commit/897b52d1c5ea875c2dc346acfbe82cd8d1e11931))


### Bug Fixes

* **pepper-pr-review:** bound the collapse step with a non-fatal timeout (DEV-674) ([#177](https://github.com/SpiceLabsHQ/.github/issues/177)) ([13cc6ca](https://github.com/SpiceLabsHQ/.github/commit/13cc6caa483dc88bc91d04fb969c57cf9679771d))

## [1.7.0](https://github.com/SpiceLabsHQ/.github/compare/pepper-pr-review-v1.6.0...pepper-pr-review-v1.7.0) (2026-07-29)


### Features

* **pepper-pr-review:** add author-class `flavor` axis orthogonal to `mode` (DEV-672) ([#163](https://github.com/SpiceLabsHQ/.github/issues/163)) ([ceba188](https://github.com/SpiceLabsHQ/.github/commit/ceba188069cb9423aeed1e9601461a58d35bbf59))
* **pepper-pr-review:** collapse bot-PR change requests in the workflow (DEV-674) ([#165](https://github.com/SpiceLabsHQ/.github/issues/165)) ([b51c427](https://github.com/SpiceLabsHQ/.github/commit/b51c427146d579c99d1102afad978ac1fa47186a))
* **pepper-pr-review:** dependency review template and risk model (DEV-673) ([#164](https://github.com/SpiceLabsHQ/.github/issues/164)) ([4a27792](https://github.com/SpiceLabsHQ/.github/commit/4a2779267cc1fe09e9eec0930e46e1e7a5e52584))
* **pepper-pr-review:** stamp the reviewed head SHA on review output (DEV-721) ([#170](https://github.com/SpiceLabsHQ/.github/issues/170)) ([4b0b0ab](https://github.com/SpiceLabsHQ/.github/commit/4b0b0ab2a0e5779c4f4ba4dcd0984617a0213ae6))

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
