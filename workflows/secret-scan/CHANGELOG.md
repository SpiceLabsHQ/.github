# Changelog

## [1.1.1](https://github.com/SpiceLabsHQ/.github/compare/secret-scan-v1.1.0...secret-scan-v1.1.1) (2026-08-21)


### Bug Fixes

* **secret-scan:** key the concurrency group on the calling workflow (DEV-1181) ([#210](https://github.com/SpiceLabsHQ/.github/issues/210)) ([35cd554](https://github.com/SpiceLabsHQ/.github/commit/35cd55426f1f4df7132729a1eb5ee0aec09b1a35))

## [1.1.0](https://github.com/SpiceLabsHQ/.github/compare/secret-scan-v1.0.1...secret-scan-v1.1.0) (2026-07-04)


### Features

* **deps:** update github/codeql-action action to v4 ([#79](https://github.com/SpiceLabsHQ/.github/issues/79)) ([bc8086f](https://github.com/SpiceLabsHQ/.github/commit/bc8086f078a9832004ef6ad62849769f44753d8f))

## [1.0.1](https://github.com/SpiceLabsHQ/.github/compare/secret-scan-v1.0.0...secret-scan-v1.0.1) (2026-07-04)


### Bug Fixes

* **deps:** update actions/checkout action to v7 ([#61](https://github.com/SpiceLabsHQ/.github/issues/61)) ([f01862d](https://github.com/SpiceLabsHQ/.github/commit/f01862db624a28bce16f535b3c29a8b036927904))

## 1.0.0 (2026-07-03)

Baseline release establishing per-workflow versioning ([DEV-408]). Functionally
identical to the legacy shared `v1` tag as of commit `60a48c1`. From here on,
`secret-scan` versions independently: immutable tags `secret-scan-vX.Y.Z` plus the
floating major alias `secret-scan-v1`.

[DEV-408]: https://linear.app/spicelabshq/issue/DEV-408
