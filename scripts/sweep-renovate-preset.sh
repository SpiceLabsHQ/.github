#!/usr/bin/env bash
# Sweeps org repos onto the shared Renovate preset (DEV-1167, executing DEV-1155).
#
# WHY THIS EXISTS SEPARATELY FROM the old migrate-legacy-v1-pins.sh: that
# script seeded a config only where none exists, had no code path that
# rewrote one, and skipped any repo without a .github/workflows directory. A
# dry run showed it reaching 10 of 23 targets — it could not touch the eleven
# repos whose config exists but extends config:recommended instead of the org
# preset, which is the actual DEV-1150 population. Its own job was also done
# (0 legacy @v1 pins remained), so it was retired outright (DEV-1172) rather
# than widened.
#
# For each target repo this script will:
#   1. Classify it: on-preset (no-op), off-preset (rewrite), or none (seed)
#   2. Rewrite `extends` to name the shared preset, touching nothing else
#   3. Or seed the standard config where the repo has none
#   4. Create a branch, commit, push, open a PR against the default branch
#
# WHAT IT DELIBERATELY DOES NOT DO:
#   - It never removes `enabledManagers` from an existing config. Dropping it
#     silently enables npm on repos whose engines floor is unsettled (DEV-1103),
#     turning a config sweep into an unreviewed dependency-bump wave. Coverage
#     widens only where a repo has no config at all and nothing is watching it.
#   - It never rewrites `packageRules`, even where a rule restates preset
#     policy. It reports those so a human can prune them per repo.
#   - It never edits a `renovate` key nested in package.json, or a json5 config
#     jq cannot parse. Those are reported as MANUAL.
#
# ON FAILURE (DEV-1175): a repo that fails does NOT stop the sweep. Its stage and
# error are recorded, the run continues, and the summary always prints — from an
# EXIT trap, so it survives an abort or Ctrl-C — listing PRs already opened, what
# failed and why, and the exact command to re-run just the failures. Re-running
# is safe: a repo whose PR is already open is skipped rather than retried. The
# exit code is non-zero if anything failed, but only after every other repo has
# been attempted.
#
# Usage:
#   scripts/sweep-renovate-preset.sh                       # dry-run, whole org
#   scripts/sweep-renovate-preset.sh --apply               # actually open PRs
#   scripts/sweep-renovate-preset.sh --apply repo1 repo2   # only the named repos
#
# Requirements: gh (authenticated), git, jq.

set -euo pipefail

ORG="SpiceLabsHQ"
BRANCH="chore/renovate-extend-org-preset"
# The PR title is load-bearing twice over, so do not "tidy" it (DEV-1171):
#
#   1. It MUST be a Conventional Commit. `pr-hygiene / Conventional Commits
#      title` is a blocking required check on every tier, and merges are
#      squash-only with squash_merge_commit_title=PR_TITLE — so this string, not
#      COMMIT_MSG, is both what the check reads and what lands on main. The
#      previous title here was plain prose and would have failed on all 24 PRs.
#
#   2. The type MUST be `chore`. It is what makes these PRs exempt from the
#      issue-reference policy: Pepper's intent_verification exempts a diff that
#      is "unambiguously chore-shaped … repo housekeeping with no changes to
#      application source or tests", which a lone renovate.json is. (The diff is
#      the deciding signal there, not the prefix — but the prefix is the
#      supporting evidence and should agree with it.) `fix` or `feat` would also
#      cut a release in every target repo running release-please; `chore` does
#      not bump a version.
#
# The (DEV-1155) reference is kept even though the chore exemption does not
# require one — it gives traceability back to the sweep and is the fallback if a
# reviewer judges a particular diff not chore-shaped.
COMMIT_MSG="chore(ci): extend the shared Renovate preset (DEV-1155)"
PR_TITLE="chore(ci): extend the shared Renovate preset (DEV-1155)"

command -v gh >/dev/null || { echo "gh not found" >&2; exit 2; }
command -v jq >/dev/null || { echo "jq not found" >&2; exit 2; }
command -v git >/dev/null || { echo "git not found" >&2; exit 2; }

# shellcheck source=scripts/lib/renovate-preset.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/renovate-preset.sh"

DRY_RUN=true
TARGETS=()

for arg in "$@"; do
  case "$arg" in
    --apply) DRY_RUN=false ;;
    -h|--help) sed -n '2,40p' "$0"; exit 0 ;;
    *) TARGETS+=("$arg") ;;
  esac
