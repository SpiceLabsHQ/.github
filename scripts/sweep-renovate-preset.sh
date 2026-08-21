#!/usr/bin/env bash
# Sweeps org repos onto the shared Renovate preset (DEV-1167, executing DEV-1155).
#
# WHY THIS EXISTS SEPARATELY FROM migrate-legacy-v1-pins.sh: that script seeds a
# config only where none exists, has no code path that rewrites one, and skips
# any repo without a .github/workflows directory. A dry run showed it reaching
# 10 of 23 targets — it cannot touch the eleven repos whose config exists but
# extends config:recommended instead of the org preset, which is the actual
# DEV-1150 population. Its own job is also done (0 legacy @v1 pins remain), so
# widening it would extend a script whose purpose has expired.
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
# Usage:
#   scripts/sweep-renovate-preset.sh                       # dry-run, whole org
#   scripts/sweep-renovate-preset.sh --apply               # actually open PRs
#   scripts/sweep-renovate-preset.sh --apply repo1 repo2   # only the named repos
#
# Requirements: gh (authenticated), git, jq.

set -euo pipefail

ORG="SpiceLabsHQ"
BRANCH="chore/renovate-extend-org-preset"
COMMIT_MSG="chore(ci): extend the shared Renovate preset [DEV-1155]"
PR_TITLE="Extend the shared Renovate preset [DEV-1155]"

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
echo "Targets (${#TARGETS[@]})"
echo

WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR"' EXIT

n_noop=0; n_rewrite=0; n_seed=0; n_manual=0
PRS=()
MANUAL_NOTES=""

# Opens the PR for a planned change. $1 repo, $2 target path, $3 new content,
# $4 human summary of what changed (goes in the PR body).
open_pr() {
  local repo="$1" path="$2" content="$3" summary="$4" clone_dir default_branch url

  default_branch="$(gh api "repos/$ORG/$repo" --jq '.default_branch')"
  clone_dir="$WORKDIR/$repo"
  gh repo clone "$ORG/$repo" "$clone_dir" -- --depth=1 --quiet
  (
    cd "$clone_dir"
    git checkout -q -b "$BRANCH"
    mkdir -p "$(dirname "$path")"
    printf '%s\n' "$content" > "$path"
    git add "$path"
    git commit -q -m "$COMMIT_MSG" -m "$summary"
    git push -q -u origin HEAD
  )
  url="$(gh pr create --repo "$ORG/$repo" --base "$default_branch" --head "$BRANCH" \
    --title "$PR_TITLE" --body "$(pr_body "$summary")")"
  PRS+=("$url")
  echo "  PR: $url"
}

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

for repo in "${TARGETS[@]}"; do
  echo "── $ORG/$repo ──"
  state="$(renovate_state "$repo")"

  # Shadowed-config check. Renovate reads the FIRST config in its resolution
  # order and silently ignores any others, so a repo with two of them has a
  # dead file that still reads like live config — edit it and nothing happens,
  # with no error. Claude-Marketplace and Claude-Marketplace-Internal are both
  # in this state today. Surface it; do not quietly act on the winner alone.
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
      ;;

    none)
      echo "  seed: .github/renovate.json (no config today — nothing watches this repo)"
      n_seed=$((n_seed + 1))
      if [ "$DRY_RUN" = false ]; then
        open_pr "$repo" ".github/renovate.json" "$(renovate_seed_config)" \
          "Seeds a Renovate config; this repo had none, so no dependency updates were ever proposed. No \`enabledManagers\` is set, so Renovate watches every manifest it detects."
      fi
      ;;

    off-preset)
      path="$(renovate_config_path "$repo" || true)"
      if [ -z "$path" ]; then
        echo "  MANUAL: config lives in package.json's \`renovate\` key — not rewritten here"
        MANUAL_NOTES="${MANUAL_NOTES}- **${repo}** — \`renovate\` key nested in package.json\n"
        n_manual=$((n_manual + 1))
        continue
      fi

      content="$(renovate_fetch "$repo" "$path")"
      if ! printf '%s' "$content" | jq empty 2>/dev/null; then
        echo "  MANUAL: $path is not plain JSON (json5/comments) — not rewritten here"
        MANUAL_NOTES="${MANUAL_NOTES}- **${repo}** — \`${path}\` is json5/commented\n"
        n_manual=$((n_manual + 1))
        continue
      fi

      updated="$(apply_preset_to_config "$content")"
      managers="$(printf '%s' "$content" | jq -r 'if has("enabledManagers") then (.enabledManagers | join(", ")) else "" end')"
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

      if [ "$DRY_RUN" = false ]; then
        summary="Adds the preset to \`extends\`."
        [ "$dropped_recommended" = true ] && summary="${summary} Drops \`config:recommended\`, which the preset already extends."
        if [ -n "$managers" ]; then
          summary="${summary} **\`enabledManagers\` is preserved as \`[$managers]\`** — widening it is a separate, deliberate decision (DEV-1103), not a side effect of this sweep."
        fi
        open_pr "$repo" "$path" "$updated" "$summary"
      fi
      ;;
  esac
done

echo
echo "── summary ──"
echo "  already on-preset : $n_noop"
echo "  would rewrite     : $n_rewrite"
echo "  would seed        : $n_seed"
echo "  needs manual work : $n_manual"
if [ -n "$MANUAL_NOTES" ]; then
  echo
  echo "Manual follow-ups (not blocking the sweep, but someone should look):"
  printf '%b' "$MANUAL_NOTES"
fi
if [ "$DRY_RUN" = true ]; then
  echo
  echo "Dry run — nothing was changed. Re-run with --apply to open PRs."
elif [ ${#PRS[@]} -gt 0 ]; then
  echo
  echo "Opened ${#PRS[@]} PRs:"
  printf '  %s\n' "${PRS[@]}"
fi
