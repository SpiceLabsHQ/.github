# Changelog

## [1.1.1](https://github.com/SpiceLabsHQ/.github/compare/pr-hygiene-v1.1.0...pr-hygiene-v1.1.1) (2026-08-22)


### Bug Fixes

* **deps:** route workflow action pins through per-package pins files ([#218](https://github.com/SpiceLabsHQ/.github/issues/218)) ([ad15be1](https://github.com/SpiceLabsHQ/.github/commit/ad15be11a8225abd28234d1c0f385888365a8059))

## [1.1.0](https://github.com/SpiceLabsHQ/.github/compare/pr-hygiene-v1.0.0...pr-hygiene-v1.1.0) (2026-07-29)


### Features

* **pepper-pr-review:** stamp the reviewed head SHA on review output (DEV-721) ([#170](https://github.com/SpiceLabsHQ/.github/issues/170)) ([4b0b0ab](https://github.com/SpiceLabsHQ/.github/commit/4b0b0ab2a0e5779c4f4ba4dcd0984617a0213ae6))
* **pr-hygiene:** retune size warning for an AI-first reviewer ([#139](https://github.com/SpiceLabsHQ/.github/issues/139)) ([9027ca6](https://github.com/SpiceLabsHQ/.github/commit/9027ca6493a28e071dcf9d6a066bc77ee8de51af))

## 1.0.0 (2026-07-03)

Baseline release establishing per-workflow versioning ([DEV-408]). Functionally
identical to the legacy shared `v1` tag as of commit `60a48c1`. From here on,
`pr-hygiene` versions independently: immutable tags `pr-hygiene-vX.Y.Z` plus the
floating major alias `pr-hygiene-v1`.

[DEV-408]: https://linear.app/spicelabshq/issue/DEV-408
