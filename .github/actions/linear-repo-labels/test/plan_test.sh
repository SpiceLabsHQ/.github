#!/usr/bin/env bash
# Fixture test for plan.jq — the reconciliation logic behind the Linear
# repo-label sync. Exercises the EXACT program sync.sh runs (jq -f plan.jq),
# so it can't drift from production. Self-asserting: exits non-zero on mismatch.
#
# Run locally:  .github/actions/linear-repo-labels/test/plan_test.sh
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLAN="${HERE}/../plan.jq"

# Fixtures — one repo per reconciliation branch:
#   100 alpha      : ID match, name match          -> noop (dropped)
#   200 bravo-new  : ID match, name differs        -> rename (from bravo-old)
#   300 charlie    : no match                       -> create
#   400 delta      : unmanaged label of same name   -> adopt
#   500 echo       : name owned by another repo (999) -> conflict
repos='[
  {"id":100,"name":"alpha"},
  {"id":200,"name":"bravo-new"},
  {"id":300,"name":"charlie"},
  {"id":400,"name":"delta"},
  {"id":500,"name":"echo"}
]'
# Current labels in the group:
#   L1 alpha      managed 100  -> noop
#   L2 bravo-old  managed 200  -> rename to bravo-new
#   L3 gonezo     managed 700  -> prune (repo 700 gone)
#   L4 delta      unmanaged    -> adopt (stamp 400)
#   L5 echo       managed 999  -> conflict source + prune (repo 999 gone)
children='[
  {"id":"L1","name":"alpha","managedId":"100"},
  {"id":"L2","name":"bravo-old","managedId":"200"},
  {"id":"L3","name":"gonezo","managedId":"700"},
  {"id":"L4","name":"delta","managedId":null},
  {"id":"L5","name":"echo","managedId":"999"}
]'

expected='[
  {"op":"rename","id":"L2","name":"bravo-new","from":"bravo-old","repoId":"200"},
  {"op":"create","name":"charlie","repoId":"300"},
  {"op":"adopt","id":"L4","name":"delta","repoId":"400"},
  {"op":"conflict","name":"echo","otherRepoId":"999","repoId":"500"},
  {"op":"prune","id":"L3","name":"gonezo","repoId":"700"},
  {"op":"prune","id":"L5","name":"echo","repoId":"999"}
]'

actual="$(jq -n --argjson repos "$repos" --argjson children "$children" -f "$PLAN")"

# Order-independent comparison: sort both sides by a stable key.
sortkey='sort_by(.op, .repoId, (.name // ""))'
if diff <(jq -S "$sortkey" <<<"$expected") <(jq -S "$sortkey" <<<"$actual") >/dev/null; then
  echo "PASS: plan.jq produces the expected 6 ops (noop dropped, rename/create/adopt/conflict/prune all correct)."
  # Guard the key invariant explicitly: a rename must reuse the existing label id.
  rid="$(jq -r '.[] | select(.op=="rename") | .id' <<<"$actual")"
  [ "$rid" = "L2" ] || { echo "FAIL: rename did not reuse existing label id (got '$rid', want L2)"; exit 1; }
  echo "PASS: rename reuses the existing label id (issues preserved)."
  exit 0
else
  echo "FAIL: plan.jq output did not match expected."
  echo "--- expected ---"; jq -S "$sortkey" <<<"$expected"
  echo "--- actual ---";   jq -S "$sortkey" <<<"$actual"
  exit 1
fi
