#!/usr/bin/env bash
# Fixture test for the DEV-653 audit record — all three programs
# (pepper-audit-record.sh, pepper-audit-collect.jq, pepper-audit-record.jq),
# driven in dry-run mode against committed fixtures and a stub `gh`. Exercises
# the EXACT programs the workflow runs, so none can drift from production.
# Self-asserting: exits non-zero on mismatch.
#
# WHY FIXTURES. This code runs on every review, on the one path where being
# wrong is invisible: it writes to a log group nobody watches day to day, inside
# a step that is `continue-on-error` by hard requirement (DEV-502/DEV-504). Its
# worst failures produce a GREEN check and a silently wrong dataset —
#   - a field renamed or dropped, so every committed Logs Insights query in
#     docs/pepper-audit.md silently returns nothing;
#   - the execution file preferred over the transcript incorrectly (or not at
#     all), so cost and turns come from the wrong source;
#   - a missing execution file, a missing transcript, or unreadable labels
#     crashing the script instead of degrading to nulls — which on the
#     no-verdict path would lose exactly the runs DEV-884's analysis needs;
#   - a non-zero exit, which is the one outcome the required check forbids.
# None of them shows as a red check in production, so all are pinned here.
#
# `ts` is the only non-deterministic field. It is asserted to be an ISO-8601 UTC
# stamp and then normalised to a sentinel, so the rest of the record can be
# compared byte for byte against the expected fixture.
#
# Run locally:  scripts/test/pepper-audit-record_test.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="${HERE}/../pepper-audit-record.sh"
FIX="${HERE}/fixtures/pepper-audit"

fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; shift; for l in "$@"; do echo "  $l"; done; fails=$((fails + 1)); }

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT
BIN="${WORK}/bin"
mkdir -p "${BIN}"

# Stub `gh`. The script reads exactly one thing from it — the PR's final outcome
# labels — so the stub answers `pr view` from ${WORK}/labels and fails anything
# else. Removing the file models an unreadable PR (token hiccup, deleted PR),
# which must degrade to `outcome: null` rather than crash.
cat > "${BIN}/gh" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  "pr view"*) cat "${WORK}/labels" 2>/dev/null || exit 1 ;;
  *) exit 1 ;;
esac
STUB
chmod +x "${BIN}/gh"

# Stub `aws`. Nothing may reach it — every case below runs in dry-run mode — so
# it exists only to prove that: an invocation writes a marker the assertions
# check for.
cat > "${BIN}/aws" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "${WORK}/aws-calls"
exit 0
STUB
chmod +x "${BIN}/aws"

# Run the script with the given fixture wiring. Every case is dry-run: this test
# must never depend on (or reach) AWS.
#
# PEPPER_AUDIT_TRANSCRIPT_DIR is pointed at an empty directory whenever no
# transcript is wired, so the discovery path cannot wander into a real
# ~/.claude/projects on a developer's machine and make the test non-hermetic.
mkdir -p "${WORK}/empty-projects"

run_audit() { # <execution_file> <transcript> [env assignments...]
  local exec_file="$1" transcript="$2"
  shift 2
  rm -f "${WORK}/aws-calls"
  env -i \
    PATH="${BIN}:/usr/bin:/bin:/usr/local/bin" \
    HOME="${WORK}" \
    WORK="${WORK}" \
    PEPPER_AUDIT_DRY_RUN=true \
    PEPPER_AUDIT_EXECUTION_FILE="${exec_file}" \
    PEPPER_AUDIT_TRANSCRIPT="${transcript}" \
    PEPPER_AUDIT_TRANSCRIPT_DIR="${WORK}/empty-projects" \
    REPO="SpiceLabsHQ/example" \
    PR_NUMBER=123 \
    RUN_ID=17123456789 \
    RUN_ATTEMPT=1 \
    EVENT_NAME=pull_request \
    HEAD_SHA=abc1234def567890abc1234def567890abc1234d \
    PR_AUTHOR=octocat \
    FLAVOR=default \
    WORKFLOW_SHA=3fd28051d0e4c8b6a1f2e3d4c5b6a7988990a1b2 \
    MODEL="arn:aws:bedrock:us-west-2:618640261060:application-inference-profile/xda66yqkegz4" \
    EFFORT=high \
    MAX_TURNS=80 \
    REVIEW_TIMEOUT_MINUTES=50 \
    NO_VERDICT=false \
    COLLAPSE_FIRED=false \
    "$@" \
    bash "${SCRIPT}"
}

