# Bot-PR outcome collapse: the decision half (DEV-674).
#
# On a bot-authored PR the outcome set must be {approve, comment_and_escalate}.
# `CHANGES_REQUESTED` is a dead letter there: Renovate and Dependabot have no
# reader for a review body, and the verdict can only be cleared by a push the bot
# has no reason to make or by a dismissal. This program answers one question —
# "are there live Pepper change requests on this PR that must be collapsed?" —
# and hands the acting half (pepper-bot-outcome-collapse.sh) the review ids and
# the body it needs.
#
# Pure function, no network, so scripts/test/pepper-bot-outcome-collapse_test.sh
# can pin every case against fixtures. Same split as pepper-stranded-sweep-decide.jq
# and org-repo-settings-plan.jq.
#
# WHAT CLEARS A CHANGE REQUEST. Only a same-reviewer approval or an explicit
# dismissal. A `COMMENT` review supersedes nothing — GitHub's own schema says so:
#
#   gh api graphql -f query='{__type(name:"PullRequestReviewState")
#                             {enumValues{name description}}}'
#     COMMENTED         -> "An informational review."
#     CHANGES_REQUESTED -> "A review blocking the pull request from merging."
#     DISMISSED         -> "A review that has been dismissed."
#
# So the selector is `state == "CHANGES_REQUESTED"`, one condition on one field.
# There is no separate `dismissed` flag to test: a dismissal REWRITES `state` in
# place, which is what makes this program idempotent — a row this step already
# collapsed reads `DISMISSED` and is no longer selected. Verified on this repo:
#
#   gh api repos/SpiceLabsHQ/.github/pulls/119/reviews \
#     --jq '.[]|{id,state,user:.user.login}'
#     4632652148 CHANGES_REQUESTED pepper-pr-review[bot]
#     4632718270 DISMISSED         pepper-pr-review[bot]
#     4632732806 APPROVED          pepper-pr-review[bot]
#
# THE GUARD, and why #119 above is exactly it. A later approval clears the block
# but does NOT rewrite the earlier change request's row: `4632652148` still reads
# `CHANGES_REQUESTED` on a PR that merged two weeks ago. Selecting every
# `CHANGES_REQUESTED` row with no guard would therefore fire on a PR that is not
# blocked at all — posting a collapse comment and dismissing settled history. So:
# act only when Pepper's NEWEST submitted review is not `APPROVED`.
#
# ALL OF THEM, not the newest one. Each `CHANGES_REQUESTED` blocks independently
# and each needs its own dismissal. SpiceLabsHQ/.github#138 carries six:
#
#   gh api repos/SpiceLabsHQ/.github/pulls/138/reviews \
#     --jq '[.[]|.state]|group_by(.)|map({(.[0]):length})|add'
#     {"CHANGES_REQUESTED":6}
#
# Inputs (all required):
#   $bot      — Pepper's App login, "<app-slug>[bot]". Empty when the token
#               action gave us no app-slug; we then cannot tell Pepper's reviews
#               from a human's and must stand down rather than guess.
#   $flavor   — author class, "dependency" for an enumerated dependency bot's PR,
#               "default" otherwise. Checked here as well as in the workflow step
#               so the human-authored case is pinned by a fixture and not only by
#               a shell `case`.
#   $reviews  — GET /repos/{o}/{r}/pulls/{n}/reviews, all pages, as one array.
#
# Output:
#   {"action": "collapse"|"skip", "reason": "<slug>", "review_ids": [<id>...],
#    "body": "<newest change request's body>", "marker": "<html comment>",
#    "comment_needed": true|false}
#
# `marker` is an invisible HTML comment keyed to the newest change request's id,
# carried in the comment this collapses to. `comment_needed` is false when a
# Pepper `COMMENT` review already carries that marker, so a run retrying a failed
# dismissal re-files nothing and the PR does not collect duplicates.

# Pepper's SUBMITTED reviews. A pending (unsubmitted) review carries a null
# submitted_at and would sort ahead of every real one, so drop it here.
def bot_reviews:
  [$reviews[]? | select(.user.login == $bot and .submitted_at != null)];

def newest_review:
  (bot_reviews | sort_by(.submitted_at) | last);

def change_requests:
  ([bot_reviews[] | select(.state == "CHANGES_REQUESTED")] | sort_by(.submitted_at));

def skip($reason):
  {action: "skip", reason: $reason, review_ids: [], body: "",
   marker: "", comment_needed: false};

if $flavor != "dependency" then
  # Human-authored (or any non-enumerated author): CHANGES_REQUESTED is
  # actionable, because the author can read it and push a fix. Leave it alone.
  skip("not-a-bot-pr")

elif ($bot | length) == 0 then
  # No app-slug. Every other identity-dependent path in this workflow fails open
  # the same way (the DEV-523 short-circuit runs the review rather than guess);
  # here failing open means leaving the verdict exactly as Pepper filed it.
  # Honest and blocked beats dismissing some other reviewer's verdict.
  skip("unknown-bot-identity")

elif (bot_reviews | length) == 0 then
  skip("no-pepper-review")

elif (newest_review.state == "APPROVED") then
  # THE GUARD. The block is already cleared; the stale CHANGES_REQUESTED rows
  # underneath it are history, not a deadlock. Touching them would post a
  # collapse comment on a PR nobody is stuck on — and on the auto-merge path
  # (ADR-0017) an approval is the merge, so this is also the path that must never
  # be disturbed.
  skip("already-approved")

elif ((change_requests | length) == 0) then
  # No live change request: the newest review is a COMMENT, or every change
  # request was already dismissed (by this step on an earlier run, by a human, or
  # by the ruleset's dismiss-stale-reviews-on-push). Nothing to collapse.
  skip("no-changes-requested")

else
  # Deliberately not filtered by head SHA: what blocks the PR is the review's
  # state, whatever commit it was filed against. A stale CHANGES_REQUESTED is
  # exactly as unclearable by a bot as a fresh one. This step is the BACKSTOP for
  # the runs where Pepper should not have filed one at all (DEV-670's gate skip is
  # the primary defense).
  (change_requests | last) as $live |
  ("<!-- pepper-collapse:\($live.id) -->") as $marker |
  {action: "collapse",
   reason: "bot-pr-changes-requested",
   review_ids: [change_requests[].id],
   body: ($live.body // ""),
   marker: $marker,
   comment_needed:
     (([bot_reviews[]
        | select(.state == "COMMENTED" and ((.body // "") | contains($marker)))]
       | length) == 0)}
end
