#!/usr/bin/env bash
# Bot-PR outcome collapse: the acting half (DEV-674).
#
# On a bot-authored PR, collapse Pepper's `CHANGES_REQUESTED` reviews into one
# `COMMENT` review plus a human escalation. The diagnosis is kept — on
# SpiceLabsHQ/.github#138 it was correct and valuable every round — and only its
# audience is redirected, from a bot that cannot read it to a human who can act
# on it.
#
# WHY THIS IS NOT A PROMPT RULE. Removing `--request-changes` from a markdown
# template is not structural. `GH_TOOLS='Bash(gh *)'` leaves the call fully
# available, `REVIEW_DISALLOWED` carries no `gh` entries, and the review prompt
# actively drives the call. An in-context rule is exactly what `<budget_discipline>`
# documents as unreliable under compaction, so the guarantee lives here, after the
# verdict, where it holds regardless of what the model decided to do.
#
# THERE IS NO "CONVERT". No REST operation turns a submitted review into another
# state, so each change request must be DISMISSED:
#   PUT /repos/{owner}/{repo}/pulls/{pull_number}/reviews/{review_id}/dismissals
# `message` is required, `event` optional.
#
# WHAT ACTUALLY CLEARS A CHANGE REQUEST. A same-reviewer approval, or a
# dismissal. Nothing else — a `COMMENT` review is "An informational review" and
# supersedes nothing, per GitHub's own schema:
#   gh api graphql -f query='{__type(name:"PullRequestReviewState")
#                             {enumValues{name description}}}'
# That is why the decision program selects on `state == "CHANGES_REQUESTED"` and
# why this script dismisses EVERY such row rather than only the newest one: they
# block independently. SpiceLabsHQ/.github#138 carries six of them —
#   gh api repos/SpiceLabsHQ/.github/pulls/138/reviews \
#     --jq '[.[]|.state]|group_by(.)|map({(.[0]):length})|add'  -> {"CHANGES_REQUESTED":6}
# — and dismissing one would have left five blocking.
#
# ORDERING: COMMENT FIRST, THEN DISMISS. With the selector above, ordering does
# not affect correctness — a `COMMENT` review is invisible to it, so posting one
# cannot mask anything, and a change request whose dismissal failed is still
# selected on the next run and retried. The step is idempotent by construction.
# Comment-first is chosen because it is the fail-safe direction: if the comment
# cannot be posted we have destroyed nothing and simply stop, whereas dismissing
# first and then failing to comment removes the block on a PR whose findings were
# never re-filed anywhere a human is likely to look.
#
# The ordinary retry does not duplicate the comment: it carries an invisible
# marker keyed to the newest change request's id, and the decision program clears
# `comment_needed` once a Pepper COMMENT review carrying that marker exists. This
# is NOT an unconditional one-comment-per-PR guarantee — if the newest change
# request is dismissed and an older one survives, the marker rekeys to the
# survivor and the next run posts a second comment. See the decision program's
# header for why that is left as is.
#
# Only the NEWEST change request's body is re-filed inline. Older rounds survive
# on their own dismissed reviews, which keep their bodies, and the human this
# escalates to reads the review timeline.
#
# Nothing here exits non-zero: this runs after the verdict, and a failed cleanup
# must not turn a completed review into a red required check (DEV-504 — the floor
# treats this workflow as required).
#
# WHICH MEANS THE ONLY SIGNAL OF A BROKEN COLLAPSE IS A LABEL. If the App turns
# out to be unable to dismiss under this repo's ruleset, every run warns inside a
# green required check and nobody ever looks. So the incomplete path still adds
# `pepper-needs-review` — it routes to a person — while deliberately NOT removing
# `pepper-changes-requested`. Both labels together are the honest reading: changes
# are still requested AND a human is needed. Only a confirmed, complete collapse
# clears the change-requested label.
#
# Collapsing does NOT make the PR mergeable on its own: `reviewDecision` falls
# back to REVIEW_REQUIRED against `required_approving_review_count: 1`, and a
# COMMENT review does not satisfy it. Both terminal states are reachable by
# someone — that is the whole point (DEV-637's principle: never file a verdict the
# author has no path to clear).
#
# RESIDUAL RISK — dismissal permission. The REST docs say dismissing a review on
# a PROTECTED branch requires repo-admin rights or membership of the dismissal
# allowlist. That allowlist is a CLASSIC branch-protection feature and this repo
# does not use classic protection:
#   gh api repos/SpiceLabsHQ/.github/branches/main/protection
#     -> 404 Branch not protected
#   gh api repos/SpiceLabsHQ/.github/rules/branches/main \
#     --jq '.[]|select(.type=="pull_request").parameters|keys'
#     -> ["allowed_merge_methods","dismiss_stale_reviews_on_push",
#         "require_code_owner_review","require_last_push_approval",
#         "required_approving_review_count","required_review_thread_resolution",
#         "required_reviewers"]  — no dismissal-restriction key
# Rulesets have no equivalent parameter. Whether GitHub nonetheless imposes an
# implicit restriction under rulesets is only answerable on the first live run,
# and the failure mode is benign: a `::warning::`, a human requested, the PR left
# blocked exactly as it is today, and a retry on the next run.
#
# Requires: gh (authenticated as the Pepper App), jq.
#
# Environment:
#   REPO              — owner/repo
#   PR_NUMBER         — PR number
#   PEPPER_BOT_LOGIN  — Pepper's App login, "<app-slug>[bot]"; empty means stand down
#   FLAVOR            — author class; only "dependency" collapses
#   REVIEWERS_TEAM    — team slug to request a review from
#   REPO_OWNER        — org that owns REVIEWERS_TEAM
#   GH_TOKEN          — App installation token
#
# Prints a single `collapse-result=<slug>` line last, which is what the fixture
# test asserts on.
#
# DEV-653: when `GITHUB_OUTPUT` is set it ALSO writes `collapse_fired=true|false`
# as a step output, so the audit record can say whether this step rewrote the
# verdict. See `result()` for why the stdout contract is left untouched.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DECIDE="${HERE}/pepper-bot-outcome-collapse-decide.jq"

