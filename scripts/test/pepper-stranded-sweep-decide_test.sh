#!/usr/bin/env bash
# Fixture test for pepper-stranded-sweep-decide.jq — the per-PR decision behind
# the stranded-PR sweep (DEV-667). Exercises the EXACT program the sweep runs
# (jq -f pepper-stranded-sweep-decide.jq), so it cannot drift from production.
# Self-asserting: exits non-zero on mismatch.
#
# The cases that matter most are the two guardrails, because both fail SILENTLY
# and expensively in production if they regress:
#   - `awaiting-nudge`: a broken backoff turns the sweep into a reopen loop,
#     closing and reopening the same PR every schedule tick forever.
#   - `current-verdict`: a broken verdict test nudges already-reviewed PRs,
#     spending a Bedrock-billed review each time.
# Neither shows up as a red check — only as churn — so they are pinned here.
#
# Run locally:  scripts/test/pepper-stranded-sweep-decide_test.sh
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DECIDE="${HERE}/../pepper-stranded-sweep-decide.jq"

# One App for both actions: Pepper reviews AND, via the sweep, reopens. They are
# two actions of one capability, so one login answers both of the program's
# questions.
BOT='pepper-pr-review[bot]'
EXCLUDED='["rosemary-releaser[bot]"]'

fails=0

# Run the real decision program. Args: <pr> <reviews> <timeline>
decide() {
  jq -cn --arg bot "$BOT" --argjson excluded_authors "$EXCLUDED" \
    --argjson pr "$1" --argjson reviews "$2" --argjson timeline "$3" -f "$DECIDE"
}

# Assert the decision for one scenario.
check() {
  local label="$1" expected_action="$2" expected_reason="$3" actual="$4"
  local action reason
  action="$(jq -r '.action' <<<"$actual")"
  reason="$(jq -r '.reason' <<<"$actual")"
  if [ "$action" = "$expected_action" ] && [ "$reason" = "$expected_reason" ]; then
    echo "PASS: ${label}"
  else
    echo "FAIL: ${label}"
    echo "  expected: ${expected_action}/${expected_reason}"
    echo "  actual:   ${action}/${reason}"
    fails=$((fails + 1))
  fi
}

pr()       { jq -cn --arg sha "$1" --arg author "${2:-alice}" --argjson draft "${3:-false}" \
               '{draft: $draft, user: {login: $author}, head: {sha: $sha}}'; }
review()   { jq -cn --arg sha "$1" --arg at "$2" --arg who "${3:-$BOT}" \
               '{commit_id: $sha, submitted_at: $at, user: {login: $who}}'; }
reopened() { jq -cn --arg at "$1" --arg who "${2:-$BOT}" \
               '{event: "reopened", created_at: $at, actor: {login: $who}}'; }
# A review the reviewer has started but not submitted: submitted_at is null.
pending()  { jq -cn --arg sha "$1" --arg who "${2:-$BOT}" \
               '{commit_id: $sha, submitted_at: null, user: {login: $who}}'; }

# --- The stranding this sweep exists for -----------------------------------
# Draft -> ready with no push: the floor never saw ready_for_review (DEV-576),
# so there is no Pepper review at all on a non-draft PR.
check "never reviewed, never nudged" nudge stranded \
  "$(decide "$(pr sha-a)" '[]' '[]')"

# Stale verdict from when it was a draft: reviewed, but at an older SHA.
check "verdict is stale (older SHA)" nudge stranded \
  "$(decide "$(pr sha-b)" "[$(review sha-a 2026-07-01T00:00:00Z)]" '[]')"

# DEV-465: a new PR reusing a branch already reviewed on this same SHA is NOT
# what this rule catches — the SHA matches, so the sweep correctly stands down
# and DEV-465 is handled by the review living on the branch, not by a nudge.
check "verdict is current" skip current-verdict \
  "$(decide "$(pr sha-a)" "[$(review sha-a 2026-07-01T00:00:00Z)]" '[]')"

# --- Guardrail: no re-nudge (backoff) --------------------------------------
check "nudged, no review since" skip awaiting-nudge \
  "$(decide "$(pr sha-a)" '[]' "[$(reopened 2026-07-02T00:00:00Z)]")"

