#!/usr/bin/env bash
# Bot-allowlist drift check (DEV-679).
#
# The bot inventory is duplicated across three workflows, in three shapes:
#
#   .github/workflows/pepper-pr-review.yml   `allowed_bots` input DEFAULT,
#                                            comma string, NO `[bot]` suffix
#                                            -> INITIATOR allowlist (DEV-504)
#   .github/workflows/floor-pepper.yml       `allowed_bots` caller override,
#                                            comma string, NO `[bot]` suffix
#                                            -> INITIATOR allowlist, widened
#                                               for the DEV-667 sweep
#   .github/workflows/floor-automerge.yml    JSON array inside the job-level
#                                            `if:`, WITH `[bot]` suffix
#                                            -> AUTHOR allowlist (ADR-0017)
#
# GitHub Actions has no cross-workflow literal sharing, so DEV-679 deliberately
# keeps the duplication and asserts agreement instead of preventing divergence.
# This script is that assertion. It is hermetic — three files in this repo, no
# network, no token — which is why it runs as a repo-local PR check
# (repo-checks.yml) rather than in the scheduled, org-scoped, non-blocking
# org-ci-audit.
#
# INITIATOR AND AUTHOR ARE NOT THE SAME LIST and this check must never collapse
# them. What it asserts:
#
#   1. DEPENDENCY-BOT INVENTORY AGREEMENT. The author allowlist in
#      floor-automerge and the initiator DEFAULT in pepper-pr-review must
#      enumerate the same bots (modulo the `[bot]` suffix). A bot in one but not
#      the other is real drift: present only in floor-automerge it auto-arms
#      with no review path; present only in pepper-pr-review it is reviewed and
#      then strands unmerged.
#
#   2. THE SWEEP EXTENSION IS EXACT. floor-pepper's initiator list must be the
#      inventory PLUS exactly the documented sweep initiators below — no more,
#      no less. `pepper-pr-review` is there because the DEV-667 sweep reopens
#      stranded PRs as Pepper's own App and would otherwise be gated out
#      (silently: a skipped required check still passes). Dropping it disables
#      the sweep with no signal; adding anything else widens who may trigger a
#      review with no record of why.
#
#   3. THE SWEEP EXTENSION STAYS OUT OF THE AUTHOR LIST. `pepper-pr-review` is
#      an initiator, never an author. In the author allowlist it would arm
#      auto-merge for Pepper's own App.
#
#   4. SHAPES HOLD. Initiator entries carry no `[bot]` suffix (pepper-pr-review
#      documents them that way and the gate appends it); author entries carry
#      it (they are compared against `pull_request.user.login`). A suffix on the
#      wrong side of the line matches nothing and fails open.
#
#   5. NO GLOBS. Every GitHub App login ends in `[bot]`, so a `*[bot]`-style
#      pattern silently arms any future app — the ADR-0017 argument recorded at
#      floor-automerge.yml:24-42. The lists are enumerations, always.
#
# Requires: yq (mikefarah v4), jq. Both are present on GitHub-hosted ubuntu
# runners; scripts/org-repo-settings-reconcile.sh already relies on yq there.
#
# Usage: scripts/check-bot-allowlists.sh [--workflows DIR]
#        (DIR defaults to this repo's .github/workflows; the flag exists so the
#        fixture test can point the SAME program at synthetic trees.)

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKFLOWS="${HERE}/../.github/workflows"

while [ $# -gt 0 ]; do
  case "$1" in
    --workflows) WORKFLOWS="${2:?--workflows needs a value}"; shift 2 ;;
    -h|--help) sed -n '2,60p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

command -v yq >/dev/null || { echo "yq (mikefarah v4) not found" >&2; exit 2; }
command -v jq >/dev/null || { echo "jq not found" >&2; exit 2; }

PEPPER="${WORKFLOWS}/pepper-pr-review.yml"
FLOOR_PEPPER="${WORKFLOWS}/floor-pepper.yml"
AUTOMERGE="${WORKFLOWS}/floor-automerge.yml"

for f in "$PEPPER" "$FLOOR_PEPPER" "$AUTOMERGE"; do
  [ -f "$f" ] || { echo "missing workflow: $f" >&2; exit 2; }
done

# The ONLY initiators floor-pepper may add on top of the dependency-bot
# inventory. Adding an entry here is the deliberate act of recording a new
# operational initiator; it is not a place to park a dependency bot.
SWEEP_ONLY_INITIATORS='["pepper-pr-review"]'

