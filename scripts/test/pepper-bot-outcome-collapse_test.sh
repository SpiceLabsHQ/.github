#!/usr/bin/env bash
# Fixture test for the DEV-674 bot-PR outcome collapse — both halves, the
# decision program (pepper-bot-outcome-collapse-decide.jq) and the actor
# (pepper-bot-outcome-collapse.sh). Exercises the EXACT programs the workflow
# runs, so neither can drift from production. Self-asserting: exits non-zero on
# mismatch.
#
# WHY FIXTURES. This code only ever runs after a Bedrock-billed review, on a live
# PR, on the one path where getting it wrong is worst: it makes API calls that
# CHANGE whether a PR is blocked. The failures that must never ship are all
# silent —
#   - collapsing a HUMAN's PR, which would dismiss an actionable change request;
#   - dismissing only ONE of several change requests, leaving the PR blocked by
#     the rest while the labels and the comment say it was handled;
#   - firing on a PR whose block a later approval already cleared, dismissing
#     settled history and commenting on a PR nobody is stuck on;
#   - swapping the labels after a dismissal that did not actually take.
# None of them shows as a red check in production, so all of them are pinned here.
#
# The actor is driven against a stub `gh` on PATH that records every call AND
# carries state between calls — dismissals rewrite state, posted reviews are
# appended — so ordering, retryability and idempotence are tested end to end
# without a network or a real PR.
#
# Run locally:  scripts/test/pepper-bot-outcome-collapse_test.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DECIDE="${HERE}/../pepper-bot-outcome-collapse-decide.jq"
COLLAPSE="${HERE}/../pepper-bot-outcome-collapse.sh"

BOT='pepper-pr-review[bot]'

fails=0

pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; shift; for l in "$@"; do echo "  $l"; done; fails=$((fails + 1)); }

# ---------------------------------------------------------------------------
# Part 1 — the decision program
# ---------------------------------------------------------------------------

decide() { # <flavor> <reviews-json> [bot]
  jq -cn --arg bot "${3-$BOT}" --arg flavor "$1" --argjson reviews "$2" -f "$DECIDE"
}

review() { # <id> <state> <submitted_at> [login] [body]
  jq -cn --argjson id "$1" --arg state "$2" --arg at "$3" \
     --arg who "${4:-$BOT}" --arg body "${5:-findings}" \
     '{id: $id, state: $state, submitted_at: $at, user: {login: $who}, body: $body}'
}

check_decision() { # <label> <expected_action> <expected_reason> <decision>
  local label="$1" xa="$2" xr="$3" got="$4" a r
  a="$(jq -r '.action' <<<"$got")"
  r="$(jq -r '.reason' <<<"$got")"
  if [ "$a" = "$xa" ] && [ "$r" = "$xr" ]; then
    pass "$label"
  else
    fail "$label" "expected: ${xa}/${xr}" "actual:   ${a}/${r}"
  fi
}

CR='[{"id":11,"state":"CHANGES_REQUESTED","submitted_at":"2026-07-10T00:00:00Z","user":{"login":"pepper-pr-review[bot]"},"body":"stale workflow.sha256"}]'

# Six live change requests, the shape observed on the motivating PR:
#   gh api repos/SpiceLabsHQ/.github/pulls/138/reviews \
#     --jq '[.[]|.state]|group_by(.)|map({(.[0]):length})|add'  -> {"CHANGES_REQUESTED":6}
SIX="[$(for i in 1 2 3 4 5 6; do
  printf '%s' "$(review "$((10 + i))" CHANGES_REQUESTED "2026-07-0${i}T00:00:00Z" "$BOT" "round ${i}")"
  [ "$i" -lt 6 ] && printf ','
done)]"

