# Changelog

## [1.1.0](https://github.com/SpiceLabsHQ/.github/compare/markdownlint-v1.0.0...markdownlint-v1.1.0) (2026-07-05)


### Features

* **markdownlint:** add reusable org-wide markdownlint workflow (DEV-517) ([#109](https://github.com/SpiceLabsHQ/.github/issues/109)) ([e6abd7b](https://github.com/SpiceLabsHQ/.github/commit/e6abd7bad63de54f02b5c0333e0ce1c5cdc34ce5))

## 1.0.0 (2026-07-05)

Initial release of the reusable `markdownlint` workflow ([DEV-517]). Extracted
from Eng-Cookbook's standalone `markdownlint.yml` so markdown linting is defined
once org-wide instead of copy-pasted per repo. Runs `markdownlint-cli2` over
caller-scoped `globs` (default `**/*.md`) with a caller-supplied, tolerated-absent
`.markdownlint-cli2.jsonc`. Consumed via the floating major alias
`markdownlint-v1`.

[DEV-517]: https://linear.app/spicelabshq/issue/DEV-517
