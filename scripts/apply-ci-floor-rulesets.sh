#!/usr/bin/env bash
# Apply (create or update) the org CI floor rulesets from rulesets/*.json (DEV-499).
#
# Idempotent: upserts by ruleset name (PUT if one already exists, else POST).
# The canonical JSON files carry enforcement:"active"; pass --evaluate to apply
# them in non-blocking dry-run mode first (supported on the Team plan), inspect
# GitHub's rule-insights on a real PR, then re-run without the flag to enforce.
#
# Requires: gh (authenticated as an ORG ADMIN), jq. The referenced floor-*.yml
# workflows must already exist on this repo's main branch — GitHub validates the
# workflow ref at create time.
#
# Usage:
#   scripts/apply-ci-floor-rulesets.sh [--org SpiceLabsHQ] [--evaluate] [--active] \
#       [rulesets/spice-ci-floor-docs.json ...]   # default: all rulesets/*.json
#
# Safety: never touches spice-branch-protection or any ruleset not named in the
# JSON files it applies.

set -euo pipefail

ORG="SpiceLabsHQ"
ENFORCE_OVERRIDE=""     # "", "evaluate", or "active"
FILES=()

while [ $# -gt 0 ]; do
  case "$1" in
    --org) ORG="${2:?}"; shift 2 ;;
    --evaluate) ENFORCE_OVERRIDE="evaluate"; shift ;;
    --active) ENFORCE_OVERRIDE="active"; shift ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    -*) echo "Unknown flag: $1" >&2; exit 2 ;;
    *) FILES+=("$1"); shift ;;
  esac
done

command -v gh >/dev/null || { echo "gh not found" >&2; exit 2; }
command -v jq >/dev/null || { echo "jq not found" >&2; exit 2; }

# Default to every ruleset payload next to this script's repo root.
if [ "${#FILES[@]}" -eq 0 ]; then
  root="$(cd "$(dirname "$0")/.." && pwd)"
  while IFS= read -r f; do FILES+=("$f"); done < <(ls "$root"/rulesets/*.json)
fi

# Existing org rulesets: name -> id.
existing="$(gh api "orgs/${ORG}/rulesets?per_page=100" --jq '[.[] | {name, id}]')"

for file in "${FILES[@]}"; do
  [ -f "$file" ] || { echo "skip (not found): $file" >&2; continue; }
  payload="$(cat "$file")"
  name="$(printf '%s' "$payload" | jq -r '.name')"
  if [ -n "$ENFORCE_OVERRIDE" ]; then
    payload="$(printf '%s' "$payload" | jq --arg e "$ENFORCE_OVERRIDE" '.enforcement=$e')"
  fi
  enf="$(printf '%s' "$payload" | jq -r '.enforcement')"
  id="$(printf '%s' "$existing" | jq -r --arg n "$name" '.[] | select(.name==$n) | .id' | head -1)"

  if [ -n "$id" ] && [ "$id" != "null" ]; then
    printf '%s' "$payload" | gh api -X PUT "orgs/${ORG}/rulesets/${id}" --input - \
      --jq '"updated \(.name) (id \(.id)) -> enforcement=\(.enforcement)"'
  else
    printf '%s' "$payload" | gh api -X POST "orgs/${ORG}/rulesets" --input - \
      --jq '"created \(.name) (id \(.id)) -> enforcement=\(.enforcement)"'
  fi
  echo "  applied from ${file} (enforcement=${enf})"
done
