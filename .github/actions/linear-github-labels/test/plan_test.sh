#!/usr/bin/env bash
# Fixture test for plan.jq — the reconciliation logic behind the Linear
# GitHub-label sync. Exercises the EXACT program sync.sh runs (jq -f plan.jq),
# so it can't drift from production. Self-asserting: exits non-zero on mismatch.
#
# Two suites run the same six reconciliation branches over the two key formats
# the action produces, proving plan.jq treats the key as opaque:
#   1. numeric repo IDs      (source=repos)
#   2. gh-action:<id>:<path> (source=actions — dots, slashes, colons)
#
# Run locally:  .github/actions/linear-github-labels/test/plan_test.sh
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLAN="${HERE}/../plan.jq"

sortkey='sort_by(.op, .itemId, (.name // ""))'
fails=0

# run_suite <label> <items-json> <children-json> <expected-json> <rename-label-id>
run_suite() {
  local suite="$1" items="$2" children="$3" expected="$4" want_rename_id="$5" actual rid
  actual="$(jq -n --argjson items "$items" --argjson children "$children" -f "$PLAN")"

  if diff <(jq -S "$sortkey" <<<"$expected") <(jq -S "$sortkey" <<<"$actual") >/dev/null; then
    echo "PASS [${suite}]: 6 ops as expected (noop dropped; rename/create/adopt/conflict/prune correct)."
  else
    echo "FAIL [${suite}]: plan.jq output did not match expected."
    echo "--- expected ---"; jq -S "$sortkey" <<<"$expected"
    echo "--- actual ---";   jq -S "$sortkey" <<<"$actual"
    fails=$((fails+1))
    return
  fi

  # The key invariant: a rename must reuse the existing label id, or every issue
  # tagged with that label is orphaned.
  rid="$(jq -r '.[] | select(.op=="rename") | .id' <<<"$actual")"
  if [ "$rid" = "$want_rename_id" ]; then
    echo "PASS [${suite}]: rename reuses the existing label id (issues preserved)."
  else
    echo "FAIL [${suite}]: rename did not reuse existing label id (got '$rid', want '$want_rename_id')"
    fails=$((fails+1))
  fi
}

# --- Suite 1: source=repos (numeric keys) ------------------------------------
#   100 alpha      : ID match, name match            -> noop (dropped)
#   200 bravo-new  : ID match, name differs          -> rename (from bravo-old)
#   300 charlie    : no match                        -> create
#   400 delta      : unmanaged label of same name    -> adopt
#   500 echo       : name owned by another key (999) -> conflict
run_suite "repos" \
'[
  {"id":100,"name":"alpha"},
  {"id":200,"name":"bravo-new"},
  {"id":300,"name":"charlie"},
  {"id":400,"name":"delta"},
  {"id":500,"name":"echo"}
]' \
'[
  {"id":"L1","name":"alpha","managedId":"100"},
  {"id":"L2","name":"bravo-old","managedId":"200"},
  {"id":"L3","name":"gonezo","managedId":"700"},
  {"id":"L4","name":"delta","managedId":null},
  {"id":"L5","name":"echo","managedId":"999"}
]' \
'[
  {"op":"rename","id":"L2","name":"bravo-new","from":"bravo-old","itemId":"200"},
  {"op":"create","name":"charlie","itemId":"300"},
  {"op":"adopt","id":"L4","name":"delta","itemId":"400"},
  {"op":"conflict","name":"echo","otherItemId":"999","itemId":"500"},
  {"op":"prune","id":"L3","name":"gonezo","itemId":"700"},
  {"op":"prune","id":"L5","name":"echo","itemId":"999"}
]' "L2"

# --- Suite 2: source=actions (composite string keys) -------------------------
# The same six branches, but every key is a `gh-action:<repo-id>:<path>` string
# containing dots, slashes and colons, and every label name contains a slash.
# This is the regression guard for treating the key as an opaque token.
run_suite "actions" \
'[
  {"id":"gh-action:111:.github/workflows/sast.yml","name":".github/sast"},
  {"id":"gh-action:111:.github/workflows/codeql.yml","name":".github/codeql"},
  {"id":"gh-action:111:.github/workflows/secret-scan.yml","name":".github/secret-scan"},
  {"id":"gh-action:111:.github/workflows/markdownlint.yml","name":".github/markdownlint"},
  {"id":"gh-action:222:.github/workflows/pr-hygiene.yml","name":"other-repo/pr-hygiene"}
]' \
'[
  {"id":"L1","name":".github/sast","managedId":"gh-action:111:.github/workflows/sast.yml"},
  {"id":"L2","name":".github/codeql-old","managedId":"gh-action:111:.github/workflows/codeql.yml"},
  {"id":"L3","name":".github/removed","managedId":"gh-action:111:.github/workflows/removed.yml"},
  {"id":"L4","name":".github/markdownlint","managedId":null},
  {"id":"L5","name":"other-repo/pr-hygiene","managedId":"gh-action:999:.github/workflows/pr-hygiene.yml"}
]' \
'[
  {"op":"rename","id":"L2","name":".github/codeql","from":".github/codeql-old","itemId":"gh-action:111:.github/workflows/codeql.yml"},
  {"op":"create","name":".github/secret-scan","itemId":"gh-action:111:.github/workflows/secret-scan.yml"},
  {"op":"adopt","id":"L4","name":".github/markdownlint","itemId":"gh-action:111:.github/workflows/markdownlint.yml"},
  {"op":"conflict","name":"other-repo/pr-hygiene","otherItemId":"gh-action:999:.github/workflows/pr-hygiene.yml","itemId":"gh-action:222:.github/workflows/pr-hygiene.yml"},
  {"op":"prune","id":"L3","name":".github/removed","itemId":"gh-action:111:.github/workflows/removed.yml"},
  {"op":"prune","id":"L5","name":"other-repo/pr-hygiene","itemId":"gh-action:999:.github/workflows/pr-hygiene.yml"}
]' "L2"

if [ "$fails" -eq 0 ]; then
  echo "All plan.jq suites passed."
  exit 0
fi
echo "${fails} plan.jq assertion(s) failed."
exit 1