# A COMMENT interleaved among the change requests, and NEWER than all of them.
# GitHub does not treat it as superseding anything — `COMMENTED` is "An
# informational review", `CHANGES_REQUESTED` is "A review blocking the pull
# request from merging":
#   gh api graphql -f query='{__type(name:"PullRequestReviewState")
#                             {enumValues{name description}}}'
# so the selector must ignore it and the change requests must still collapse.
CR_THEN_COMMENT="[$(review 11 CHANGES_REQUESTED 2026-07-10T00:00:00Z),\
$(review 12 COMMENTED 2026-07-11T00:00:00Z),\
$(review 13 CHANGES_REQUESTED 2026-07-12T00:00:00Z),\
$(review 14 COMMENTED 2026-07-13T00:00:00Z)]"

# A stale change request UNDER a later approval by the same reviewer. The
# approval clears the block; the earlier row keeps `state: CHANGES_REQUESTED`
# forever. Live instance on this repo — same reviewer, merged PR:
#   gh api repos/SpiceLabsHQ/.github/pulls/119/reviews \
#     --jq '.[]|{id,state,user:.user.login}'
#     4632652148 CHANGES_REQUESTED / 4632718270 DISMISSED / 4632732806 APPROVED
STALE_UNDER_APPROVAL="[$(review 11 CHANGES_REQUESTED 2026-07-10T00:00:00Z),\
$(review 12 APPROVED 2026-07-11T00:00:00Z)]"

check_decision "bot PR + CHANGES_REQUESTED" collapse bot-pr-changes-requested \
  "$(decide dependency "$CR")"

# The approval path must be untouched, or ADR-0017 auto-merge never fires.
check_decision "bot PR + approval" skip already-approved \
  "$(decide dependency "[$(review 11 APPROVED 2026-07-10T00:00:00Z)]")"

# THE GUARD. A naive dismiss-all would fire here, on a PR nothing is blocking.
check_decision "stale CHANGES_REQUESTED under a later approval" skip already-approved \
  "$(decide dependency "$STALE_UNDER_APPROVAL")"

# THE SELECTOR. A COMMENT clears nothing, so the change requests underneath it
# are still live and must still collapse.
check_decision "COMMENT interleaved among change requests" collapse bot-pr-changes-requested \
  "$(decide dependency "$CR_THEN_COMMENT")"

# The guardrail that matters most: a human can read and clear a change request,
# so it is actionable and must survive.
check_decision "human PR + CHANGES_REQUESTED" skip not-a-bot-pr \
  "$(decide default "$CR")"

check_decision "bot PR, Pepper never reviewed" skip no-pepper-review \
  "$(decide dependency '[]')"

# Someone else's change request is not Pepper's to dismiss.
check_decision "bot PR, CHANGES_REQUESTED by a human reviewer" skip no-pepper-review \
  "$(decide dependency "[$(review 11 CHANGES_REQUESTED 2026-07-10T00:00:00Z alice)]")"

# Without an app-slug we cannot tell Pepper's reviews from anyone else's. Stand
# down rather than guess — the same fail-open shape as the DEV-523 short-circuit.
check_decision "no app-slug" skip unknown-bot-identity \
  "$(decide dependency "$CR" '')"

# Idempotence: a dismissal REWRITES the review's state in place — there is no
# separate `dismissed` flag — so a re-run of this step (the workflow's `always()`
# gate makes re-runs cheap and likely) selects nothing.
check_decision "already dismissed" skip no-changes-requested \
  "$(decide dependency "[$(review 11 DISMISSED 2026-07-10T00:00:00Z)]")"

check_decision "only a COMMENT from Pepper" skip no-changes-requested \
  "$(decide dependency "[$(review 11 COMMENTED 2026-07-10T00:00:00Z)]")"

# A PENDING review carries a null submitted_at and would sort ahead of every real
# one, reading as the newest verdict when it is not a verdict at all.
pending() { jq -cn --argjson id "$1" --arg who "$BOT" \
  '{id: $id, state: "PENDING", submitted_at: null, user: {login: $who}, body: ""}'; }