record_of() { grep -o '^audit-record=.*' <<<"$1" | tail -n1 | sed 's/^audit-record=//'; }

# `ts` is the run clock. Assert its SHAPE, then normalise it so the remaining
# fields can be compared exactly.
normalise_ts() {
  jq -c '.ts = "TS"' <<<"$1" 2>/dev/null
}

check_record() { # <label> <expected-file> <script stdout> <rc>
  local label="$1" expected="$2" out="$3" rc="$4" rec got want
  rec="$(record_of "${out}")"
  if [ -z "${rec}" ]; then
    fail "${label}: emits a record" "no audit-record= line in output" "${out}"
    return
  fi
  if ! jq -e . >/dev/null 2>&1 <<<"${rec}"; then
    fail "${label}: record is valid JSON" "${rec}"
    return
  fi
  if [ "${rc}" -eq 0 ]; then
    pass "${label}: exits 0"
  else
    fail "${label}: exits 0" "rc=${rc}"
  fi
  if jq -e '.ts | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$")' >/dev/null 2>&1 <<<"${rec}"; then
    pass "${label}: ts is an ISO-8601 UTC stamp"
  else
    fail "${label}: ts is an ISO-8601 UTC stamp" "ts=$(jq -c '.ts' <<<"${rec}")"
  fi
  got="$(jq -S . <<<"$(normalise_ts "${rec}")")"
  want="$(jq -S . <"${expected}")"
  if [ "${got}" = "${want}" ]; then
    pass "${label}: record matches ${expected##*/}"
  else
    # Field-by-field, so a diff names the field rather than dumping two blobs.
    fail "${label}: record matches ${expected##*/}" \
      "$(diff <(jq -S 'to_entries[] | "\(.key)=\(.value|tojson)"' -r <<<"${want}") \
              <(jq -S 'to_entries[] | "\(.key)=\(.value|tojson)"' -r <<<"${got}") || true)"
  fi
  if [ ! -f "${WORK}/aws-calls" ]; then
    pass "${label}: dry run makes no AWS call"
  else
    fail "${label}: dry run makes no AWS call" "$(cat "${WORK}/aws-calls")"
  fi
}

# --- Happy path: execution file + transcript, approved ----------------------
# Pins the whole preference order in one case. Cost, turns, duration and the
# token split come from the execution file's `result` record (51234/98765/...,
# NOT the 11/22/33/9 the same file's assistant lines sum to). `cli_version` and
# `effort` come from the execution file's assistant lines as EXECUTED
# (2.1.223 / high), beating the transcript's 2.1.220 / medium and the
# workflow-passed effort — the DEV-881 property: a CLI that rewrites a flag is
# only visible in what it actually sent. `model` is the exception and SPLITS
# instead of preferring: it keeps the workflow-passed profile ARN (the cost-
# attribution key) while `model_executed` carries the stream's resolved model
# id, so the divergence signal survives without destroying the cost join.
printf '%s' "pepper-approved" > "${WORK}/labels"
OUT="$(run_audit "${FIX}/execution-file.json" "${FIX}/transcript.jsonl")"; RC=$?
check_record "approved" "${FIX}/expected-approved.json" "${OUT}" "${RC}"

# --- No verdict -------------------------------------------------------------
# `no_verdict` is a FAILURE, not a verdict, and it must not be reported as an
# ordinary escalation even though the DEV-235 escalation step applies the same
# `pepper-needs-review` label. The step's own output is what decides it.
printf '%s' "pepper-needs-review" > "${WORK}/labels"
OUT="$(run_audit "${FIX}/execution-file.json" "${FIX}/transcript.jsonl" NO_VERDICT=true)"; RC=$?
check_record "no-verdict" "${FIX}/expected-no-verdict.json" "${OUT}" "${RC}"

