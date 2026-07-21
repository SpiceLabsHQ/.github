# Per-PR decision for the Pepper stranded-PR sweep (DEV-667).
#
# Pure function: given one PR plus its reviews and issue timeline, decide whether
# the sweep should nudge it (close -> reopen, to re-fire the injected floor
# review) or leave it alone. Kept as a standalone program so the decision can be
# exercised against fixtures by scripts/test/pepper-stranded-sweep-decide_test.sh
# without touching the network — the same split as org-repo-settings-plan.jq.
#
# Two DISTINCT identities, per ADR-0007 (one App per capability, no borrowing):
#   $review_bot        — the App that posts reviews, "pepper-pr-review[bot]".
#                        Answers "does this PR have a current Pepper verdict?"
#   $sweep_bot         — the App that reopens stranded PRs, "spice-pepper-sweep[bot]".
#                        Answers "did WE already nudge this PR?"
# Keeping them separate is not just policy compliance: it makes the backoff exact.
# With a single shared login, any reopen by Pepper's App — for any reason, now or
# later — would read as one of our nudges and silently suppress a real one.
#
# Other inputs:
#   $excluded_authors  — JSON array of PR author logins the floor never reviews.
#   $pr                — {draft, user:{login}, head:{sha}}
#   $reviews           — GET /repos/{o}/{r}/pulls/{n}/reviews
#   $timeline          — GET /repos/{o}/{r}/issues/{n}/timeline
#
# Output: {"action": "nudge"|"skip", "reason": "<slug>"}

# Pepper's SUBMITTED reviews only. A pending (unsubmitted) review carries a null
# submitted_at and would sort ahead of real ones, so drop it here rather than
# reason about nulls downstream.
def bot_reviews:
  [$reviews[]? | select(.user.login == $review_bot and .submitted_at != null)];

# Pepper's most recent review, or null if it has never reviewed this PR.
def last_review:
  (bot_reviews | sort_by(.submitted_at) | last);

# When the sweep last nudged this PR, or null if it never has. GitHub records the
# reopen in the issue timeline with the acting App's login, so the nudge history
# needs no side-channel state (no label to create org-wide, no comment to parse)
# and it self-clears: a PR that gets its review simply stops being a candidate.
def last_nudge_at:
  ([$timeline[]? | select(.event == "reopened" and .actor.login == $sweep_bot) | .created_at]
   | sort | last);

if ($pr.draft // false) then
  # The floor deliberately does not auto-review drafts, so a draft is not stranded.
  {action: "skip", reason: "draft"}

elif (($excluded_authors | index($pr.user.login)) != null) then
  # Inherit the floor's own author exclusions (rosemary-releaser release PRs, etc.)
  # so the sweep never fights an intentional skip.
  {action: "skip", reason: "excluded-author"}

elif (last_review != null and last_review.commit_id == $pr.head.sha) then
  # Pepper's newest verdict is against the current head — this PR is reviewed.
  # Same "current verdict" test as the DEV-523 unchanged-SHA short-circuit.
  {action: "skip", reason: "current-verdict"}

elif (last_nudge_at != null
      and ((last_review == null) or (last_review.submitted_at <= last_nudge_at))) then
  # Backoff: we already nudged and no review has landed since. Nudging again would
  # be a reopen loop against a floor that is not responding. Leave it for a human.
  # Note this is deliberately time-based, not SHA-based: a review that landed AFTER
  # the nudge but on a since-superseded SHA is a FRESH stranding, and falls through
  # to nudge below.
  {action: "skip", reason: "awaiting-nudge"}

else
  {action: "nudge", reason: "stranded"}
end