check_decision "pending review does not mask the newest approval" skip already-approved \
  "$(decide dependency "[$(review 11 APPROVED 2026-07-10T00:00:00Z),$(pending 99)]")"

# EVERY change request is selected: each one blocks independently, so dismissing
# only the newest would leave five of #138's six still blocking.
GOT="$(decide dependency "$SIX")"
if [ "$(jq -c '.review_ids' <<<"$GOT")" = "[11,12,13,14,15,16]" ]; then
  pass "all six change requests are selected, not just the newest"
else
  fail "all six change requests are selected, not just the newest" \
    "actual: $(jq -c '.review_ids' <<<"$GOT")"
fi

GOT="$(decide dependency "$CR_THEN_COMMENT")"
if [ "$(jq -c '.review_ids' <<<"$GOT")" = "[11,13]" ]; then
  pass "the interleaved COMMENTs are not selected for dismissal"
else
  fail "the interleaved COMMENTs are not selected for dismissal" \
    "actual: $(jq -c '.review_ids' <<<"$GOT")"
fi

# The review ids and body are what the actor needs; a wrong id dismisses the
# wrong review and a dropped body loses the diagnosis.
GOT="$(decide dependency "$CR")"
if [ "$(jq -c '.review_ids' <<<"$GOT")" = "[11]" ] && [ "$(jq -r '.body' <<<"$GOT")" = "stale workflow.sha256" ]; then
  pass "collapse carries the review ids and the original body"
else
  fail "collapse carries the review ids and the original body" "actual: ${GOT}"
fi

# The comment is filed once. A run retrying a failed dismissal must not re-post
# it, which is what the marker on the newest change request is for.
GOT="$(decide dependency "$CR")"
MARKER="$(jq -r '.marker' <<<"$GOT")"
ALREADY="[$(review 11 CHANGES_REQUESTED 2026-07-10T00:00:00Z),\
$(review 12 COMMENTED 2026-07-11T00:00:00Z "$BOT" "${MARKER} findings")]"
if [ "$(jq -r '.comment_needed' <<<"$GOT")" = "true" ] \
   && [ "$(decide dependency "$ALREADY" | jq -r '.comment_needed')" = "false" ]; then
  pass "comment_needed clears once a marked collapse comment exists"
else
  fail "comment_needed clears once a marked collapse comment exists" \
    "marker: ${MARKER}" "second: $(decide dependency "$ALREADY")"
fi

# ---------------------------------------------------------------------------
# Part 2 — the actor, against a stateful stub `gh`
# ---------------------------------------------------------------------------

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT
BIN="${WORK}/bin"
mkdir -p "${BIN}"