# Findings accumulate as newline-delimited text rather than an array: bash 3.2
# (the macOS default, where this is also run locally) has no `mapfile` and
# treats an empty array as unset under `set -u`.
findings=""
note() { findings="${findings}  - ${1}
"; }

# --- extraction -------------------------------------------------------------
# Every extractor hard-fails on an empty result. A moved key would otherwise
# turn this check into a vacuous pass — the exact failure mode it exists to
# prevent.

# Comma string -> sorted unique JSON array of trimmed, non-empty entries.
comma_to_set() {
  tr ',' '\n' \
    | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' \
    | jq -cRn '[inputs | select(length > 0)] | unique'
}

pepper_default="$(yq -r '.on.workflow_call.inputs.allowed_bots.default // ""' "$PEPPER")"
[ -n "$pepper_default" ] || {
  echo "could not read .on.workflow_call.inputs.allowed_bots.default from ${PEPPER}" >&2; exit 2; }

floor_override="$(yq -r '[.jobs.[].with.allowed_bots | select(. != null)] | .[0] // ""' "$FLOOR_PEPPER")"
[ -n "$floor_override" ] || {
  echo "could not read a job's .with.allowed_bots from ${FLOOR_PEPPER}" >&2; exit 2; }

automerge_if="$(yq -r '[.jobs.[].if | select(. != null)] | join(" ")' "$AUTOMERGE")"
[ -n "$automerge_if" ] || {
  echo "could not read a job-level if: from ${AUTOMERGE}" >&2; exit 2; }

# The author allowlist is a JSON array literal inside `fromJSON('[...]')`.
# Require exactly one occurrence: zero means the allowlist moved, more than one
# means "the author allowlist" is ambiguous and this check cannot speak to it.
from_json_hits="$(grep -o "fromJSON('\[.*\]')" <<<"$automerge_if" || true)"
hit_count="$(printf '%s' "$from_json_hits" | grep -c . || true)"
if [ "$hit_count" -ne 1 ]; then
  echo "expected exactly one fromJSON('[...]') literal in ${AUTOMERGE} job if:, found ${hit_count}" >&2
  exit 2
fi
author_raw="$(sed "s/^fromJSON('//; s/')$//" <<<"$from_json_hits")"
jq -e 'type == "array"' >/dev/null <<<"$author_raw" || {
  echo "author allowlist in ${AUTOMERGE} is not a JSON array: ${author_raw}" >&2; exit 2; }

initiator_base="$(comma_to_set <<<"$pepper_default")"
initiator_floor="$(comma_to_set <<<"$floor_override")"
author_logins="$(jq -c 'map(gsub("^\\s+|\\s+$"; "")) | unique' <<<"$author_raw")"

# --- 5. no globs ------------------------------------------------------------
globs="$(jq -c --argjson a "$initiator_base" --argjson b "$initiator_floor" --argjson c "$author_logins" \
  -n '($a + $b + $c) | map(select(test("[*?]"))) | unique')"
[ "$globs" = "[]" ] || note "glob-shaped entries are never allowed (ADR-0017: every App login ends in [bot], so a glob arms every future app): ${globs}"

# --- 4. shapes --------------------------------------------------------------
bad_initiator_shape="$(jq -c --argjson a "$initiator_base" --argjson b "$initiator_floor" \
  -n '($a + $b) | map(select(endswith("[bot]"))) | unique')"
[ "$bad_initiator_shape" = "[]" ] || note "initiator entries must NOT carry the [bot] suffix (pepper-pr-review's gate appends it): ${bad_initiator_shape}"

bad_author_shape="$(jq -c 'map(select(endswith("[bot]") | not))' <<<"$author_logins")"
[ "$bad_author_shape" = "[]" ] || note "author entries MUST carry the [bot] suffix (they are compared against pull_request.user.login): ${bad_author_shape}"

author_base="$(jq -c 'map(sub("\\[bot\\]$"; "")) | unique' <<<"$author_logins")"

# --- 1. dependency-bot inventory agreement ----------------------------------
only_author="$(jq -c -n --argjson a "$author_base" --argjson i "$initiator_base" '$a - $i')"
only_initiator="$(jq -c -n --argjson a "$author_base" --argjson i "$initiator_base" '$i - $a')"
[ "$only_author" = "[]" ] || note "in floor-automerge's AUTHOR allowlist but not pepper-pr-review's allowed_bots default — these PRs auto-arm with no review path: ${only_author}"
[ "$only_initiator" = "[]" ] || note "in pepper-pr-review's allowed_bots default but not floor-automerge's AUTHOR allowlist — these PRs are reviewed and then strand unmerged: ${only_initiator}"

# --- 2. the sweep extension is exact ----------------------------------------
expected_floor="$(jq -c -n --argjson i "$initiator_base" --argjson s "$SWEEP_ONLY_INITIATORS" '($i + $s) | unique')"
missing_floor="$(jq -c -n --argjson e "$expected_floor" --argjson f "$initiator_floor" '$e - $f')"
extra_floor="$(jq -c -n --argjson e "$expected_floor" --argjson f "$initiator_floor" '$f - $e')"
[ "$missing_floor" = "[]" ] || note "missing from floor-pepper's initiator allowlist — dropping a sweep initiator disables the DEV-667 sweep silently (a skipped required check still passes): ${missing_floor}"
[ "$extra_floor" = "[]" ] || note "undocumented entries in floor-pepper's initiator allowlist — add a dependency bot to pepper-pr-review's default, or record a new operational initiator in SWEEP_ONLY_INITIATORS in this script: ${extra_floor}"

# --- 3. the sweep extension stays out of the author list --------------------
leaked="$(jq -c -n --argjson a "$author_base" --argjson s "$SWEEP_ONLY_INITIATORS" '$a - ($a - $s)')"
[ "$leaked" = "[]" ] || note "initiator-only entries must never appear in floor-automerge's AUTHOR allowlist — that would arm auto-merge for Pepper's own App: ${leaked}"

# --- report -----------------------------------------------------------------
if [ -z "$findings" ]; then
  echo "bot allowlists agree:"
  echo "  dependency-bot inventory (pepper-pr-review default == floor-automerge authors): ${initiator_base}"
  echo "  floor-pepper initiators (inventory + sweep):                                    ${initiator_floor}"
  exit 0
fi

echo "bot allowlist drift (DEV-679):" >&2
printf '%s' "$findings" >&2
echo >&2
echo "Read:  pepper-pr-review.yml (initiator default) / floor-pepper.yml (initiator override) / floor-automerge.yml (author allowlist)" >&2
exit 1
