#!/usr/bin/env bash
# General-purpose org repo-settings reconciler (DEV-519).
#
# Reconciles every non-archived repo in the org to a declarative desired-state
# (repo-settings.yml). It exists because some per-repo settings — notably merge
# methods — cannot be enforced by org rulesets: there is no ruleset rule for
# merge method and the flags are per-repo, so API-level reconciliation is the
# only lever. Squash-only merge is the first policy it carries, but it is
# general-purpose: adding a new enforced setting is a config edit, not code.
#
# Each leaf key under `policies.<group>` in the config is a literal field of
# GitHub's "Update a repository" REST API. The reconciler flattens every group
# into one desired field-map, diffs it against each live repo, and PATCHes only
# the drifted fields in a single atomic call (so merge-method invariants — GitHub
# requires >=1 method enabled — never transiently break).
#
# Two modes:
#   audit  (default) — dry-run: report drift, make no writes.
#   apply            — reconcile: PATCH drifted repos.
#
# Exceptions follow the `ci-exception` custom-property model (see the CI floor
# rulesets). The property named by `options.exception_property` opts a repo out:
#   "all"/"*"             → skip the whole repo
#   "<group>"             → skip that policy group only
#   "<group>,<group>,..." → skip each listed group
#   unset/empty           → fully reconciled
# `options.exclude_forks: true` additionally skips every fork.
#
# Output: a Markdown reconciliation report on stdout (drift + actions). The
# workflow tees it into the job summary.
#
# Requires: gh (authenticated with an org-scoped token carrying Administration:
# write for apply mode, plus Metadata read and org Custom-properties read), jq,
# and yq (mikefarah) to parse the YAML config. Set GH_TOKEN in the environment.
#
# Usage:
#   scripts/org-repo-settings-reconcile.sh [--org SpiceLabsHQ] \
#       [--mode audit|apply] [--config repo-settings.yml]

set -euo pipefail

ORG="SpiceLabsHQ"
MODE="audit"
CONFIG="repo-settings.yml"

while [ $# -gt 0 ]; do
  case "$1" in
    --org)    ORG="${2:?--org needs a value}"; shift 2 ;;
    --mode)   MODE="${2:?--mode needs a value}"; shift 2 ;;
    --config) CONFIG="${2:?--config needs a value}"; shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

case "$MODE" in audit|apply) : ;; *) echo "--mode must be audit or apply (got: $MODE)" >&2; exit 2 ;; esac

command -v gh >/dev/null || { echo "gh not found" >&2; exit 2; }
command -v jq >/dev/null || { echo "jq not found" >&2; exit 2; }
command -v yq >/dev/null || { echo "yq (mikefarah) not found — needed to parse ${CONFIG}" >&2; exit 2; }
[ -f "$CONFIG" ] || { echo "config not found: ${CONFIG}" >&2; exit 2; }

# --- 1. Load config as JSON -------------------------------------------------
cfg="$(yq -o=json '.' "$CONFIG")"

exclude_forks="$(printf '%s' "$cfg" | jq -r '.options.exclude_forks // false')"
exc_prop="$(printf '%s' "$cfg" | jq -r '.options.exception_property // "repo-settings-exception"')"

# Group -> {field: value} map, and the flattened field -> value desired map.
groups_json="$(printf '%s' "$cfg" | jq -c '.policies // {}')"
group_names="$(printf '%s' "$groups_json" | jq -r 'keys[]')"
if [ -z "$group_names" ]; then
  echo "config ${CONFIG} declares no policies — nothing to reconcile" >&2
  exit 2
fi

# --- 2. Repo inventory (non-archived; name, fork) ---------------------------
repos_json="$(gh api "orgs/${ORG}/repos?per_page=100&type=all" --paginate \
  --jq '[.[] | select(.archived==false) | {name, fork}]' | jq -s 'add // []')"