# --- Missing execution file: fall back to the transcript --------------------
# The action's `execution_file` output is empty on a timed-out or errored run —
# exactly the runs worth auditing — so the transcript fallback carries them.
# Cost, turns and duration are legitimately null here (only the SDK's `result`
# record reports them); the token sum over assistant lines is the ground truth,
# and cost is derived at query time rather than invented (docs/pepper-audit.md).
# `collapse_fired` is true so the DEV-674 flag is pinned in both directions.
printf '%s' "pepper-changes-requested,pepper-needs-review" > "${WORK}/labels"
OUT="$(run_audit "${WORK}/does-not-exist.json" "${FIX}/transcript.jsonl" COLLAPSE_FIRED=true)"; RC=$?
check_record "transcript-only" "${FIX}/expected-transcript-only.json" "${OUT}" "${RC}"

# --- Neither source, and unreadable labels ----------------------------------
# The floor of the fail-open contract: every telemetry source missing AND `gh`
# failing must still produce ONE valid schema-v1 record with nulls in the holes,
# and must still exit 0. If this case ever crashes, a required check goes red on
# a review that succeeded.
rm -f "${WORK}/labels"
OUT="$(run_audit "${WORK}/does-not-exist.json" "${WORK}/also-missing.jsonl")"; RC=$?
check_record "no-telemetry" "${FIX}/expected-no-telemetry.json" "${OUT}" "${RC}"

# --- cookbook_ref is carried through verbatim (DEV-1119) --------------------
# "Latest stable" Eng-Cookbook release floats by design, so the tag the prompt
# actually carried must reach the record as passed — it is the only way to
# attribute a behavior or cost shift to a cookbook release. Every fixture above
# pins the null case (no release, or the run degraded to the marker).
printf '%s' "pepper-approved" > "${WORK}/labels"
OUT="$(run_audit "${FIX}/execution-file.json" "${FIX}/transcript.jsonl" COOKBOOK_REF=v1.2.3)"
REF="$(record_of "${OUT}" | jq -r '.cookbook_ref')"
if [ "${REF}" = "v1.2.3" ]; then
  pass "cookbook_ref: the passed Eng-Cookbook tag is recorded as-is"
else
  fail "cookbook_ref: the passed Eng-Cookbook tag is recorded as-is" "actual: ${REF}"
fi

# --- The schema itself ------------------------------------------------------
# The committed queries in docs/pepper-audit.md address fields by name, so the
# key set is the contract. A rename is a schema bump, not a refactor.
printf '%s' "pepper-approved" > "${WORK}/labels"
OUT="$(run_audit "${FIX}/execution-file.json" "${FIX}/transcript.jsonl")"
KEYS="$(record_of "${OUT}" | jq -c 'keys_unsorted')"
WANT_KEYS='["schema_version","ts","repo","pr_number","run_id","run_attempt","event","head_sha","pr_author","flavor","workflow_sha","standards_sha256","cookbook_ref","model","model_executed","effort","max_turns","review_timeout_minutes","cli_version","outcome","collapse_fired","turns_used","duration_ms","cost_usd","tokens"]'
if [ "${KEYS}" = "${WANT_KEYS}" ]; then
  pass "schema: the v1 field set is exactly as specified"
else
  fail "schema: the v1 field set is exactly as specified" "expected: ${WANT_KEYS}" "actual:   ${KEYS}"
fi

TOKEN_KEYS="$(record_of "${OUT}" | jq -c '.tokens | keys_unsorted')"
if [ "${TOKEN_KEYS}" = '["input","output","cache_read","cache_creation"]' ]; then
  pass "schema: the token split carries all four buckets"
else
  fail "schema: the token split carries all four buckets" "actual: ${TOKEN_KEYS}"
fi

# --- The job summary --------------------------------------------------------
# The summary is the only view of a run for anyone without AWS access, so its
# absence is a real regression and worth one assertion.
printf '%s' "pepper-approved" > "${WORK}/labels"
SUMMARY="${WORK}/summary.md"
: > "${SUMMARY}"
run_audit "${FIX}/execution-file.json" "${FIX}/transcript.jsonl" \
  GITHUB_STEP_SUMMARY="${SUMMARY}" >/dev/null
if grep -q "Pepper review audit" "${SUMMARY}" && grep -q "2.1.223" "${SUMMARY}"; then
  pass "job summary is rendered with the record's values"
else
  fail "job summary is rendered with the record's values" "$(cat "${SUMMARY}")"
fi

echo
if [ "$fails" -eq 0 ]; then
  echo "All checks passed."
else
  echo "${fails} check(s) failed."
  exit 1
fi
