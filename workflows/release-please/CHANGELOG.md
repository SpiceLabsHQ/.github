# Changelog

## [1.1.2](https://github.com/SpiceLabsHQ/.github/compare/release-please-v1.1.1...release-please-v1.1.2) (2026-08-22)


### Bug Fixes

* **deps:** route workflow action pins through per-package pins files ([#218](https://github.com/SpiceLabsHQ/.github/issues/218)) ([ad15be1](https://github.com/SpiceLabsHQ/.github/commit/ad15be11a8225abd28234d1c0f385888365a8059))

## [1.1.1](https://github.com/SpiceLabsHQ/.github/compare/release-please-v1.1.0...release-please-v1.1.1) (2026-07-07)


### Bug Fixes

* **release-please:** prevent phantom duplicate release PRs via two-pass run with consistency barrier (DEV-533) ([#129](https://github.com/SpiceLabsHQ/.github/issues/129)) ([9443123](https://github.com/SpiceLabsHQ/.github/commit/944312303f96fcbdfed111b7decaacce4af56a12))

## [1.1.0](https://github.com/SpiceLabsHQ/.github/compare/release-please-v1.0.0...release-please-v1.1.0) (2026-07-04)


### Features

* **deps:** update actions/create-github-app-token action to v3.2.0 ([#72](https://github.com/SpiceLabsHQ/.github/issues/72)) ([19450f4](https://github.com/SpiceLabsHQ/.github/commit/19450f4e43dc37ba95b8530322431d15ee5fca5b))

## 1.0.0 (2026-07-03)

Baseline release establishing per-workflow versioning ([DEV-408]). Functionally
identical to the legacy shared `v1` tag as of commit `60a48c1`. From here on,
`release-please` versions independently: immutable tags `release-please-vX.Y.Z` plus the
floating major alias `release-please-v1`.

[DEV-408]: https://linear.app/spicelabshq/issue/DEV-408
