#!/usr/bin/env bash
# Fixture test for org-repo-settings-plan.jq — the planning logic behind the org
# repo-settings reconciler. Exercises the EXACT program the reconciler runs
# (jq -f org-repo-settings-plan.jq), so it can't drift from production.
# Self-asserting: exits non-zero on mismatch.
#
# The case that matters most is `drift on one field of a coupled group` (DEV-631):
# the reconciler used to PATCH only the drifted field, and GitHub rejected it
# with 422 invalid_squash_commit_setting_combo because it validates squash
# title/message as a pair against the request's defaults, not the repo's stored
# values. That path first ran in production, on a schedule, and stayed red for
# six nights. It is pinned here so it never ships unexercised again.
#
# Run locally:  scripts/test/org-repo-settings-plan_test.sh
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLAN="${HERE}/../org-repo-settings-plan.jq"

fails=0

# Run the real plan program. Args: <cur> <groups> <skips>
plan() {
  jq -cn --argjson cur "$1" --argjson groups "$2" --arg skips "$3" -f "$PLAN"
}

# Assert one field of the plan output equals the expected JSON (order-insensitive).
check() {
  local label="$1" field="$2" expected="$3" actual="$4"
  if diff <(jq -S . <<<"$expected") <(jq -S . <<<"$actual") >/dev/null 2>&1; then
    echo "PASS: ${label} — ${field}"
  else
    echo "FAIL: ${label} — ${field}"
    echo "  expected: $(jq -Sc . <<<"$expected" 2>/dev/null || printf '%s' "$expected")"
    echo "  actual:   $(jq -Sc . <<<"$actual"   2>/dev/null || printf '%s' "$actual")"
    fails=$((fails + 1))
  fi
}

# The real `merge` group from repo-settings.yml: squash-only, PR_TITLE + PR_BODY.
# squash_merge_commit_title and squash_merge_commit_message are co-validated by
# GitHub and so must travel together in any PATCH.
groups='{"merge":{
  "allow_squash_merge":true,
  "allow_merge_commit":false,
  "allow_rebase_merge":false,
  "squash_merge_commit_title":"PR_TITLE",
  "squash_merge_commit_message":"PR_BODY"
}}'

# --- Case 1: the DEV-631 regression -----------------------------------------
# Reaper-Linear-Agent's real live state: conformant except the squash message.
# Title is already PR_TITLE — legal with PR_BODY — but it MUST still be in the
# PATCH, or GitHub defaults it to COMMIT_OR_PR_TITLE and 422s the combination.
cur1='{"allow_squash_merge":true,"allow_merge_commit":false,"allow_rebase_merge":false,
       "squash_merge_commit_title":"PR_TITLE","squash_merge_commit_message":"COMMIT_MESSAGES"}'
p1="$(plan "$cur1" "$groups" "")"
check "drift on one field of a coupled group" "drifted lists only the changed field" \
  '{"squash_merge_commit_message":"PR_BODY"}' "$(jq -c .drifted <<<"$p1")"
check "drift on one field of a coupled group" "patch carries the WHOLE group (the fix)" \
  "$(jq -c '.merge' <<<"$groups")" "$(jq -c .patch <<<"$p1")"
# The invariant, stated directly: a PATCH touching the squash message must also
# carry the squash title, or GitHub rejects it.
if [ "$(jq -r 'has("squash_merge_commit_title")' <<<"$(jq -c .patch <<<"$p1")")" = "true" ]; then
  echo "PASS: drift on one field of a coupled group — squash title accompanies the message"
else
  echo "FAIL: patch omits squash_merge_commit_title — this is the 422 that caused DEV-631"
  fails=$((fails + 1))
fi

# --- Case 2: conformant repo -> no drift, no API call ------------------------
cur2="$(jq -c '. + {"squash_merge_commit_message":"PR_BODY"}' <<<"$cur1")"
p2="$(plan "$cur2" "$groups" "")"
check "conformant repo" "no drift"        '{}' "$(jq -c .drifted <<<"$p2")"
check "conformant repo" "empty patch (no PATCH is issued)" '{}' "$(jq -c .patch <<<"$p2")"

# --- Case 3: group excepted via the exception property -----------------------
p3="$(plan "$cur1" "$groups" "merge")"
check "excepted group" "no drift"  '{}' "$(jq -c .drifted <<<"$p3")"
check "excepted group" "no patch"  '{}' "$(jq -c .patch   <<<"$p3")"
if [ "$(jq -r .active_fields <<<"$p3")" -eq 0 ]; then
  echo "PASS: excepted group — active_fields is 0 (repo reported as skipped)"
else
  echo "FAIL: excepted group — active_fields should be 0, got $(jq -r .active_fields <<<"$p3")"
  fails=$((fails + 1))
fi

# --- Case 4: an unrelated exception leaves the group in force ----------------
p4="$(plan "$cur1" "$groups" "team_access")"
check "unrelated exception" "group still reconciled" \
  '{"squash_merge_commit_message":"PR_BODY"}' "$(jq -c .drifted <<<"$p4")"

# --- Case 5: multiple groups — only the drifted group is PATCHed -------------
# Guards the coupling boundary: a conformant group must not be dragged into
# another group's PATCH (its fields are not co-validated with the drifted ones).
groups5="$(jq -c '. + {"features":{"has_wiki":false,"has_projects":false}}' <<<"$groups")"
cur5="$(jq -c '. + {"has_wiki":false,"has_projects":false}' <<<"$cur1")"
p5="$(plan "$cur5" "$groups5" "")"
check "two groups, one drifted" "patch carries only the drifted group" \
  "$(jq -c '.merge' <<<"$groups")" "$(jq -c .patch <<<"$p5")"

# --- Case 6: drift in both groups -> both PATCHed in one call ----------------
cur6="$(jq -c '. + {"has_wiki":true}' <<<"$cur5")"
p6="$(plan "$cur6" "$groups5" "")"
check "two groups, both drifted" "patch carries both groups in one atomic call" \
  "$(jq -c '.merge + .features' <<<"$groups5")" "$(jq -c .patch <<<"$p6")"

echo
if [ "$fails" -eq 0 ]; then
  echo "All plan fixtures passed."
  exit 0
fi
echo "${fails} plan fixture(s) failed."
exit 1