check "nudged, only a review predating the nudge" skip awaiting-nudge \
  "$(decide "$(pr sha-b)" "[$(review sha-a 2026-07-01T00:00:00Z)]" \
     "[$(reopened 2026-07-02T00:00:00Z)]")"

# A review that landed AFTER the nudge means the nudge worked. A later push then
# strands the PR again — a FRESH stranding, not a loop, so nudge it.
check "nudge worked, then a new push stranded it again" nudge stranded \
  "$(decide "$(pr sha-c)" "[$(review sha-b 2026-07-03T00:00:00Z)]" \
     "[$(reopened 2026-07-02T00:00:00Z)]")"

# A human reopening the PR is not our nudge and must not trigger the backoff,
# or one manual reopen would permanently exempt a PR from the sweep.
check "reopened by a human, not the sweep" nudge stranded \
  "$(decide "$(pr sha-a)" '[]' "[$(reopened 2026-07-02T00:00:00Z alice)]")"

# The flip side of sharing one login: a reopen by Pepper's App IS the sweep, and
# must trip the backoff. Sound only while nothing else in Pepper reopens PRs — if
# that ever changes, this case is where it breaks, and the identities need
# splitting.
check "reopened by Pepper's App is our own nudge" skip awaiting-nudge \
  "$(decide "$(pr sha-a)" '[]' "[$(reopened 2026-07-02T00:00:00Z "$BOT")]")"

# Newest nudge wins: an old nudge that did get a review must not mask a recent
# nudge that did not.
check "several nudges, newest has no review since" skip awaiting-nudge \
  "$(decide "$(pr sha-c)" "[$(review sha-b 2026-07-03T00:00:00Z)]" \
     "[$(reopened 2026-07-02T00:00:00Z),$(reopened 2026-07-04T00:00:00Z)]")"

# --- Guardrail: never nudge a bot-authored PR (DEV-667 incident) ------------
# The nudge is a close -> reopen, and Dependabot reads the close as "rejected":
# it abandoned a real js-yaml bump the one time the sweep touched its PR. So a
# bot PR is skipped EVEN WHEN genuinely stranded (no review at all here) — the
# categorical rule, not an allowlist of known-bad bots.
check "dependabot PR, stranded, still skipped" skip bot-author \
  "$(decide "$(pr sha-a 'dependabot[bot]')" '[]' '[]')"

check "renovate PR, stranded, still skipped" skip bot-author \
  "$(decide "$(pr sha-a 'renovate[bot]')" '[]' '[]')"

# rosemary-releaser is a bot too, so the bot rule now subsumes the old
# excluded-author path for it. Pinned so a refactor can't quietly let a
# rosemary release PR through to a nudge.
check "rosemary release PR is caught as a bot" skip bot-author \
  "$(decide "$(pr sha-a 'rosemary-releaser[bot]')" '[]' '[]')"

# The bot check must not swallow a human whose name merely CONTAINS "bot".
check "human author containing 'bot' is not a bot" nudge stranded \
  "$(decide "$(pr sha-a 'robotina')" '[]' '[]')"

check "draft PR" skip draft \
  "$(decide "$(pr sha-a alice true)" '[]' '[]')"

# --- Reading Pepper's reviews out of a mixed list ---------------------------
# Someone else's approval is not a Pepper verdict; the PR is still stranded.
check "human review only" nudge stranded \
  "$(decide "$(pr sha-a)" "[$(review sha-a 2026-07-01T00:00:00Z alice)]" '[]')"

# A PENDING review carries a null submitted_at. Sorting it as the newest would
# read as "reviewed at commit null" and wrongly strand-or-skip the PR.
check "pending review ignored, real verdict is current" skip current-verdict \
  "$(decide "$(pr sha-a)" \
     "[$(review sha-a 2026-07-01T00:00:00Z),$(pending sha-zzz)]" '[]')"

# Out-of-order pages must not change which review is newest.
check "reviews arrive out of order" skip current-verdict \
  "$(decide "$(pr sha-b)" \
     "[$(review sha-b 2026-07-05T00:00:00Z),$(review sha-a 2026-07-01T00:00:00Z)]" '[]')"

echo
if [ "$fails" -eq 0 ]; then
  echo "All checks passed."
else
  echo "${fails} check(s) failed."
  exit 1
fi
