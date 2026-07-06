# `coverage-surface`

Surface **diff coverage** on a pull request without gating on it (DEV-526,
[ADR-0004]). Add one step to your **test job**, right after coverage is
produced, and you get:

1. A diff-coverage table in the **Actions job summary**.
2. Inline **`::warning::` annotations** on uncovered *changed* lines, rendered
   in the Files-changed tab.
3. The raw coverage file uploaded as the **`coverage-report` artifact**, which
   `pepper-pr-review` polls for and folds into its review.

**No coverage number ever fails the build.** The artifact feeds Pepper's
review judgment; the reviewer — informed by coverage — decides. This is the
deliberate opposite of a coverage-percentage merge gate (see ADR-0004).

## Usage

The step reads the coverage file off local disk, so it belongs in the same job
that ran the tests. Produce a coverage report in any
[`diff-cover`](https://github.com/Bachmann1234/diff_cover)-supported format —
LCOV, Cobertura, Clover, or JaCoCo — then hand its path to the action.

```yaml
jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v7
        with:
          # Full history so diff-cover can resolve the merge-base with the
          # PR base branch. A shallow checkout may under-report changed lines.
          fetch-depth: 0

      # ... run your tests, emitting a coverage file (see the table below) ...

      - name: Surface diff coverage
        uses: SpiceLabsHQ/.github/.github/actions/coverage-surface@<pin>
        with:
          coverage-file: coverage/lcov.info
```

Pin `<pin>` to a full commit SHA (or the shared org tag) — the same way you pin
every other third-party action. This repo is public, so the action is
consumable from any org.

### Emitting a coverage file

Every runner already has the flag; there is no format conversion and no
per-language parser — produce a file, hand it to the action.

| Runner  | Emit flag                                   | Format    |
| ------- | ------------------------------------------- | --------- |
| Vitest  | `--coverage.reporter=lcov`                  | LCOV      |
| pytest  | `--cov-report=xml`                          | Cobertura |
| Go      | `go test -coverprofile` → gocover-cobertura | Cobertura |
| PHPUnit | `--coverage-clover clover.xml`              | Clover    |
| Pester  | `-CodeCoverage`                             | JaCoCo    |

Rollout order is TS (Vitest) / Python (pytest) / Go first; PHP and PowerShell
after — but the action itself is language-agnostic, so any of the above works
today.

## Inputs

| Input                | Required | Default                                   | Description                                                                 |
| -------------------- | -------- | ----------------------------------------- | --------------------------------------------------------------------------- |
| `coverage-file`      | yes      | —                                         | Path to the coverage report (LCOV / Cobertura / Clover / JaCoCo).           |
| `base-ref`           | no       | `${{ github.event.pull_request.base.ref }}` | Branch to diff against. Empty on non-PR events → the action no-ops.        |
| `artifact-name`      | no       | `coverage-report`                         | Uploaded artifact name; must match Pepper's `coverage_artifact` input.      |
| `upload-artifact`    | no       | `true`                                    | Upload the coverage file for the Pepper consumer.                           |
| `diff-cover-version` | no       | `10.3.0`                                  | Pinned `diff-cover` version installed for the run.                          |

## Outputs

| Output            | Description                                                       |
| ----------------- | ---------------------------------------------------------------- |
| `percent-covered` | Percent of changed lines covered (`100` when there is no diff).  |
| `changed-lines`   | Number of changed executable lines considered.                   |
| `uncovered-lines` | Number of changed lines with no coverage.                        |
| `surfaced`        | `true` when a table was produced, else `false` (clean fallback). |

## Tests

The note-rendering logic — `note.jq` (the Pepper diff-coverage note, including
the test/non-test classifier and truncation) and `annotate.py` (the `::warning::`
emitter) — is covered by a self-asserting fixture test that runs the exact
production programs against known diff-cover JSON:

```
.github/actions/coverage-surface/test/coverage_surface_test.sh
```

It runs in CI via [`coverage-surface-test.yml`](../../workflows/coverage-surface-test.yml)
on any PR touching this action. The Pepper workflow renders its note with
`jq -rf note.jq`, so the test exercises the same program that ships.

## Failure behavior

The action is **fail-open by design**. A missing file, an unsupported format, a
non-PR event, or a `diff-cover` error each downgrades to a `::warning::` with
`surfaced=false` and exits `0`. A coverage problem must never block a merge —
that is the whole point of the non-gating model.

[ADR-0004]: https://linear.app/spicelabshq/issue/DEV-526
