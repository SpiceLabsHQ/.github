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
# GitHub's "Update a repository" REST API. The reconciler diffs every group
# against each live repo and PATCHes, in a single atomic call, every field of
# each group that has any drift (so merge-method invariants — GitHub requires
# >=1 method enabled — never transiently break).
#
# WHY WHOLE-GROUP AND NOT JUST THE DRIFTED FIELDS: GitHub validates some fields
# as a set, against request defaults rather than the repo's stored values, so a
# minimal diff can be rejected even when the resulting state would be legal. A
# repo with squash title PR_TITLE / message COMMIT_MESSAGES drifting only on the
# message gets 422 invalid_squash_commit_setting_combo for {message: PR_BODY}:
# the omitted title defaults to COMMIT_OR_PR_TITLE, which cannot pair with
# PR_BODY. Sending the group whole keeps every co-validated field in the request.
# A group is therefore the coupling boundary — put fields GitHub validates
# together in the same group.
#
# Team access (DEV-525) is a SECOND, separate pass. Granting a team access to a
# repo is not a repo-update field but its own endpoint
# (PUT /orgs/{org}/teams/{slug}/repos/{owner}/{repo}), so the `team_access`
# section is reconciled independently with FLOOR semantics: ensure each team has
# at least the configured permission, never downgrade a higher existing grant.
# This is what keeps the `reviewers` team's read access (Pepper's escalation
# target) present on every repo as new repos are added.
#
# Two modes:
#   audit  (default) — dry-run: report drift, make no writes.
#   apply            — reconcile: PATCH drifted repos / grant missing team access.
#
# Exceptions follow the `ci-exception` custom-property model (see the CI floor
# rulesets). The property named by `options.exception_property` opts a repo out:
#   "all"/"*"             → skip the whole repo (both passes)
#   "<group>"             → skip that policy group only
#   "team_access"         → skip the team-access pass only
#   "<group>,<group>,..." → skip each listed group / pass
#   unset/empty           → fully reconciled
# `options.exclude_forks: true` additionally skips every fork (both passes).
#
# Output: a Markdown reconciliation report on stdout (drift + actions). The
# workflow tees it into the job summary.
#
# Requires: gh (authenticated with an org-scoped token), jq, and yq (mikefarah)
# to parse the YAML config. Set GH_TOKEN in the environment. Token permissions:
# Administration write (policies apply) + Metadata read + org Custom-properties
# read, and — for the team_access pass — org Members read (audit) / write (apply,
# to manage a team's repos).
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

# team slug -> {permission: level} map for the team-access pass (DEV-525).
team_access_json="$(printf '%s' "$cfg" | jq -c '.team_access // {}')"
team_slugs="$(printf '%s' "$team_access_json" | jq -r 'keys[]')"

if [ -z "$group_names" ] && [ -z "$team_slugs" ]; then
  echo "config ${CONFIG} declares no policies and no team_access — nothing to reconcile" >&2
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

