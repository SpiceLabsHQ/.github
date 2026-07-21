#!/usr/bin/env bash
# Pepper stranded-PR sweep (DEV-667).
#
# The GUARANTEE half of the floor's draft handling. Nothing in the injected floor
# can see `ready_for_review` — GitHub delivers ruleset-injected workflows on the
# DEFAULT pull_request activity types only (DEV-576) — so a PR opened as a draft
# and later marked ready gets no review until something re-fires an event the
# floor CAN see. Same class of gap: a new PR that reuses a branch already
# reviewed on the same SHA (DEV-465).
#
# This sweep closes that gap centrally, with no per-repo config: find open,
# non-draft PRs org-wide that lack a CURRENT Pepper verdict, and reopen them
# (close -> reopen) to re-fire the injected floor review against the same head
# SHA. That is the proven manual workaround, automated. No SHA change, no forced
# push, no rewritten history.
#
# IDENTITY (and why it matters): the sweep acts as its OWN App,
# `spice-pepper-sweep[bot]` — not Pepper's. ADR-0007 requires one App per
# capability and forbids both borrowing another App's credentials and widening an
# existing App to serve a new use; this sweep needs a permission Pepper's review
# App does not have (`Organization: Custom properties = read`), so a dedicated App
# is the only compliant shape. The ADR names reusing `pepper-pr-review` as an
# explicitly rejected alternative.
#
# The reopen makes the sweep's App the TRIGGERING ACTOR of the resulting
# pull_request event, and the reusable's bot-initiator gate (DEV-504) skips any
# bot initiator outside `allowed_bots`. So `.github/workflows/floor-pepper.yml`
# carries `spice-pepper-sweep` in its `allowed_bots`. That coupling is enforced at
# runtime (see the preflight below) rather than trusted, because getting it wrong
# fails SILENTLY: the sweep would reopen PRs and Pepper would skip every one.
#
# GUARDRAILS
#   - Per-run cap (--max, default 5). A mass-stranding event must not fire a
#     burst of Bedrock-billed reviews; the next run mops up the remainder.
#   - No re-nudge (backoff). A PR already nudged with no review since is left
#     alone, so a non-responding floor can never become a reopen loop.
#   - Floor exclusions inherited: drafts, docs-tier repos, this `.github` repo,
#     and rosemary-releaser release PRs — never fight an intentional skip.
#
# Requires: gh (authenticated with an ORG-SCOPED token carrying repo read, pull
# requests write, and org custom-property read), jq. Set GH_TOKEN.
#
# Usage: scripts/pepper-stranded-sweep.sh [--org ORG] [--max N] [--dry-run]

set -euo pipefail

ORG="SpiceLabsHQ"
MAX=5
DRY_RUN=false

# The two identities this sweep reasons about. They are DIFFERENT Apps (ADR-0007:
# one App per capability, never borrow another's credentials).
#   REVIEW_BOT — posts the reviews; defines "has a current verdict".
#   SWEEP_BOT  — reopens stranded PRs (this script's own identity); defines
#                "did we already nudge".
# SWEEP_BOT is injected by the workflow from the token it actually minted, so the
# backoff can never key off a login we are not really acting as.
REVIEW_BOT_LOGIN="${PEPPER_REVIEW_BOT_LOGIN:-pepper-pr-review[bot]}"
SWEEP_BOT_LOGIN="${PEPPER_SWEEP_BOT_LOGIN:-spice-pepper-sweep[bot]}"

# Authors the floor never reviews, mirrored from floor-pepper.yml's job-level
# `if:`. Keep in sync with that caller — a divergence here means the sweep
# reopens a PR the floor will then skip, which is a pointless nudge, not a
# review.
EXCLUDED_AUTHORS='["rosemary-releaser[bot]"]'

# Repos the floor never reviews. `.github` self-skips in floor-pepper.yml (it
# reviews its own PRs via the committed pepper-self-review.yml caller, which
# DOES see ready_for_review and so is never stranded).
EXCLUDED_REPOS='[".github"]'

while [ $# -gt 0 ]; do
  case "$1" in
    --org)     ORG="${2:?--org needs a value}"; shift 2 ;;
    --max)     MAX="${2:?--max needs a value}"; shift 2 ;;
    --dry-run) DRY_RUN=true; shift ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DECIDE="${HERE}/pepper-stranded-sweep-decide.jq"

command -v gh >/dev/null || { echo "gh not found" >&2; exit 2; }
command -v jq >/dev/null || { echo "jq not found" >&2; exit 2; }
[ -f "$DECIDE" ] || { echo "decision program not found: $DECIDE" >&2; exit 2; }
case "$MAX" in ''|*[!0-9]*) echo "--max must be a non-negative integer" >&2; exit 2 ;; esac

