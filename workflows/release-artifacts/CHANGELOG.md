# Changelog

## [1.0.3](https://github.com/SpiceLabsHQ/.github/compare/release-artifacts-v1.0.2...release-artifacts-v1.0.3) (2026-09-04)


### Bug Fixes

* **deps:** update anchore/sbom-action action to v0.24.1 ([#245](https://github.com/SpiceLabsHQ/.github/issues/245)) ([1075b09](https://github.com/SpiceLabsHQ/.github/commit/1075b097125128eb2b24a5ca16d37e5bf58a3187))

## [1.0.2](https://github.com/SpiceLabsHQ/.github/compare/release-artifacts-v1.0.1...release-artifacts-v1.0.2) (2026-08-22)


### Bug Fixes

* **deps:** route workflow action pins through per-package pins files ([#218](https://github.com/SpiceLabsHQ/.github/issues/218)) ([ad15be1](https://github.com/SpiceLabsHQ/.github/commit/ad15be11a8225abd28234d1c0f385888365a8059))

## [1.0.1](https://github.com/SpiceLabsHQ/.github/compare/release-artifacts-v1.0.0...release-artifacts-v1.0.1) (2026-07-04)


### Bug Fixes

* **deps:** update actions/checkout action to v7 ([#61](https://github.com/SpiceLabsHQ/.github/issues/61)) ([f01862d](https://github.com/SpiceLabsHQ/.github/commit/f01862db624a28bce16f535b3c29a8b036927904))

## 1.0.0 (2026-07-03)

Baseline release establishing per-workflow versioning ([DEV-408]). Functionally
identical to the legacy shared `v1` tag as of commit `60a48c1`. From here on,
`release-artifacts` versions independently: immutable tags `release-artifacts-vX.Y.Z` plus the
floating major alias `release-artifacts-v1`.

[DEV-408]: https://linear.app/spicelabshq/issue/DEV-408