done

if [ ${#TARGETS[@]} -eq 0 ]; then
  while IFS= read -r name; do
    TARGETS+=("$name")
  done < <(
    gh repo list "$ORG" --limit 1000 --no-archived \
      --json name,isFork --jq '.[] | select(.isFork == false) | .name'
  )
fi

echo "Sweep mode: $([ "$DRY_RUN" = true ] && echo 'DRY RUN' || echo 'APPLY')"
echo "Preset: $RENOVATE_PRESET"
# Show the exact PR title up front. It is the string a blocking required check
# reads and the one that becomes the squash commit, so an operator should see it
# before firing rather than discovering it on 24 red PRs (DEV-1171).
echo "PR title: $PR_TITLE"
echo "Targets (${#TARGETS[@]})"
echo

WORKDIR=$(mktemp -d)

n_noop=0; n_rewrite=0; n_seed=0; n_manual=0; n_failed=0; n_skipped=0
n_seen=0
PRS=()
FAILED_REPOS=()
FAILURE_BLOCKS=()
MANUAL_NOTES=""
TOTAL=0
STAGE="startup"

# The ledger runs from the EXIT trap, not from the end of the script, so it
# prints even on Ctrl-C or an unexpected abort. Losing the list of PRs already
# opened was the worst part of the old failure mode (DEV-1175): it lived only in
# a shell array and reconstructing it meant trawling GitHub by hand.
# shellcheck disable=SC2329  # invoked from the EXIT trap below, not directly.
summarize() {
  echo
  echo "── summary ──"
  echo "  processed         : $n_seen/$TOTAL"
  echo "  already on-preset : $n_noop"
  echo "  would rewrite     : $n_rewrite"
  echo "  would seed        : $n_seed"
  echo "  skipped (PR open) : $n_skipped"
  echo "  needs manual work : $n_manual"
  echo "  FAILED            : $n_failed"

  if [ ${#PRS[@]} -gt 0 ]; then
    echo
    echo "PRs opened (${#PRS[@]}):"
    printf '  %s\n' "${PRS[@]}"
  fi

  if [ -n "$MANUAL_NOTES" ]; then
    echo
    echo "Manual follow-ups (not blocking the sweep, but someone should look):"
    printf '%b' "$MANUAL_NOTES"
  fi

  if [ ${#FAILURE_BLOCKS[@]} -gt 0 ]; then
    echo
    echo "Failures (${#FAILURE_BLOCKS[@]}) — the rest of the run continued:"
    printf '%s\n' "${FAILURE_BLOCKS[@]}"
    echo "Re-run just these once the cause is fixed:"
    echo "  scripts/sweep-renovate-preset.sh$([ "$DRY_RUN" = false ] && printf ' --apply') ${FAILED_REPOS[*]}"
    echo
    echo "Re-running is safe: a repo whose PR is already open is skipped, not retried."
  fi

  if [ "$n_seen" -lt "$TOTAL" ]; then
    echo
    echo "NOTE: stopped after $n_seen of $TOTAL targets — the remainder were never examined."
  fi

  if [ "$DRY_RUN" = true ]; then
    echo
    echo "Dry run — nothing was changed. Re-run with --apply to open PRs."
  fi
}
trap 'summarize; rm -rf "$WORKDIR"' EXIT

pr_body() {
  cat <<BODY
Brings this repo's Renovate config onto the shared org preset
([\`default.json\`](https://github.com/SpiceLabsHQ/.github/blob/main/default.json)),
consumed via \`"extends": ["$RENOVATE_PRESET"]\`.

$1

## Why

The preset is where org dependency policy lives: Pepper-gated auto-merge, a
7-day \`minimumReleaseAge\` supply-chain soak, the \`vulnerabilityAlerts\`
carve-out that lets a vulnerability fix skip that soak, \`rebaseWhen: conflicted\`,
non-major update grouping, and the version parsing for this org's
\`<workflow>-vN\` reusable-workflow tags. A config that does not extend it
inherits none of that, and nothing reports the gap — which is how it went
unnoticed org-wide for six weeks.

Opened by \`scripts/sweep-renovate-preset.sh\` in
[SpiceLabsHQ/.github](https://github.com/SpiceLabsHQ/.github).

Tracking: DEV-1155
BODY
}

# Records a failure and lets the sweep carry on. The stage and the tail of the
# repo's own log are both kept, so the summary says WHERE it broke and WHY
# rather than leaving an unattributed git error in scrollback.
record_failure() {
  local repo="$1" stage="$2" log="$3" block excerpt=""
  [ -s "$log" ] && excerpt="$(tail -6 "$log" | sed 's/^/        /')"
  block="  ${repo} — failed at: ${stage}"
  [ -n "$excerpt" ] && block="${block}
${excerpt}"
  FAILURE_BLOCKS+=("$block")
  FAILED_REPOS+=("$repo")
  n_failed=$((n_failed + 1))
  echo "  FAILED at ${stage} — continuing; details in the summary"
}

# Opens the PR for a planned change. $1 repo, $2 default branch, $3 target path,
# $4 new content, $5 human summary. Returns non-zero on failure with STAGE set.
open_pr() {
  local repo="$1" default_branch="$2" path="$3" content="$4" summary="$5"
  local clone_dir url log
  log="$WORKDIR/${repo}.log"

  clone_dir="$WORKDIR/clone-$repo"

  STAGE="clone"
  gh repo clone "$ORG/$repo" "$clone_dir" -- --depth=1 --quiet >>"$log" 2>&1 || return 1

  STAGE="commit"
  (
    cd "$clone_dir"
    git checkout -q -B "$BRANCH"
    mkdir -p "$(dirname "$path")"
    printf '%s\n' "$content" > "$path"
    git add "$path"
    git commit -q -m "$COMMIT_MSG" -m "$summary"
  ) >>"$log" 2>&1 || return 1

  # Deliberately NOT a force push. If a branch of this name already exists and
  # has diverged, that is something a human should look at — the sweep does not
  # own every branch that happens to share its name. It now surfaces as a clean
  # per-repo failure instead of killing the run.
  STAGE="push"
  ( cd "$clone_dir" && git push -q -u origin "HEAD:$BRANCH" ) >>"$log" 2>&1 || return 1

  STAGE="pr-create"
  url="$(gh pr create --repo "$ORG/$repo" --base "$default_branch" --head "$BRANCH" \
    --title "$PR_TITLE" --body "$(pr_body "$summary")" 2>>"$log")" || return 1

  PRS+=("$url")
  echo "  PR: $url"
  return 0
}

# All of one repo's work. Returns non-zero on failure with STAGE set.
#
# BASH GOTCHA: this is invoked as `if ! run_repo ...`, and testing a function's
# result SUSPENDS `set -e` for its whole body. Nothing in here aborts on its
# own, so every fallible command must carry an explicit `|| return 1`. Adding a
# bare command below and assuming -e will catch it is the way this silently
# stops containing failures.
run_repo() {
  local repo="$1"
  local log="$WORKDIR/${repo}.log"
  local state path content updated managers default_branch existing
  local shadow_first shadow_rest shadow_n dropped_recommended summary

  # Reachability first. renovate_state() treats an unreadable repo the same as
  # one with no config, so a mid-run auth expiry or API outage would otherwise
  # classify every remaining repo as `none` and try to seed all of them. Proving
  # the repo is readable before trusting that verdict turns a silent mass-seed
  # into an honest failure.
  STAGE="reachability"
  default_branch="$(gh api "repos/$ORG/$repo" --jq '.default_branch' 2>>"$log")" || return 1
  [ -n "$default_branch" ] || return 1

  STAGE="classify"
  state="$(renovate_state "$repo")" || return 1

  # Shadowed-config check. Renovate reads the FIRST config in its resolution
  # order and silently ignores any others, so a repo with two of them has a dead
  # file that still reads like live config — edit it and nothing happens, with no
  # error. Claude-Marketplace and Claude-Marketplace-Internal are both in this
  # state today. Surface it; do not quietly act on the winner alone.
  if [ "$state" != "none" ]; then
    shadow_first=""; shadow_rest=""; shadow_n=0
    while IFS= read -r cfg; do
      [ -z "$cfg" ] && continue
      shadow_n=$((shadow_n + 1))
      if [ -z "$shadow_first" ]; then shadow_first="$cfg"; else shadow_rest="${shadow_rest} ${cfg}"; fi
    done < <(renovate_config_all_paths "$repo")
    if [ "$shadow_n" -gt 1 ]; then
      echo "  WARNING: $shadow_n config files present — Renovate reads $shadow_first and IGNORES:$shadow_rest"
      MANUAL_NOTES="${MANUAL_NOTES}- **${repo}** — shadowed config(s):${shadow_rest} (Renovate reads \`${shadow_first}\`; delete the dead one)\n"
    fi
  fi

  case "$state" in
    on-preset)
      echo "  ok: already extends the preset"
      n_noop=$((n_noop + 1))
      return 0
      ;;

    none)
      echo "  seed: .github/renovate.json (no config today — nothing watches this repo)"
      n_seed=$((n_seed + 1))
      path=".github/renovate.json"
      content="$(renovate_seed_config)"
      summary="Seeds a Renovate config; this repo had none, so no dependency updates were ever proposed. No \`enabledManagers\` is set, so Renovate watches every manifest it detects."
      ;;

    off-preset)
      STAGE="locate-config"
      path="$(renovate_config_path "$repo" || true)"
      if [ -z "$path" ]; then
        echo "  MANUAL: config lives in package.json's \`renovate\` key — not rewritten here"
        MANUAL_NOTES="${MANUAL_NOTES}- **${repo}** — \`renovate\` key nested in package.json\n"
        n_manual=$((n_manual + 1))
        return 0
      fi

      STAGE="read-config"
      content="$(renovate_fetch "$repo" "$path")"
      if ! printf '%s' "$content" | jq empty 2>/dev/null; then
        echo "  MANUAL: $path is not plain JSON (json5/comments) — not rewritten here"
        MANUAL_NOTES="${MANUAL_NOTES}- **${repo}** — \`${path}\` is json5/commented\n"
        n_manual=$((n_manual + 1))
        return 0
      fi

      STAGE="rewrite"
      updated="$(apply_preset_to_config "$content")" || return 1
      managers="$(printf '%s' "$content" | jq -r 'if has("enabledManagers") then (.enabledManagers | join(", ")) else "" end')" || return 1
      dropped_recommended=false
      printf '%s' "$content" | jq -e '(.extends // []) | index("config:recommended")' >/dev/null 2>&1 \
        && dropped_recommended=true

      echo "  rewrite: $path — extends now names the preset"
      [ "$dropped_recommended" = true ] && echo "           drops redundant config:recommended (the preset extends it)"
      if [ -n "$managers" ]; then
        echo "           PRESERVES enabledManagers: [$managers]"
      fi
      if printf '%s' "$content" | jq -e '(.packageRules // []) | map(select((.matchPackageNames // []) | any(test("SpiceLabsHQ/\\.github")))) | length > 0' >/dev/null 2>&1; then
        echo "           note: a packageRule restates the preset's -vN versioning; left in place for a human to prune"
      fi
      n_rewrite=$((n_rewrite + 1))

      summary="Adds the preset to \`extends\`."
      [ "$dropped_recommended" = true ] && summary="${summary} Drops \`config:recommended\`, which the preset already extends."
      if [ -n "$managers" ]; then
        summary="${summary} **\`enabledManagers\` is preserved as \`[$managers]\`** — widening it is a separate, deliberate decision (DEV-1103), not a side effect of this sweep."
      fi
      content="$updated"
      ;;
  esac

  [ "$DRY_RUN" = true ] && return 0

  # Idempotent re-runs. An open PR on our branch means this repo was already
  # handled by an earlier run; skipping is what makes a re-run after a partial
  # sweep safe, instead of erroring out in `gh pr create`.
  STAGE="check-existing-pr"
  existing="$(gh pr list --repo "$ORG/$repo" --head "$BRANCH" --state open \
    --json url --jq '.[0].url // empty' 2>>"$log")" || return 1
  if [ -n "$existing" ]; then
    echo "  skip: PR already open — $existing"
    PRS+=("$existing")
    n_skipped=$((n_skipped + 1))
    return 0
  fi

  open_pr "$repo" "$default_branch" "$path" "$content" "$summary" || return 1
  return 0
}

TOTAL=${#TARGETS[@]}
for repo in "${TARGETS[@]}"; do
  n_seen=$((n_seen + 1))
  echo "── [$n_seen/$TOTAL] $ORG/$repo ──"
  STAGE="unknown"
  if ! run_repo "$repo"; then
    record_failure "$repo" "$STAGE" "$WORKDIR/${repo}.log"
  fi
done

[ "$n_failed" -eq 0 ] || exit 1
exit 0
