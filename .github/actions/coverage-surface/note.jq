# Render diff-cover JSON into Pepper's NON-GATING diff-coverage note (DEV-526).
#
# Input: a `diff-cover --format json:` report. Output (jq -rf): a short markdown
# note — changed-line count, % of changed lines covered, the uncovered lines
# (capped at 50), and a SOFT "new-logic-without-a-test" flag that fires only for
# uncovered lines in NON-test files. No percentage is ever a gate.
#
# This is the exact program the pepper-pr-review workflow runs (jq -rf note.jq),
# so the fixture test in test/ can't drift from production. Fixed by review
# (DEV-526): the test/non-test classifier now also matches PREFIX-style test
# files (pytest `test_foo.py`, `spec_foo.rb`) at the repo root, not just
# suffix (`foo_test.go`) and directory-scoped (`tests/…`) ones — otherwise an
# uncovered line in a bare `test_foo.py` misclassified as production code and
# could spuriously trip the soft flag.

(.total_percent_covered) as $pct
| (.num_changed_lines) as $changed
| (.total_num_violations) as $viol
| ([ .src_stats | to_entries[] as $e | ($e.value.violation_lines // [])[] | {file:$e.key, line:.} ]) as $unc
| ([ $unc[]
     | select(.file
       | test("(/|^)(tests?|specs?|__tests__)/|(/|^)(test|spec)_|_(test|spec)\\.|\\.(test|spec)s?\\.|conftest"; "i")
       | not) ]) as $nontest
| (
    "- Changed executable lines: \($changed)",
    "- Changed lines covered: \($pct)% (\($viol) uncovered)",
    ( if ($unc|length) > 0
      then ( "- Uncovered changed lines:",
             ( $unc[0:50][] | "  - \(.file):\(.line)" ),
             ( if ($unc|length) > 50 then "  - … (truncated, \(($unc|length)-50) more)" else empty end ) )
      else "- All changed lines are covered." end ),
    ( if ($nontest|length) > 0
      then ( "",
             "> **New-logic-without-a-test flag (soft):** \($nontest|length) uncovered changed line(s) sit in non-test files. Treat this as a test gap under `<test_review>` unless you positively verify the logic is exercised elsewhere, or the change explains why a test is not warranted." )
      else empty end )
  )