# --- 0. Preflight: our identity must be on the floor's allow-list -----------
# The sweep's whole effect depends on floor-pepper.yml listing this App in
# `allowed_bots`: without it the bot-initiator gate (DEV-504) skips every review
# our reopens trigger. That failure is invisible — PRs get closed and reopened,
# no review appears, and no check goes red, because a skipped required check
# still passes. Two files having to agree about one string is exactly the kind of
# coupling that rots, so assert it here instead of trusting a comment.
FLOOR_CALLER="${HERE}/../.github/workflows/floor-pepper.yml"
sweep_slug="${SWEEP_BOT_LOGIN%\[bot\]}"
if [ -f "$FLOOR_CALLER" ]; then
  if ! grep -E '^[[:space:]]*allowed_bots:' "$FLOOR_CALLER" | grep -q "\b${sweep_slug}\b"; then
    echo "::error::${sweep_slug} is not in allowed_bots in ${FLOOR_CALLER##*/} — every review this sweep triggers would be silently skipped by the DEV-504 bot-initiator gate. Refusing to nudge." >&2
    exit 1
  fi
else
  echo "::warning::Could not find ${FLOOR_CALLER} to verify ${sweep_slug} is on the floor's allowed_bots list."
fi

# --- 1. In-scope repos ------------------------------------------------------
# Code-tier only: the floor's Pepper review is injected into untagged repos, so a
# repo tagged `ci-exception=docs` has no floor review to be stranded without.
# Fail-safe matches the ruleset — untagged means code-tier means in scope.
#
# FAIL CLOSED, deliberately. Every other API failure in this script degrades to
# "skip and retry next run", but not this one: an unreadable property list looks
# identical to "no repo is docs-tier", which would put every docs repo in scope
# and reopen PRs there that no floor review will ever answer — a nudge per docs
# PR, org-wide, on the first run. So a failed read aborts the sweep instead.
# The usual cause is the App missing `Organization: Custom properties = read`;
# see the workflow header for the grant.
if ! props_json="$(gh api "orgs/${ORG}/properties/values?per_page=100" --paginate \
    --jq '[.[] | {name: .repository_name, props: [.properties[]? | select(.property_name=="ci-exception") | .value]}]' \
    | jq -s 'add // []')"; then
  echo "::error::Could not read org custom properties for ${ORG} — aborting the sweep rather than treating every docs-tier repo as in scope. Grant the App 'Organization: Custom properties = read'." >&2
  exit 1
fi
docs_repos="$(jq -r '.[] | select(.props | index("docs")) | .name' <<<"$props_json")"

repos="$(gh api "orgs/${ORG}/repos?per_page=100&type=all" --paginate \
  --jq '.[] | select(.archived==false and .disabled==false) | .name')"

in_scope=""
while IFS= read -r repo; do
  [ -z "$repo" ] && continue
  if jq -e --arg r "$repo" --argjson x "$EXCLUDED_REPOS" -n '$x | index($r) != null' >/dev/null; then
    continue
  fi
  if printf '%s\n' "$docs_repos" | grep -Fxq "$repo"; then
    continue
  fi
  in_scope="${in_scope}${repo}"$'\n'
done <<< "$repos"

# --- 2. Candidate open PRs --------------------------------------------------
# One list call per repo rather than a single `gh search prs`: the search index
# lags behind reality by minutes, and a sweep that reads stale state either
# misses a stranded PR or nudges an already-reviewed one. The PR list endpoint is
# authoritative and hands back draft, author, and head SHA in the same response.
#
# Drafts are filtered here, in the query, because "open and non-draft" IS the
# candidate-set definition — not a decision about a candidate. Fetching reviews
# and a timeline for every draft in the org just to discard them would double the
# sweep's API cost for no signal. Author exclusions are deliberately NOT filtered
# here: the decision program owns every per-PR rule, so there is exactly one place
# that can be wrong about them.
candidates=""
while IFS= read -r repo; do
  [ -z "$repo" ] && continue
  prs="$(gh api "repos/${ORG}/${repo}/pulls?state=open&per_page=100" --paginate \
    --jq '.[] | select(.draft == false) | [.number, .user.login, .head.sha, .updated_at] | @tsv' \
    2>/dev/null || true)"
  while IFS=$'\t' read -r num author sha updated; do
    [ -z "${num:-}" ] && continue
    candidates="${candidates}${updated}"$'\t'"${repo}"$'\t'"${num}"$'\t'"${sha}"$'\t'"${author}"$'\n'
  done <<< "$prs"
done <<< "$in_scope"