# Stub `gh`. Records each invocation one-per-line in ${WORK}/calls, and MODELS
# the two GitHub behaviors this script depends on:
#   - a dismissal REWRITES that review's `state` to DISMISSED (verified on
#     SpiceLabsHQ/.github#119, see the fixture comments above);
#   - a posted COMMENT review is APPENDED, with its body, as the author's newest
#     review and does NOT change the state of any CHANGES_REQUESTED.
# Modelling the second is what makes the retry and dedupe scenarios meaningful:
# the review list a run leaves behind is the input the next run reads.
#
# Scenario flags (touch to arm, rm to disarm):
#   ${WORK}/fail_comment    — POST .../reviews fails
#   ${WORK}/fail_dismiss    — PUT .../dismissals fails outright
#   ${WORK}/silent_dismiss  — PUT .../dismissals returns success but the review
#                             keeps blocking (the write that lies)
#   ${WORK}/fail_one        — only the dismissal of review 13 fails
#   ${WORK}/fail_reviewer   — --add-reviewer fails
cat > "${BIN}/gh" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "${WORK}/calls"
R="${WORK}/reviews.json"
case "$*" in
  *"/dismissals"*)
    id="$(sed -n 's|.*/reviews/\([0-9][0-9]*\)/dismissals.*|\1|p' <<<"$*")"
    [ -f "${WORK}/fail_dismiss" ] && exit 1
    [ -f "${WORK}/silent_dismiss" ] && exit 0
    if [ -f "${WORK}/fail_one" ] && [ "${id}" = "13" ]; then exit 1; fi
    jq --argjson id "${id:-0}" 'map(if .id == $id then .state = "DISMISSED" else . end)' \
      "$R" > "$R.tmp" && mv "$R.tmp" "$R"
    exit 0 ;;
  *"--input -"*)
    # POST .../reviews. Read stdin rather than discarding it: the body carries
    # the collapse marker, and appending it verbatim is what lets the dedupe path
    # be exercised. Leaving stdin unread would also EPIPE the jq that builds the
    # payload and read as a failure the script never saw.
    payload="$(cat)"
    [ -f "${WORK}/fail_comment" ] && exit 1
    jq --arg body "$(jq -r '.body' <<<"${payload}")" \
      '. + [{id: 999, state: "COMMENTED", submitted_at: "2026-07-31T00:00:00Z",
             user: {login: "pepper-pr-review[bot]"}, body: $body}]' \
      "$R" > "$R.tmp" && mv "$R.tmp" "$R"
    exit 0 ;;
  *--paginate*"/reviews?"*)
    jq -c '.[]' "$R"
    exit 0 ;;
  *"/reviews/"*.state*)
    id="$(sed -n 's|.*/reviews/\([0-9][0-9]*\).*|\1|p' <<<"$*")"
    jq -r --argjson id "${id:-0}" '.[] | select(.id == $id) | .state' "$R"
    exit 0 ;;
  "pr view"*)
    echo "pepper-changes-requested,pepper-cooking"
    exit 0 ;;
  "pr edit"*--add-reviewer*)
    [ -f "${WORK}/fail_reviewer" ] && exit 1
    exit 0 ;;
esac
exit 0
STUB
chmod +x "${BIN}/gh"

# Re-run the actor against whatever review list the previous run left behind.
rerun_collapse() { # <flavor> [reviewers_team]
  rm -f "${WORK}/calls"
  WORK="${WORK}" PATH="${BIN}:${PATH}" \
    REPO="SpiceLabsHQ/.github" PR_NUMBER=138 PEPPER_BOT_LOGIN="${BOT}" \
    FLAVOR="$1" REVIEWERS_TEAM="${2-reviewers}" REPO_OWNER="SpiceLabsHQ" \
    "${COLLAPSE}"
}

run_collapse() { # <flavor> <reviews-json> [reviewers_team]
  printf '%s' "$2" > "${WORK}/reviews.json"
  rerun_collapse "$1" "${3-reviewers}"
}

calls() { cat "${WORK}/calls" 2>/dev/null; }
called()     { calls | grep -qF -- "$1"; }
not_called() { ! called "$1"; }

states_of() { # <state>
  jq -r --arg s "$1" '[.[] | select(.state == $s)] | length' "${WORK}/reviews.json"
}

check_result() { # <label> <expected slug> <script stdout>
  local label="$1" want="$2" got
  got="$(grep -o 'collapse-result=.*' <<<"$3" | tail -n1)"
  if [ "${got}" = "collapse-result=${want}" ]; then
    pass "$label"
  else
    fail "$label" "expected: collapse-result=${want}" "actual:   ${got:-<none>}"
  fi
}

check_calls() { # <label> <predicate result 0/1>
  if [ "$2" -eq 0 ]; then pass "$1"; else fail "$1" "call log:" "$(calls)"; fi
}

# --- Happy path: bot PR with a single change request -----------------------
OUT="$(run_collapse dependency "$CR")"; RC=$?
check_result "actor: bot PR + CHANGES_REQUESTED collapses" collapsed "$OUT"
[ "$RC" -eq 0 ] && pass "actor: exits 0 on the happy path" \
  || fail "actor: exits 0 on the happy path" "rc=${RC}"