REPO="${REPO:-}"
PR_NUMBER="${PR_NUMBER:-}"
PEPPER_BOT_LOGIN="${PEPPER_BOT_LOGIN:-}"
FLAVOR="${FLAVOR:-default}"
REVIEWERS_TEAM="${REVIEWERS_TEAM:-}"
REPO_OWNER="${REPO_OWNER:-}"

# The single exit point. The `collapse-result=<slug>` line on stdout is the
# original contract and is UNCHANGED — the fixture test and any log reader still
# see exactly what they did before.
#
# DEV-653 adds a step output alongside it, guarded on `GITHUB_OUTPUT` being set
# so nothing changes for the fixture test (which runs the script directly) or
# for a consumer pinned to an older tag. `collapse_fired` is true only for a
# CONFIRMED, complete collapse: `dismiss-incomplete` means at least one change
# request is still standing, so the verdict was NOT rewritten and the audit
# record must not claim it was. The write is best-effort for the same reason
# nothing else here exits non-zero — a failed audit hint must not turn a
# completed review red (DEV-504).
result() {
  if [ -n "${GITHUB_OUTPUT:-}" ]; then
    if [ "$1" = "collapsed" ]; then
      echo "collapse_fired=true" >> "${GITHUB_OUTPUT}" 2>/dev/null || true
    else
      echo "collapse_fired=false" >> "${GITHUB_OUTPUT}" 2>/dev/null || true
    fi
  fi
  echo "collapse-result=$1"
  exit 0
}

# Best-effort human escalation, used on the success path and on both failure
# paths. A team that lacks read access to this repo, or a token that cannot
# request teams, must never change the outcome of the collapse.
#
# An UNSET team is loud rather than silent. The escalation is the entire second
# half of the collapsed outcome set — a caller that has disabled it by passing an
# empty `reviewers_team` is choosing a PR that is commented on and then left for
# nobody, and that choice should be visible in the run log.
request_human() {
  if [ -z "${REVIEWERS_TEAM}" ]; then
    echo "::warning::No human was requested on ${REPO}#${PR_NUMBER}: the reusable workflow's \`reviewers_team\` input is empty, so the escalation half of the bot-PR outcome collapse cannot run. Set \`reviewers_team\` on the caller to a team with read access to this repo (DEV-674)."
    return 0
  fi
  if [ -z "${REPO_OWNER}" ]; then
    echo "::warning::No human was requested on ${REPO}#${PR_NUMBER}: \`reviewers_team\` is set to '${REVIEWERS_TEAM}' but the owning org is unknown (DEV-674)."
    return 0
  fi
  gh pr edit "${PR_NUMBER}" --repo "${REPO}" --add-reviewer "${REPO_OWNER}/${REVIEWERS_TEAM}" >/dev/null 2>&1 \
    || echo "::warning::Could not request a review from ${REPO_OWNER}/${REVIEWERS_TEAM} on ${REPO}#${PR_NUMBER} (DEV-674)."
}