# --- 3. Exception property values (one call for the whole org) --------------
props_json="$(gh api "orgs/${ORG}/properties/values?per_page=100" --paginate \
  --jq "[.[] | {name: .repository_name, exc: ((.properties[]? | select(.property_name==\"${exc_prop}\") | .value) // \"\")}]" \
  | jq -s 'add // []')"

# Groups skipped for a repo, given its exception value. Echoes group names,
# newline-separated (empty = none skipped; the token "*ALL*" = whole repo).
skipped_groups() {
  local exc="$1"
  [ -z "$exc" ] && return 0
  case "$exc" in
    all|"*") echo "*ALL*"; return 0 ;;
  esac
  printf '%s' "$exc" | tr ',' '\n' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | grep -v '^$' || true
}

# --- 4. Reconcile loop ------------------------------------------------------
printf '# Repo-settings reconciliation — %s mode\n\n' "$MODE"
printf '_Org `%s`, desired-state [`%s`](../blob/main/%s). ' "$ORG" "$CONFIG" "$CONFIG"
if [ "$MODE" = "apply" ]; then
  printf 'Drifted repos were PATCHed to the desired state._\n\n'
else
  printf 'Dry-run — no writes were made; run `apply` mode to reconcile._\n\n'
fi

drift_report=""     # per-repo drift detail
applied_report=""   # per-repo apply confirmations
skip_report=""      # exception/fork skips
n_scanned=0; n_conformant=0; n_drift=0; n_applied=0; n_skipped=0; n_errors=0

while IFS= read -r repo; do
  [ -z "$repo" ] && continue
  n_scanned=$((n_scanned + 1))

  is_fork="$(printf '%s' "$repos_json" | jq -r --arg r "$repo" '.[] | select(.name==$r) | .fork')"
  exc="$(printf '%s' "$props_json" | jq -r --arg r "$repo" '(.[] | select(.name==$r) | .exc) // ""')"

  # Whole-repo skips (fork exclusion or exception=all).
  skips="$(skipped_groups "$exc")"
  if [ "$exclude_forks" = "true" ] && [ "$is_fork" = "true" ]; then
    n_skipped=$((n_skipped + 1)); skip_report="${skip_report}- \`${repo}\` — fork (options.exclude_forks)\n"; continue
  fi
  if printf '%s\n' "$skips" | grep -qx '\*ALL\*'; then
    n_skipped=$((n_skipped + 1)); skip_report="${skip_report}- \`${repo}\` — \`${exc_prop}=${exc}\`\n"; continue
  fi

  # Fields to reconcile for this repo = all desired fields whose group isn't skipped.
  desired_fields="$(printf '%s' "$groups_json" | jq -c \
    --arg skips "$skips" '
      ($skips | split("\n") | map(select(length>0))) as $skip
      | [ to_entries[] | select((.key as $g | $skip | index($g)) | not)
          | .value | to_entries[] ] | from_entries')"
  [ "$(printf '%s' "$desired_fields" | jq 'length')" -eq 0 ] && {
    # Every group excepted for this repo.
    n_skipped=$((n_skipped + 1)); skip_report="${skip_report}- \`${repo}\` — all policy groups excepted (\`${exc_prop}=${exc}\`)\n"; continue
  }

  # Live settings for the repo (single GET). On error, note and move on.
  cur="$(gh api "repos/${ORG}/${repo}" 2>/dev/null || true)"
  if [ -z "$cur" ]; then
    n_errors=$((n_errors + 1)); drift_report="${drift_report}- \`${repo}\` — ⚠️ could not read repo settings (skipped)\n"; continue
  fi

  # Diff: keep only fields whose live value differs from desired.
  patch="$(jq -cn --argjson cur "$cur" --argjson want "$desired_fields" '
    reduce ($want | to_entries[]) as $e ({}; if ($cur[$e.key]) != $e.value then . + {($e.key): $e.value} else . end)')"

  if [ "$(printf '%s' "$patch" | jq 'length')" -eq 0 ]; then
    n_conformant=$((n_conformant + 1)); continue
  fi

  # Human-readable diff lines (field: current → desired).
  diff_lines="$(jq -rn --argjson cur "$cur" --argjson patch "$patch" '
    $patch | to_entries[] | "  - `\(.key)`: `\($cur[.key] | tojson)` → `\(.value | tojson)`"')"
  n_drift=$((n_drift + 1))

  if [ "$MODE" = "apply" ]; then
    if printf '%s' "$patch" | gh api -X PATCH "repos/${ORG}/${repo}" --input - >/dev/null 2>&1; then
      n_applied=$((n_applied + 1))
      applied_report="${applied_report}- \`${repo}\` — reconciled:\n${diff_lines}\n"
    else
      n_errors=$((n_errors + 1))
      drift_report="${drift_report}- \`${repo}\` — ⚠️ PATCH failed (needs Administration: write?):\n${diff_lines}\n"
    fi
  else
    drift_report="${drift_report}- \`${repo}\` — drift:\n${diff_lines}\n"
  fi
done < <(printf '%s' "$repos_json" | jq -r '.[].name' | sort)

# --- 5. Report --------------------------------------------------------------
printf '## Summary\n\n'
printf '| Scanned | Conformant | Drifted | Applied | Skipped | Errors |\n'
printf '|--:|--:|--:|--:|--:|--:|\n'
printf '| %d | %d | %d | %d | %d | %d |\n\n' \
  "$n_scanned" "$n_conformant" "$n_drift" "$n_applied" "$n_skipped" "$n_errors"

if [ "$MODE" = "apply" ]; then
  printf '## Applied\n\n'
  if [ -n "$applied_report" ]; then printf '%b' "$applied_report"; else printf '_Nothing to apply — every scanned repo was already conformant._\n'; fi
  printf '\n'
fi

printf '## Drift%s\n\n' "$([ "$MODE" = apply ] && echo ' / errors' || echo '')"
if [ -n "$drift_report" ]; then printf '%b' "$drift_report"; else printf '_No drift detected._\n'; fi

printf '\n## Skipped (exceptions)\n\n'
if [ -n "$skip_report" ]; then printf '%b' "$skip_report"; else printf '_No repos excepted._\n'; fi

# Non-zero exit if apply hit errors, so the scheduled run surfaces red on failure.
[ "$n_errors" -eq 0 ] || exit 1
