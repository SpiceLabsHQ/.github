#!/usr/bin/env bash
# Fixture tests for the coverage-surface note logic (DEV-526). Exercises the
# EXACT programs production runs — `jq -rf note.jq` (the Pepper note renderer)
# and `annotate.py` (the ::warning:: emitter) — against known diff-cover JSON,
# so neither can drift from what ships. Self-asserting: exits non-zero on any
# mismatch.
#
# Run locally:  .github/actions/coverage-surface/test/coverage_surface_test.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NOTE_JQ="${HERE}/../note.jq"
ANNOTATE="${HERE}/../annotate.py"

fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1" >&2; fails=$((fails + 1)); }

# render <json> -> the note markdown produced by note.jq
render() { jq -r -f "${NOTE_JQ}"; }

FLAG='New-logic-without-a-test flag'

assert_contains()     { case "$1" in *"$2"*) pass "$3" ;; *) fail "$3 — expected to contain: $2";; esac; }
assert_not_contains() { case "$1" in *"$2"*) fail "$3 — expected NOT to contain: $2";; *) pass "$3" ;; esac; }
assert_eq()           { if [ "$1" = "$2" ]; then pass "$3"; else fail "$3 — got [$1] want [$2]"; fi; }

# --- note.jq: test/non-test classifier ---------------------------------------
# The bug the review caught: a PREFIX-style pytest file (test_foo.py at the repo
# root) must be recognized as a TEST file, so its uncovered lines do NOT trip
# the soft flag.
out="$(printf '%s' '{"total_percent_covered":60,"num_changed_lines":5,"total_num_violations":2,"src_stats":{"test_foo.py":{"violation_lines":[10,12]}}}' | render)"
assert_not_contains "$out" "$FLAG" "prefix pytest file test_foo.py is a test file (no soft flag)"

for tf in "tests/foo.py" "foo_test.go" "foo_spec.rb" "foo.test.ts" "foo.spec.ts" "conftest.py" "spec_thing.rb" "src/__tests__/x.ts"; do
  out="$(printf '{"total_percent_covered":50,"num_changed_lines":2,"total_num_violations":1,"src_stats":{"%s":{"violation_lines":[1]}}}' "$tf" | render)"
  assert_not_contains "$out" "$FLAG" "test file '$tf' does not trip the soft flag"
done

# A genuine non-test (production) file DOES trip the flag, counting only non-test lines.
out="$(printf '%s' '{"total_percent_covered":40,"num_changed_lines":10,"total_num_violations":3,"src_stats":{"tests/x.py":{"violation_lines":[1]},"lib/pay.rb":{"violation_lines":[7,9,11]}}}' | render)"
assert_contains "$out" "$FLAG" "uncovered production line trips the soft flag"
assert_contains "$out" "3 uncovered changed line(s) sit in non-test files" "soft flag counts only the 3 non-test lines (excludes tests/x.py)"

# Files that merely look test-ish stay classified as production.
for pf in "latest.py" "contest.py" "src/contestant.go"; do
  out="$(printf '{"total_percent_covered":0,"num_changed_lines":1,"total_num_violations":1,"src_stats":{"%s":{"violation_lines":[1]}}}' "$pf" | render)"
  assert_contains "$out" "$FLAG" "non-test lookalike '$pf' is treated as production (flag fires)"
done

# --- note.jq: headline + fully-covered + truncation --------------------------
out="$(printf '%s' '{"total_percent_covered":100,"num_changed_lines":4,"total_num_violations":0,"src_stats":{}}' | render)"
assert_contains "$out" "- All changed lines are covered." "fully-covered note has no uncovered list"
assert_not_contains "$out" "$FLAG" "fully-covered note has no soft flag"
assert_contains "$out" "- Changed lines covered: 100% (0 uncovered)" "headline reports percent and uncovered count"

# 60 uncovered lines in a production file -> list capped at 50 with a truncation line.
big="$(python3 -c 'import json;print(json.dumps({"total_percent_covered":10,"num_changed_lines":60,"total_num_violations":60,"src_stats":{"lib/big.py":{"violation_lines":list(range(1,61))}}}))')"
out="$(printf '%s' "$big" | render)"
listed="$(printf '%s\n' "$out" | grep -c '^  - lib/big.py:')"
assert_eq "$listed" "50" "uncovered list is capped at 50 entries"
assert_contains "$out" "… (truncated, 10 more)" "truncation line reports the 10 hidden entries"

# --- annotate.py: stdout stats + stderr annotations --------------------------
ann_err="$(printf '%s' '{"num_changed_lines":2,"total_num_violations":1,"total_percent_covered":50,"src_stats":{"m.py":{"violation_lines":[5]}}}' | python3 "${ANNOTATE}" /dev/stdin 2>&1 1>/dev/null)"
ann_out="$(printf '%s' '{"num_changed_lines":2,"total_num_violations":1,"total_percent_covered":50,"src_stats":{"m.py":{"violation_lines":[5]}}}' | python3 "${ANNOTATE}" /dev/stdin 2>/dev/null)"
assert_eq "$ann_out" "50|2|1" "annotate.py prints pct|changed|uncovered on stdout"
assert_contains "$ann_err" "::warning file=m.py,line=5" "annotate.py emits a ::warning:: annotation per uncovered line"

# Malformed input degrades to a non-gating no-op (100|0|0, no crash).
bad_out="$(printf '%s' 'not json' | python3 "${ANNOTATE}" /dev/stdin 2>/dev/null)"
assert_eq "$bad_out" "100|0|0" "annotate.py degrades malformed input to 100|0|0"

if [ "$fails" -gt 0 ]; then
  echo "" >&2; echo "${fails} assertion(s) failed." >&2; exit 1
fi
echo "All coverage-surface fixture assertions passed."