if [ ! -f "${DECIDE}" ]; then
  echo "::warning::Outcome-collapse decision program not found at ${DECIDE} — leaving the verdict as filed (DEV-674)."
  result "decide-program-missing"
fi

if [ -z "${REPO}" ] || [ -z "${PR_NUMBER}" ]; then
  echo "::warning::REPO/PR_NUMBER not set — outcome collapse skipped (DEV-674)."
  result "no-pr-context"
fi

# Stream every review across all pages, then slurp into one array. A per-element
# `--jq '.[]'` is the pagination-safe form: an aggregating filter would be applied
# per page and silently drop everything but the last.
REVIEWS="$(gh api --paginate "repos/${REPO}/pulls/${PR_NUMBER}/reviews?per_page=100" --jq '.[]' 2>/dev/null | jq -sc '.')" || REVIEWS=""
if [ -z "${REVIEWS}" ] || ! printf '%s' "${REVIEWS}" | jq -e 'type == "array"' >/dev/null 2>&1; then
  echo "::warning::Could not read reviews for ${REPO}#${PR_NUMBER} — leaving the verdict as filed (DEV-674)."
  result "reviews-unreadable"
fi

DECISION="$(jq -cn \
  --arg bot "${PEPPER_BOT_LOGIN}" \
  --arg flavor "${FLAVOR}" \
  --argjson reviews "${REVIEWS}" \
  -f "${DECIDE}")" || DECISION=""
if [ -z "${DECISION}" ]; then
  echo "::warning::Outcome-collapse decision failed to evaluate — leaving the verdict as filed (DEV-674)."
  result "decision-failed"
fi

ACTION="$(printf '%s' "${DECISION}" | jq -r '.action')"
REASON="$(printf '%s' "${DECISION}" | jq -r '.reason')"

if [ "${ACTION}" != "collapse" ]; then
  echo "No outcome collapse needed for ${REPO}#${PR_NUMBER} (${REASON})."
  result "skipped:${REASON}"
fi

REVIEW_IDS="$(printf '%s' "${DECISION}" | jq -r '.review_ids[]')"
MARKER="$(printf '%s' "${DECISION}" | jq -r '.marker')"
COMMENT_NEEDED="$(printf '%s' "${DECISION}" | jq -r '.comment_needed')"
echo "Collapsing Pepper change request(s) $(printf '%s' "${REVIEW_IDS}" | tr '\n' ' ')on ${REPO}#${PR_NUMBER} (${REASON})."

# STEP 1 — re-file the diagnosis as a COMMENT review, before anything is
# dismissed. A COMMENT is informational: it clears nothing, hides nothing from
# the selector, and cannot make the PR look resolved. If it fails we stop here
# with every change request still standing and still selectable, so the PR reads
# exactly as it did before this step ran and the next run retries the whole
# collapse.
#
# The preamble deliberately does NOT contain the trigger phrase. Review
# submissions do not fire `issue_comment`, so this cannot self-trigger today, but
# the escalation comment downstream carries the same rule and there is no reason
# for the two to disagree.
if [ "${COMMENT_NEEDED}" = "true" ]; then
  PREAMBLE='**Pepper filed this as a comment, not a change request.** This PR was
opened by a dependency bot, which has no way to read a review and no reason to
push the commit that would clear a `CHANGES_REQUESTED`, so that verdict would
deadlock the PR rather than get it fixed (DEV-674). The findings below stand
unchanged and still need a human decision — either fix them and approve, or close
the PR. An approval here is a merge (ADR-0017 arms auto-merge for this author).

---

