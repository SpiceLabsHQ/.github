# Changelog

## [1.2.0](https://github.com/SpiceLabsHQ/.github/compare/sast-v1.1.1...sast-v1.2.0) (2026-07-29)


### Features

* **pepper-pr-review:** stamp the reviewed head SHA on review output (DEV-721) ([#170](https://github.com/SpiceLabsHQ/.github/issues/170)) ([4b0b0ab](https://github.com/SpiceLabsHQ/.github/commit/4b0b0ab2a0e5779c4f4ba4dcd0984617a0213ae6))

## [1.1.1](https://github.com/SpiceLabsHQ/.github/compare/sast-v1.1.0...sast-v1.1.1) (2026-07-04)


### Bug Fixes

* gate SARIF uploads to public repos (sast, actions-audit, scorecard) ([#89](https://github.com/SpiceLabsHQ/.github/issues/89)) ([049cdd5](https://github.com/SpiceLabsHQ/.github/commit/049cdd5f168deb0eaff59676985603bee3a82943))

## [1.1.0](https://github.com/SpiceLabsHQ/.github/compare/sast-v1.0.1...sast-v1.1.0) (2026-07-04)


### Features

* **deps:** update actions/setup-python action to v6 ([#76](https://github.com/SpiceLabsHQ/.github/issues/76)) ([4326d12](https://github.com/SpiceLabsHQ/.github/commit/4326d12028f40563c7eaf0398eddbc4086854269))
* **deps:** update github/codeql-action action to v4 ([#79](https://github.com/SpiceLabsHQ/.github/issues/79)) ([bc8086f](https://github.com/SpiceLabsHQ/.github/commit/bc8086f078a9832004ef6ad62849769f44753d8f))

## [1.0.1](https://github.com/SpiceLabsHQ/.github/compare/sast-v1.0.0...sast-v1.0.1) (2026-07-04)


### Bug Fixes

* **deps:** update actions/checkout action to v7 ([#61](https://github.com/SpiceLabsHQ/.github/issues/61)) ([f01862d](https://github.com/SpiceLabsHQ/.github/commit/f01862db624a28bce16f535b3c29a8b036927904))
* **deps:** update dependency python to 3.14 ([#60](https://github.com/SpiceLabsHQ/.github/issues/60)) ([2d1296f](https://github.com/SpiceLabsHQ/.github/commit/2d1296f526955aa757738d9c30f7d6ee7c470ad8))

## 1.0.0 (2026-07-03)

Baseline release establishing per-workflow versioning ([DEV-408]). Functionally
identical to the legacy shared `v1` tag as of commit `60a48c1`. From here on,
`sast` versions independently: immutable tags `sast-vX.Y.Z` plus the
floating major alias `sast-v1`.

[DEV-408]: https://linear.app/spicelabshq/issue/DEV-408