called "/reviews/11/dismissals"; check_calls "actor: dismisses the change request" $?
called "--method POST"; check_calls "actor: posts a COMMENT review" $?
called "--add-reviewer SpiceLabsHQ/reviewers"; check_calls "actor: requests the reviewers team" $?
called "--add-label pepper-needs-review"; check_calls "actor: adds pepper-needs-review" $?
called "--remove-label pepper-changes-requested"; check_calls "actor: removes pepper-changes-requested" $?
[ "$(states_of CHANGES_REQUESTED)" = "0" ] \
  && pass "actor: no change request is left blocking" \
  || fail "actor: no change request is left blocking" "reviews: $(cat "${WORK}/reviews.json")"

# --- ALL of them. Six live change requests, each blocking independently -----
OUT="$(run_collapse dependency "$SIX")"
check_result "actor: six change requests collapse" collapsed "$OUT"
MISSED=""
for i in 11 12 13 14 15 16; do
  called "/reviews/${i}/dismissals" || MISSED="${MISSED} ${i}"
done
[ -z "${MISSED}" ] && pass "actor: every one of the six is dismissed" \
  || fail "actor: every one of the six is dismissed" "never dismissed:${MISSED}" "call log:" "$(calls)"
[ "$(states_of CHANGES_REQUESTED)" = "0" ] \
  && pass "actor: none of the six is left blocking" \
  || fail "actor: none of the six is left blocking" "still blocking: $(states_of CHANGES_REQUESTED)"
[ "$(calls | grep -c -- '--method POST')" = "1" ] \
  && pass "actor: six change requests produce ONE comment" \
  || fail "actor: six change requests produce ONE comment" "call log:" "$(calls)"

# --- A COMMENT interleaved among the change requests -----------------------
# The COMMENT clears nothing, so the change requests under it are still live.
# This is the case the previous, newest-review-wins selector got wrong: it read
# the COMMENT as Pepper's verdict and stood down while the PR stayed blocked.
OUT="$(run_collapse dependency "$CR_THEN_COMMENT")"
check_result "actor: a newer COMMENT does not hide the change requests" collapsed "$OUT"
called "/reviews/11/dismissals"; check_calls "actor: interleaved — the older change request is dismissed" $?
called "/reviews/13/dismissals"; check_calls "actor: interleaved — the newer change request is dismissed" $?
not_called "/reviews/12/dismissals"; check_calls "actor: interleaved — the COMMENT is not dismissed" $?
[ "$(states_of CHANGES_REQUESTED)" = "0" ] \
  && pass "actor: interleaved — nothing is left blocking" \
  || fail "actor: interleaved — nothing is left blocking" "reviews: $(cat "${WORK}/reviews.json")"

# --- The guard: a later approval already cleared the block ------------------
# The stale CHANGES_REQUESTED row is history. Acting on it would dismiss settled
# reviews and post a collapse comment on a PR nobody is stuck on.
OUT="$(run_collapse dependency "$STALE_UNDER_APPROVAL")"
check_result "actor: stale change request under an approval is untouched" \
  "skipped:already-approved" "$OUT"
not_called "/dismissals"; check_calls "actor: approved — no dismissal" $?
not_called "--method POST"; check_calls "actor: approved — NO comment posted" $?
not_called "--add-label"; check_calls "actor: approved — no label change" $?

# --- Bot PR + approval only ------------------------------------------------
OUT="$(run_collapse dependency "[$(review 11 APPROVED 2026-07-10T00:00:00Z)]")"
check_result "actor: bot PR + approval is untouched" "skipped:already-approved" "$OUT"
not_called "/dismissals"; check_calls "actor: approval — no dismissal" $?
not_called "--method POST"; check_calls "actor: approval — no comment review" $?