'

  BODY_FILE="$(mktemp)"
  {
    printf '%s\n\n' "${MARKER}"
    printf '%s' "${PREAMBLE}"
    printf '%s' "${DECISION}" | jq -r '.body'
  } > "${BODY_FILE}"

  POSTED=1
  jq -n --arg body "$(cat "${BODY_FILE}")" '{event: "COMMENT", body: $body}' \
    | gh api "repos/${REPO}/pulls/${PR_NUMBER}/reviews" --method POST --input - >/dev/null 2>&1 \
    || POSTED=0
  rm -f "${BODY_FILE}"

  if [ "${POSTED}" -eq 0 ]; then
    echo "::warning::Could not re-file Pepper's findings as a COMMENT review on ${REPO}#${PR_NUMBER}. Nothing was dismissed and no labels were changed, so the change request still blocks the PR and a later run will retry the collapse. Requesting a human in the meantime (DEV-674)."
    request_human
    result "comment-failed"
  fi
else
  echo "A collapse comment carrying ${MARKER} is already on ${REPO}#${PR_NUMBER} — not re-posting."
fi

# STEP 2 — dismiss every change request, then CONFIRM each by re-reading its
# state. A dismissal we did not confirm is treated as a failure regardless of the
# write's exit code: the read-back is the only thing that distinguishes a
# dismissal from a call that returned 200 and changed nothing.
DISMISS_FAILED=0
for RID in ${REVIEW_IDS}; do
  gh api "repos/${REPO}/pulls/${PR_NUMBER}/reviews/${RID}/dismissals" \
    --method PUT \
    -f event=DISMISS \
    -f message="Dismissed by Pepper: re-filed as a comment. A dependency bot cannot clear a change request, so this verdict would have deadlocked the PR. The findings are unchanged and now await a human (DEV-674)." \
    >/dev/null 2>&1 || true

  STATE="$(gh api "repos/${REPO}/pulls/${PR_NUMBER}/reviews/${RID}" --jq '.state' 2>/dev/null)" || STATE=""
  if [ "${STATE}" != "DISMISSED" ]; then
    DISMISS_FAILED=$((DISMISS_FAILED + 1))
    echo "::warning::Dismissal of review ${RID} on ${REPO}#${PR_NUMBER} was not confirmed (state='${STATE:-unreadable}') (DEV-674)."
  fi
done

# STEP 3 — human escalation, on both outcomes. It adds a reader without claiming
# the block is gone.
request_human

# STEP 4 — labels. The remove side is gated on the label actually being on the
# PR: `gh pr edit --remove-label` errors when the label does not exist in the repo
# at all (cold-start case), and under `set -u` an empty array expansion is a bash
# 3.2 footgun — ARGS always carries the --add-label pair, so the expansion is
# safe.
#
# `pepper-needs-review` goes on either way: a human is needed whether the collapse
# finished or jammed, and on the jammed path this label is the ONLY signal that
# escapes a green required check.
#
# `pepper-changes-requested` comes off ONLY on a complete collapse, because only
# then is it false. `pepper-approved` comes off too if some earlier round left it
# behind: we would not be here unless a change request is newer than every
# approval (the decision program's guard), so an approved label on this PR is
# stale, and a PR carrying both `pepper-approved` and `pepper-needs-review` reads
# as nonsense.
CURRENT="$(gh pr view "${PR_NUMBER}" --repo "${REPO}" --json labels --jq '[.labels[].name] | join(",")' 2>/dev/null)" || CURRENT=""
ARGS=(--add-label "pepper-needs-review")
if [ "${DISMISS_FAILED}" -eq 0 ]; then
  for STALE in pepper-changes-requested pepper-approved; do
    case ",${CURRENT}," in
      *,"${STALE}",*) ARGS+=(--remove-label "${STALE}") ;;
    esac
  done
fi
gh pr edit "${PR_NUMBER}" --repo "${REPO}" "${ARGS[@]}" >/dev/null 2>&1 \
  || echo "::warning::Could not update outcome labels on ${REPO}#${PR_NUMBER} (DEV-674)."

if [ "${DISMISS_FAILED}" -gt 0 ]; then
  # At least one change request is still blocking, so the PR keeps saying so:
  # `pepper-changes-requested` stays on alongside `pepper-needs-review`. The
  # surviving rows are still `CHANGES_REQUESTED`, which is what makes the next run
  # select them again and retry.
  echo "::warning::${DISMISS_FAILED} change request(s) on ${REPO}#${PR_NUMBER} could not be dismissed. The PR is still blocked and keeps its pepper-changes-requested label; a human has been requested and a later run will retry the collapse (DEV-674)."
  result "dismiss-incomplete"
fi

result "collapsed"
