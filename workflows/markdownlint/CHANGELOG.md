# Changelog

## 1.0.0 (2026-07-05)

Initial release of the reusable `markdownlint` workflow ([DEV-517]). Extracted
from Eng-Cookbook's standalone `markdownlint.yml` so markdown linting is defined
once org-wide instead of copy-pasted per repo. Runs `markdownlint-cli2` over
caller-scoped `globs` (default `**/*.md`) with a caller-supplied, tolerated-absent
`.markdownlint-cli2.jsonc`. Consumed via the floating major alias
`markdownlint-v1`.

[DEV-517]: https://linear.app/spicelabshq/issue/DEV-517