# --- No Pepper review at all -----------------------------------------------
OUT="$(run_collapse dependency '[]')"
check_result "actor: no Pepper review is untouched" "skipped:no-pepper-review" "$OUT"
not_called "/dismissals"; check_calls "actor: no review — no dismissal" $?
not_called "--method POST"; check_calls "actor: no review — no comment posted" $?
not_called "--add-label"; check_calls "actor: no review — no label change" $?

# --- Human PR + change request: nothing may be touched ---------------------
OUT="$(run_collapse default "$CR")"
check_result "actor: human PR + CHANGES_REQUESTED is untouched" "skipped:not-a-bot-pr" "$OUT"
not_called "/dismissals"; check_calls "actor: human PR — no dismissal" $?
not_called "--method POST"; check_calls "actor: human PR — no comment review" $?
not_called "--add-label"; check_calls "actor: human PR — no label change" $?

# --- Failure path A: no dismissal takes ------------------------------------
# The findings are already re-filed (a COMMENT clears nothing, so posting it
# first is free), but the PR is still blocked — so no label may move, and the
# surviving CHANGES_REQUESTED rows must leave the collapse retryable.
touch "${WORK}/fail_dismiss"
OUT="$(run_collapse dependency "$CR")"; RC=$?
rm -f "${WORK}/fail_dismiss"
check_result "actor: rejected dismissal reports dismiss-incomplete" dismiss-incomplete "$OUT"
[ "$RC" -eq 0 ] && pass "actor: rejected dismissal does not fail the run" \
  || fail "actor: rejected dismissal does not fail the run" "rc=${RC}"
called "--method POST"; check_calls "actor: rejected dismissal — findings are re-filed anyway" $?
not_called "--add-label"; check_calls "actor: rejected dismissal — labels NOT swapped" $?
called "--add-reviewer SpiceLabsHQ/reviewers"; check_calls "actor: rejected dismissal — human still requested" $?
grep -q '::warning::' <<<"$OUT" && pass "actor: rejected dismissal is annotated" \
  || fail "actor: rejected dismissal is annotated" "$OUT"

# THE REGRESSION FIXTURE (DEV-674). A failed dismissal must leave the PR in a
# state a LATER run retries. The comment this run posted is now Pepper's NEWEST
# review — under the previous newest-review-wins selector every later run would
# have read it as "not changes requested" and stood down forever while the change
# request kept blocking. The corrected selector cannot see a COMMENT at all.
[ "$(states_of CHANGES_REQUESTED)" = "1" ] \
  && pass "actor: after a failed dismissal the change request is still live" \
  || fail "actor: after a failed dismissal the change request is still live" \
       "reviews: $(cat "${WORK}/reviews.json")"

OUT="$(rerun_collapse dependency)"
check_result "actor: a later run RETRIES the collapse after a failed dismissal" collapsed "$OUT"
called "/reviews/11/dismissals"; check_calls "actor: retry — the change request is dismissed on the second attempt" $?
called "--add-label pepper-needs-review"; check_calls "actor: retry — labels swapped once it took" $?
not_called "--method POST"; check_calls "actor: retry — the comment is NOT posted twice" $?

# A dismissal call that "succeeds" but leaves the review blocking is the same
# failure, and is only caught by the read-back.
touch "${WORK}/silent_dismiss"
OUT="$(run_collapse dependency "$CR")"
rm -f "${WORK}/silent_dismiss"
check_result "actor: silent no-op dismissal is caught by the read-back" dismiss-incomplete "$OUT"
not_called "--add-label"; check_calls "actor: silent no-op — labels NOT swapped" $?
[ "$(states_of CHANGES_REQUESTED)" = "1" ] \
  && pass "actor: silent no-op leaves the PR retryable" \
  || fail "actor: silent no-op leaves the PR retryable" "reviews: $(cat "${WORK}/reviews.json")"

