# Per-PR decision for the Pepper stranded-PR sweep (DEV-667).
#
# Pure function: given one PR plus its reviews and issue timeline, decide whether
# the sweep should nudge it (close -> reopen, to re-fire the injected floor
# review) or leave it alone. Kept as a standalone program so the decision can be
# exercised against fixtures by scripts/test/pepper-stranded-sweep-decide_test.sh
# without touching the network — the same split as org-repo-settings-plan.jq.
#
# Inputs (all required):
#   $bot               — Pepper's App login, "pepper-pr-review[bot]". ONE login
#                        answers both questions this program asks — "does this PR
#                        have a current Pepper verdict?" and "did we already nudge
#                        it?" — because the review and the sweep are two actions of
#                        a single capability sharing a single App (ADR-0007's rule
#                        is one App per *capability*, and this is one). A reopen by
#                        this login IS the sweep: nothing else in Pepper reopens PRs.
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
  [$reviews[]? | select(.user.login == $bot and .submitted_at != null)];

# Pepper's most recent review, or null if it has never reviewed this PR.
def last_review:
  (bot_reviews | sort_by(.submitted_at) | last);

# When the sweep last nudged this PR, or null if it never has. GitHub records the
# reopen in the issue timeline with the acting App's login, so the nudge history
# needs no side-channel state (no label to create org-wide, no comment to parse)
# and it self-clears: a PR that gets its review simply stops being a candidate.
def last_nudge_at:
  ([$timeline[]? | select(.event == "reopened" and .actor.login == $bot) | .created_at]
   | sort | last);

if ($pr.draft // false) then
  # The floor deliberately does not auto-review drafts, so a draft is not stranded.
  {action: "skip", reason: "draft"}

elif ($pr.user.login | endswith("[bot]")) then
  # NEVER nudge a bot-authored PR (DEV-667 incident). The nudge is a close ->
  # reopen, and a bot reads the close through its OWN semantics, not ours:
  # Dependabot treats a manual close as "rejected", comments "I won't notify you
  # again about this release", and abandons the update. So a nudge meant to
  # trigger a review instead SUPPRESSES a real dependency bump. We cannot know
  # any given bot's close-handling, so the fail-safe is categorical — no bot's
  # PR is ever closed by this sweep — rather than an allowlist of the bots whose
  # behavior we happen to have learned. This costs almost nothing: bots open
  # their PRs ready (not draft), so they are essentially never stranded by the
  # draft->ready gap this sweep exists to close. `endswith("[bot]")` is how the
  # floor's own bot-initiator gate (DEV-504) recognizes a bot login; note that
  # Pepper's review App shares that suffix, but Pepper opens no PRs, so it never
  # reaches this check as an author.
  {action: "skip", reason: "bot-author"}

elif (($excluded_authors | index($pr.user.login)) != null) then
  # Inherit the floor's own author exclusions. NOTE: the bot check above already
  # subsumes the current entries (rosemary-releaser[bot] is a bot); this stays as
  # the hook for any FUTURE non-bot author the floor decides to exclude, so the
  # two exclusion lists cannot silently diverge.
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
