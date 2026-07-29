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
# blocked at all — posting a collapse comment and dismissing settled history.
#
# The guard is "is there an APPROVED newer than the newest CHANGES_REQUESTED",
# NOT "is the newest review APPROVED". The second is a strictly weaker test and
# misses the ordinary lifecycle it was written for:
#
#   CHANGES_REQUESTED -> APPROVED -> COMMENTED
#
# The newest row there is a COMMENT, so a newest-review test lets the collapse
# run on a PR that is approved and about to auto-merge. That sequence is not
# exotic: prompts/pr-review-default.md drives `gh pr review --comment` as a
# routine verdict, and floor-pepper.yml triggers on `synchronize`, which fires on
# every Renovate rebase. Comparing timestamps is the whole fix — GitHub's
# `submitted_at` is ISO-8601 with a `Z` offset, so lexical `>=` on the strings is
# chronological, and a tie resolves in favour of the approval (do not collapse).
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
# `body` is the NEWEST change request's body only. On a PR with several rounds the
# older findings are not concatenated into the comment — they survive on their own
# dismissed reviews, which keep their bodies (see #119's `4632718270` above), and
# the human this escalates to reads the review timeline. Re-filing all six of
# #138's bodies inline would bury the current one.
#
# `marker` is an invisible HTML comment keyed to the newest change request's id,
# carried in the comment this collapses to. `comment_needed` is false when a
# Pepper `COMMENT` review already carries that marker. It suppresses the ordinary
# retry duplicate — same change requests, same newest id — but it is NOT an
# unconditional guarantee of one comment per PR: if the newest change request is
# dismissed and an older one survives, the marker rekeys to the survivor and the
# next run posts a second comment. That is bounded at one extra comment, and it
# carries a finding that had not been re-filed, so it is left alone rather than
# papered over with a PR-wide marker that would also swallow a genuinely new
# round's findings.

# Pepper's reviews. No `submitted_at` filter: only `CHANGES_REQUESTED` and
# `APPROVED` rows are ever selected below, and a review that has not been
# submitted carries `state: "PENDING"`, so it cannot reach either branch.
def bot_reviews:
  [$reviews[]? | select(.user.login == $bot)];

def change_requests:
  ([bot_reviews[] | select(.state == "CHANGES_REQUESTED")] | sort_by(.submitted_at));

def newest_cr:
  (change_requests | last);

def newest_approval:
  ([bot_reviews[] | select(.state == "APPROVED")] | sort_by(.submitted_at) | last);

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

elif (newest_approval != null
      and (newest_cr == null
           or newest_approval.submitted_at >= newest_cr.submitted_at)) then
  # THE GUARD. An approval no older than the newest change request means the
  # block is already cleared; the CHANGES_REQUESTED rows underneath it are
  # history, not a deadlock. Touching them would post a collapse comment on a PR
  # nobody is stuck on — and on the auto-merge path (ADR-0017) an approval IS the
  # merge, so this is also the path that must never be disturbed. Note this fires
  # regardless of what came after the approval: a later COMMENT (a routine
  # verdict, and a routine outcome of a Renovate rebase re-triggering the review)
  # changes nothing about the fact that the PR is approved.
  skip("already-approved")

elif (newest_cr == null) then
  # No live change request: Pepper has only commented, or every change request was
  # already dismissed (by this step on an earlier run, by a human, or by the
  # ruleset's dismiss-stale-reviews-on-push). Nothing to collapse.
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