# --- Failure path A': PARTIAL dismissal ------------------------------------
# One of the four rows refuses. The PR is still blocked by that one, so the
# labels must not move — this is the exact failure a dismiss-the-newest-only
# implementation produces on every multi-round PR.
touch "${WORK}/fail_one"
OUT="$(run_collapse dependency "$CR_THEN_COMMENT")"
rm -f "${WORK}/fail_one"
check_result "actor: a partial dismissal is not reported as collapsed" dismiss-incomplete "$OUT"
not_called "--add-label"; check_calls "actor: partial — labels NOT swapped" $?
[ "$(states_of CHANGES_REQUESTED)" = "1" ] \
  && pass "actor: partial — the surviving change request is still selectable" \
  || fail "actor: partial — the surviving change request is still selectable" \
       "reviews: $(cat "${WORK}/reviews.json")"
OUT="$(rerun_collapse dependency)"
check_result "actor: partial — a later run finishes the job" collapsed "$OUT"
[ "$(states_of CHANGES_REQUESTED)" = "0" ] \
  && pass "actor: partial — nothing is left blocking after the retry" \
  || fail "actor: partial — nothing is left blocking after the retry" \
       "reviews: $(cat "${WORK}/reviews.json")"

# --- Failure path B: the comment cannot be posted --------------------------
# Comment-first is the fail-safe direction: nothing has been dismissed yet, so
# stopping here destroys nothing. The change request stands, the PR reads exactly
# as it did before, and the next run retries the whole collapse.
touch "${WORK}/fail_comment"
OUT="$(run_collapse dependency "$CR")"; RC=$?
rm -f "${WORK}/fail_comment"
check_result "actor: a failed comment stops before any dismissal" comment-failed "$OUT"
[ "$RC" -eq 0 ] && pass "actor: comment failure does not fail the run" \
  || fail "actor: comment failure does not fail the run" "rc=${RC}"
not_called "/dismissals"; check_calls "actor: comment failure — NOTHING was dismissed" $?
not_called "--add-label"; check_calls "actor: comment failure — labels NOT swapped" $?
called "--add-reviewer SpiceLabsHQ/reviewers"; check_calls "actor: comment failure — human still requested" $?
grep -q '::warning::' <<<"$OUT" && pass "actor: comment failure is annotated" \
  || fail "actor: comment failure is annotated" "$OUT"
[ "$(states_of CHANGES_REQUESTED)" = "1" ] \
  && pass "actor: comment failure leaves the finding intact and the PR retryable" \
  || fail "actor: comment failure leaves the finding intact and the PR retryable" \
       "reviews: $(cat "${WORK}/reviews.json")"

# --- Failure path C: the team cannot be requested --------------------------
# The team lacking repo read access must not undo the collapse.
touch "${WORK}/fail_reviewer"
OUT="$(run_collapse dependency "$CR")"
rm -f "${WORK}/fail_reviewer"
check_result "actor: reviewer-request failure still collapses" collapsed "$OUT"
called "/reviews/11/dismissals"; check_calls "actor: reviewer failure — dismissal still happened" $?
called "--add-label pepper-needs-review"; check_calls "actor: reviewer failure — labels still swapped" $?

# --- Failure path D: no reviewers_team at all ------------------------------
# The escalation is the whole second half of the collapsed outcome set. A caller
# that has emptied `reviewers_team` gets a PR that is commented on and left for
# nobody, and that must be loud in the log rather than silent.
OUT="$(run_collapse dependency "$CR" "")"
check_result "actor: an empty reviewers_team still collapses" collapsed "$OUT"
not_called "--add-reviewer"; check_calls "actor: empty reviewers_team — no reviewer requested" $?
grep -q '::warning::.*reviewers_team' <<<"$OUT" \
  && pass "actor: an unset reviewers_team is named in a ::warning::" \
  || fail "actor: an unset reviewers_team is named in a ::warning::" "$OUT"

echo
if [ "$fails" -eq 0 ]; then
  echo "All checks passed."
else
  echo "${fails} check(s) failed."
  exit 1
fi