# GitHub's own error message, pulled out of a failed `gh api` stderr blob and
# flattened to one Markdown-safe line for the report. gh prints the JSON response
# body followed by its own `gh: <summary>` line, so trim from that line onward
# before parsing; fall back to the raw text when the body isn't JSON (network
# failure, HTML error page). Never guess at a cause here — print what the API said.
api_error() {
  local raw="$1" body msg
  body="${raw%%gh: *}"
  msg="$(printf '%s' "$body" | jq -r '
    [.message, (.errors[]?.message // empty)]
    | map(select(. != null and . != "")) | join(" — ")' 2>/dev/null || true)"
  [ -z "$msg" ] && msg="$raw"
  printf '%s' "$msg" | tr '\n' ' ' | tr -s ' ' | sed "s/\`/'/g"
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

# --- Pass 1: repo-update-field policies (skipped entirely if none declared) -
if [ -n "$group_names" ]; then
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

  # Groups to reconcile for this repo = every desired group that isn't skipped.
  # Kept grouped (not flattened) because the PATCH body is assembled per group.
  desired_groups="$(printf '%s' "$groups_json" | jq -c \
    --arg skips "$skips" '
      ($skips | split("\n") | map(select(length>0))) as $skip
      | with_entries(select((.key as $g | $skip | index($g)) | not))')"
  [ "$(printf '%s' "$desired_groups" | jq '[.[] | to_entries[]] | length')" -eq 0 ] && {
    # Every group excepted for this repo.
    n_skipped=$((n_skipped + 1)); skip_report="${skip_report}- \`${repo}\` — all policy groups excepted (\`${exc_prop}=${exc}\`)\n"; continue
  }

  # Live settings for the repo (single GET). On error, note and move on.
  cur="$(gh api "repos/${ORG}/${repo}" 2>/dev/null || true)"
  if [ -z "$cur" ]; then
    n_errors=$((n_errors + 1)); drift_report="${drift_report}- \`${repo}\` — ⚠️ could not read repo settings (skipped)\n"; continue
  fi

  # Drift: the fields whose live value differs from desired. Reported as-is —
  # this is what actually changes, and the only thing worth showing a human.
  drifted="$(jq -cn --argjson cur "$cur" --argjson groups "$desired_groups" '
    [ $groups[] | to_entries[] | select($cur[.key] != .value) ] | from_entries')"

  if [ "$(printf '%s' "$drifted" | jq 'length')" -eq 0 ]; then
    n_conformant=$((n_conformant + 1)); continue
  fi

  # PATCH body: every field of every group containing drift — not just the
  # drifted fields. See the header note on co-validated fields (422s). Fields
  # already at the desired value are re-sent unchanged, so this stays idempotent.
  patch="$(jq -cn --argjson cur "$cur" --argjson groups "$desired_groups" '
    [ $groups[]
      | select(any(to_entries[]; $cur[.key] != .value))
      | to_entries[] ] | from_entries')"

  # Human-readable diff lines (field: current → desired).
  diff_lines="$(jq -rn --argjson cur "$cur" --argjson drifted "$drifted" '
    $drifted | to_entries[] | "  - `\(.key)`: `\($cur[.key] | tojson)` → `\(.value | tojson)`"')"
  n_drift=$((n_drift + 1))

  if [ "$MODE" = "apply" ]; then
    # Capture stderr (only) so a failure reports what GitHub actually said. The
    # previous blanket 2>&1 discarded it and the report guessed at permissions,
    # which sent a real 422 invalid_squash_commit_setting_combo on a six-night
    # red schedule to the wrong root cause.
    if patch_err="$(printf '%s' "$patch" | gh api -X PATCH "repos/${ORG}/${repo}" --input - 2>&1 >/dev/null)"; then
      n_applied=$((n_applied + 1))
      applied_report="${applied_report}- \`${repo}\` — reconciled:\n${diff_lines}\n"
    else
      n_errors=$((n_errors + 1))
      drift_report="${drift_report}- \`${repo}\` — ⚠️ PATCH failed: $(api_error "$patch_err")\n${diff_lines}\n"
    fi
  else
    drift_report="${drift_report}- \`${repo}\` — drift:\n${diff_lines}\n"
  fi
done < <(printf '%s' "$repos_json" | jq -r '.[].name' | sort)
fi

# --- Pass 2: team repo-access (DEV-525) -------------------------------------
# Floor semantics: ensure each configured team has AT LEAST the desired
# permission on every reconciled repo; never downgrade a higher existing grant.
# Team access is a different endpoint than repo-update fields
# (PUT /orgs/{org}/teams/{slug}/repos/{owner}/{repo}), reconciled here as a
# separate pass sharing the repo inventory + fork/exception skips from above.
team_report=""
n_team_scanned=0; n_team_conformant=0; n_team_drift=0; n_team_granted=0; n_team_skipped=0; n_team_errors=0

perm_rank() {
  case "$1" in
    pull) echo 1 ;; triage) echo 2 ;; push) echo 3 ;; maintain) echo 4 ;; admin) echo 5 ;;
    *) echo 0 ;;
  esac
}

