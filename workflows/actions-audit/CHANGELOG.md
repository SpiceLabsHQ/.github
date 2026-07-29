# Changelog

## [1.3.0](https://github.com/SpiceLabsHQ/.github/compare/actions-audit-v1.2.0...actions-audit-v1.3.0) (2026-07-29)


### Features

* **pepper-pr-review:** stamp the reviewed head SHA on review output (DEV-721) ([#170](https://github.com/SpiceLabsHQ/.github/issues/170)) ([4b0b0ab](https://github.com/SpiceLabsHQ/.github/commit/4b0b0ab2a0e5779c4f4ba4dcd0984617a0213ae6))

## [1.2.0](https://github.com/SpiceLabsHQ/.github/compare/actions-audit-v1.1.2...actions-audit-v1.2.0) (2026-07-06)


### Features

* **ci:** auto-merge coverage dashboard + first-party allow_tags_for fix (DEV-505) ([#105](https://github.com/SpiceLabsHQ/.github/issues/105)) ([9840c45](https://github.com/SpiceLabsHQ/.github/commit/9840c4521ed77771b8244c5b34d193b49ec7cb8f))

## [1.1.2](https://github.com/SpiceLabsHQ/.github/compare/actions-audit-v1.1.1...actions-audit-v1.1.2) (2026-07-05)


### Bug Fixes

* **actions-audit:** repair broken zizmor invocation + align pinning policy (DEV-503) ([#101](https://github.com/SpiceLabsHQ/.github/issues/101)) ([d531b0c](https://github.com/SpiceLabsHQ/.github/commit/d531b0c2ebe5d3782b5baed7748129312dcfca9b))

## [1.1.1](https://github.com/SpiceLabsHQ/.github/compare/actions-audit-v1.1.0...actions-audit-v1.1.1) (2026-07-04)


### Bug Fixes

* gate SARIF uploads to public repos (sast, actions-audit, scorecard) ([#89](https://github.com/SpiceLabsHQ/.github/issues/89)) ([049cdd5](https://github.com/SpiceLabsHQ/.github/commit/049cdd5f168deb0eaff59676985603bee3a82943))

## [1.1.0](https://github.com/SpiceLabsHQ/.github/compare/actions-audit-v1.0.1...actions-audit-v1.1.0) (2026-07-04)


### Features

* **deps:** update github/codeql-action action to v4 ([#79](https://github.com/SpiceLabsHQ/.github/issues/79)) ([bc8086f](https://github.com/SpiceLabsHQ/.github/commit/bc8086f078a9832004ef6ad62849769f44753d8f))

## [1.0.1](https://github.com/SpiceLabsHQ/.github/compare/actions-audit-v1.0.0...actions-audit-v1.0.1) (2026-07-04)


### Bug Fixes

* **deps:** update actions/checkout action to v7 ([#61](https://github.com/SpiceLabsHQ/.github/issues/61)) ([f01862d](https://github.com/SpiceLabsHQ/.github/commit/f01862db624a28bce16f535b3c29a8b036927904))
* **deps:** update astral-sh/setup-uv action to v8.2.0 ([#57](https://github.com/SpiceLabsHQ/.github/issues/57)) ([e20e784](https://github.com/SpiceLabsHQ/.github/commit/e20e78432259298aab74447569d19586c553df64))

## 1.0.0 (2026-07-03)

Baseline release establishing per-workflow versioning ([DEV-408]). Functionally
identical to the legacy shared `v1` tag as of commit `60a48c1`. From here on,
`actions-audit` versions independently: immutable tags `actions-audit-vX.Y.Z` plus the
floating major alias `actions-audit-v1`.

[DEV-408]: https://linear.app/spicelabshq/issue/DEV-408
