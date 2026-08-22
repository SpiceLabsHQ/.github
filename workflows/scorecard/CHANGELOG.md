# Changelog

## [1.2.1](https://github.com/SpiceLabsHQ/.github/compare/scorecard-v1.2.0...scorecard-v1.2.1) (2026-08-22)


### Bug Fixes

* **deps:** route workflow action pins through per-package pins files ([#218](https://github.com/SpiceLabsHQ/.github/issues/218)) ([ad15be1](https://github.com/SpiceLabsHQ/.github/commit/ad15be11a8225abd28234d1c0f385888365a8059))

## [1.2.0](https://github.com/SpiceLabsHQ/.github/compare/scorecard-v1.1.1...scorecard-v1.2.0) (2026-07-29)


### Features

* **pepper-pr-review:** stamp the reviewed head SHA on review output (DEV-721) ([#170](https://github.com/SpiceLabsHQ/.github/issues/170)) ([4b0b0ab](https://github.com/SpiceLabsHQ/.github/commit/4b0b0ab2a0e5779c4f4ba4dcd0984617a0213ae6))

## [1.1.1](https://github.com/SpiceLabsHQ/.github/compare/scorecard-v1.1.0...scorecard-v1.1.1) (2026-07-06)


### Bug Fixes

* gate SARIF uploads to public repos (sast, actions-audit, scorecard) ([#89](https://github.com/SpiceLabsHQ/.github/issues/89)) ([049cdd5](https://github.com/SpiceLabsHQ/.github/commit/049cdd5f168deb0eaff59676985603bee3a82943))

## [1.1.0](https://github.com/SpiceLabsHQ/.github/compare/scorecard-v1.0.1...scorecard-v1.1.0) (2026-07-04)


### Features

* **deps:** update actions/upload-artifact action to v7 ([#77](https://github.com/SpiceLabsHQ/.github/issues/77)) ([57cef1e](https://github.com/SpiceLabsHQ/.github/commit/57cef1eef3033551c0a826454a18f8087dce36f6))
* **deps:** update github/codeql-action action to v4 ([#79](https://github.com/SpiceLabsHQ/.github/issues/79)) ([bc8086f](https://github.com/SpiceLabsHQ/.github/commit/bc8086f078a9832004ef6ad62849769f44753d8f))

## [1.0.1](https://github.com/SpiceLabsHQ/.github/compare/scorecard-v1.0.0...scorecard-v1.0.1) (2026-07-04)


### Bug Fixes

* **deps:** update actions/checkout action to v7 ([#61](https://github.com/SpiceLabsHQ/.github/issues/61)) ([f01862d](https://github.com/SpiceLabsHQ/.github/commit/f01862db624a28bce16f535b3c29a8b036927904))

## 1.0.0 (2026-07-03)

Baseline release establishing per-workflow versioning ([DEV-408]). Functionally
identical to the legacy shared `v1` tag as of commit `60a48c1`. From here on,
`scorecard` versions independently: immutable tags `scorecard-vX.Y.Z` plus the
floating major alias `scorecard-v1`.

[DEV-408]: https://linear.app/spicelabshq/issue/DEV-408