# Oldest-updated first. With a per-run cap, an arbitrary order lets a busy repo's
# churn starve a PR that has been stranded for days; stale-first cannot.
candidates="$(printf '%s' "$candidates" | grep -v '^[[:space:]]*$' | sort || true)"

# --- 3. Decide and nudge ----------------------------------------------------
nudged=0
stranded=0
failed=0
summary=""

while IFS=$'\t' read -r _updated repo num sha author; do
  [ -z "${repo:-}" ] && continue

  # Both fetches are fail-open-to-skip: on an API error we treat the PR as
  # undecidable and leave it for the next run. A wrongly-skipped PR costs one
  # more sweep interval; a wrongly-nudged one spends a Bedrock review and, worse,
  # could reopen a PR whose review state we misread.
  reviews="$(gh api --paginate "repos/${ORG}/${repo}/pulls/${num}/reviews?per_page=100" \
    --jq '[.[] | {commit_id, submitted_at, user: {login: .user.login}}]' 2>/dev/null | jq -s 'add // []')" || reviews=""
  timeline="$(gh api --paginate "repos/${ORG}/${repo}/issues/${num}/timeline?per_page=100" \
    --jq '[.[] | {event, created_at, actor: {login: (.actor.login // "")}}]' 2>/dev/null | jq -s 'add // []')" || timeline=""
  if [ -z "$reviews" ] || [ -z "$timeline" ]; then
    echo "::warning::${repo}#${num}: could not read review/timeline state — skipping this run."
    continue
  fi

  decision="$(jq -n \
    --arg review_bot "$REVIEW_BOT_LOGIN" \
    --arg sweep_bot "$SWEEP_BOT_LOGIN" \
    --argjson excluded_authors "$EXCLUDED_AUTHORS" \
    --argjson pr "$(jq -n --arg sha "$sha" --arg author "$author" \
        '{draft: false, user: {login: $author}, head: {sha: $sha}}')" \
    --argjson reviews "$reviews" \
    --argjson timeline "$timeline" \
    -f "$DECIDE")"
  action="$(jq -r '.action' <<<"$decision")"
  reason="$(jq -r '.reason' <<<"$decision")"

  if [ "$action" != "nudge" ]; then
    echo "skip  ${repo}#${num} (${reason})"
    continue
  fi

  stranded=$((stranded + 1))
  if [ "$nudged" -ge "$MAX" ]; then
    echo "defer ${repo}#${num} (per-run cap of ${MAX} reached; next run picks it up)"
    continue
  fi

  if [ "$DRY_RUN" = true ]; then
    echo "DRY   ${repo}#${num} would be nudged (head ${sha})"
    nudged=$((nudged + 1))
    summary="${summary}- (dry-run) ${ORG}/${repo}#${num}"$'\n'
    continue
  fi

  # Close then reopen. The window between the two is the only real hazard here:
  # a PR left closed is worse than a PR left unreviewed, so the reopen retries
  # and a terminal failure is loud (non-zero exit) rather than a quiet log line.
  if ! gh pr close "$num" --repo "${ORG}/${repo}" >/dev/null 2>&1; then
    echo "::warning::${repo}#${num}: close failed — not nudged."
    continue
  fi
  reopened=false
  for attempt in 1 2 3; do
    if gh pr reopen "$num" --repo "${ORG}/${repo}" >/dev/null 2>&1; then
      reopened=true
      break
    fi
    echo "::warning::${repo}#${num}: reopen attempt ${attempt} failed; retrying."
    sleep $((attempt * 5))
  done
  if [ "$reopened" != true ]; then
    echo "::error::${repo}#${num}: LEFT CLOSED — reopen failed after 3 attempts. Reopen it manually."
    failed=$((failed + 1))
    continue
  fi

  nudged=$((nudged + 1))
  echo "nudge ${repo}#${num} (head ${sha})"
  summary="${summary}- ${ORG}/${repo}#${num} (head \`${sha:0:7}\`)"$'\n'
done <<< "$candidates"

# --- 4. Report --------------------------------------------------------------
echo
echo "Stranded PRs found: ${stranded}; nudged this run: ${nudged} (cap ${MAX}); failed: ${failed}."

if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  {
    echo "### Pepper stranded-PR sweep"
    echo
    echo "Stranded: **${stranded}** · Nudged: **${nudged}** (cap ${MAX}) · Failed: **${failed}**"
    if [ -n "$summary" ]; then
      echo
      printf '%s' "$summary"
    fi
    if [ "$stranded" -gt "$nudged" ]; then
      echo
      echo "_$((stranded - nudged)) deferred to the next run by the per-run cap._"
    fi
  } >> "${GITHUB_STEP_SUMMARY}"
fi

[ "$failed" -eq 0 ] || exit 1