while IFS= read -r slug; do
  [ -z "$slug" ] && continue
  want_perm="$(printf '%s' "$team_access_json" | jq -r --arg s "$slug" '.[$s].permission // "pull"')"
  want_rank="$(perm_rank "$want_perm")"
  if [ "$want_rank" -eq 0 ]; then
    n_team_errors=$((n_team_errors + 1))
    team_report="${team_report}- team \`${slug}\` — ⚠️ invalid permission \`${want_perm}\` (want pull|triage|push|maintain|admin)\n"
    continue
  fi

  # One paginated call per team: the repos it can access, with permission booleans.
  # Capture gh's exit status explicitly (via `if`, not a pipe): on 404 — team
  # missing or unreadable — gh emits an error body that must NOT be slurped and
  # mistaken for a repo list, so blank it and let the not-readable branch handle
  # it. Empty is otherwise ambiguous (no grants yet vs. missing team), so the
  # branch confirms the team exists before treating [] as "team has zero repos".
  if team_repos_pages="$(gh api "orgs/${ORG}/teams/${slug}/repos?per_page=100" --paginate --jq '[.[] | {name, permissions}]' 2>/dev/null)"; then
    team_repos="$(printf '%s' "$team_repos_pages" | jq -cs 'add // []' 2>/dev/null || true)"
  else
    team_repos=""
  fi
  if [ -z "$team_repos" ]; then
    if ! gh api "orgs/${ORG}/teams/${slug}" >/dev/null 2>&1; then
      # Can't read the team at all — either it doesn't exist, or the token lacks
      # org Members: read (the team-access feature simply isn't provisioned yet).
      # Warn and SKIP rather than failing the whole reconcile red — mirrors the
      # workflow's credential guard, which no-ops with a warning. A real grant
      # failure in apply mode (below) still counts as an error and goes red.
      n_team_skipped=$((n_team_skipped + 1))
      team_report="${team_report}- team \`${slug}\` — ⚠️ not readable in org \`${ORG}\` — skipped (missing team, or token lacks org Members: read)\n"
      continue
    fi
    team_repos='[]'
  fi

  while IFS= read -r repo; do
    [ -z "$repo" ] && continue
    is_fork="$(printf '%s' "$repos_json" | jq -r --arg r "$repo" '.[] | select(.name==$r) | .fork')"
    exc="$(printf '%s' "$props_json" | jq -r --arg r "$repo" '(.[] | select(.name==$r) | .exc) // ""')"
    skips="$(skipped_groups "$exc")"

    # Same whole-repo skips as pass 1, plus the `team_access` pass opt-out.
    [ "$exclude_forks" = "true" ] && [ "$is_fork" = "true" ] && continue
    printf '%s\n' "$skips" | grep -qx '\*ALL\*' && continue
    printf '%s\n' "$skips" | grep -qx 'team_access' && continue

    n_team_scanned=$((n_team_scanned + 1))
    # Highest permission the team currently holds on this repo (0 = no access).
    cur_rank="$(printf '%s' "$team_repos" | jq -r --arg r "$repo" '
      (.[] | select(.name==$r) | .permissions) as $p
      | if   $p == null  then 0
        elif $p.admin    then 5
        elif $p.maintain then 4
        elif $p.push     then 3
        elif $p.triage   then 2
        elif $p.pull     then 1
        else 0 end')"
    [ -z "$cur_rank" ] && cur_rank=0

    if [ "$cur_rank" -ge "$want_rank" ]; then
      n_team_conformant=$((n_team_conformant + 1)); continue
    fi
    n_team_drift=$((n_team_drift + 1))

    if [ "$MODE" = "apply" ]; then
      if grant_err="$(gh api -X PUT "orgs/${ORG}/teams/${slug}/repos/${ORG}/${repo}" -f permission="${want_perm}" 2>&1 >/dev/null)"; then
        n_team_granted=$((n_team_granted + 1))
        team_report="${team_report}- \`${repo}\` — granted team \`${slug}\` = \`${want_perm}\`\n"
      else
        n_team_errors=$((n_team_errors + 1))
        team_report="${team_report}- \`${repo}\` — ⚠️ failed to grant team \`${slug}\` = \`${want_perm}\`: $(api_error "$grant_err")\n"
      fi
    else
      team_report="${team_report}- \`${repo}\` — team \`${slug}\` below \`${want_perm}\` (would grant)\n"
    fi
  done < <(printf '%s' "$repos_json" | jq -r '.[].name' | sort)
done < <(printf '%s\n' "$team_slugs")

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

# Team-access pass report (DEV-525). Only shown when team_access is configured.
if [ -n "$team_slugs" ]; then
  printf '\n## Team access\n\n'
  printf '| Scanned | Conformant | Drifted | Granted | Skipped | Errors |\n'
  printf '|--:|--:|--:|--:|--:|--:|\n'
  printf '| %d | %d | %d | %d | %d | %d |\n\n' \
    "$n_team_scanned" "$n_team_conformant" "$n_team_drift" "$n_team_granted" "$n_team_skipped" "$n_team_errors"
  if [ -n "$team_report" ]; then printf '%b' "$team_report"; else printf '_Every reconciled repo already satisfies the desired team access._\n'; fi
fi

# Non-zero exit if either pass hit errors, so the scheduled run surfaces red.
[ $((n_errors + n_team_errors)) -eq 0 ] || exit 1
