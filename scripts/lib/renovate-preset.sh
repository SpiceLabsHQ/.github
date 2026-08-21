#!/usr/bin/env bash
# Shared Renovate-preset detection and rewriting (DEV-1167).
#
# WHY THIS IS A LIBRARY: org Renovate policy living in two places is the bug
# that caused DEV-1150. The seed in migrate-legacy-v1-pins.sh restated
# config:recommended and a -vN packageRule instead of extending default.json,
# then default.json changed and the copy did not, and nine repos silently
# inherited nothing. scripts/org-ci-audit.sh (which reports preset adoption) and
# scripts/sweep-renovate-preset.sh (which fixes it) must agree on what
# "on-preset" means forever, so the definition lives here once and both source
# it.
#
# Callers must set ORG before calling renovate_state (it reads the org from the
# environment so the audit's --org override keeps working).
#
# Requires: gh (authenticated), jq.

# The canonical reference to this org's shared preset (default.json in the
# .github repo). Changing this changes what every consumer considers compliant.
RENOVATE_PRESET="github>SpiceLabsHQ/.github"

# Renovate accepts several config filenames/locations, and when a repo has more
# than one it uses the FIRST in its documented resolution order and silently
# ignores the rest. This list must therefore match that order exactly, not just
# contain the same entries: a tool that picks a different file than Renovate
# does will report on — or worse, edit — a config that has no effect.
#
# Two org repos are live examples. Claude-Marketplace and
# Claude-Marketplace-Internal each carry a root renovate.json extending only
# config:recommended AND a .github/renovate.json extending the org preset. The
# root file wins, so both repos inherit no org policy while looking compliant to
# anyone who opens the .github/ one. An earlier hand survey read .github/ first
# and scored them on-preset; they are not.
#
# Order per Renovate's config resolution: root, then .github/, then .gitlab/,
# then .renovaterc*.
RENOVATE_CONFIG_PATHS="renovate.json renovate.json5 .github/renovate.json .github/renovate.json5 .gitlab/renovate.json .gitlab/renovate.json5 .renovaterc .renovaterc.json .renovaterc.json5"

# True when a Renovate config's `extends` pulls in this org's shared preset.
# Matches the documented shorthands and tolerates a `#branch` / `:preset` suffix.
extends_has_preset() {
  local content="$1" entries
  # Parse `extends` properly where we can. A bare substring match would also hit
  # `matchPackageNames: ["SpiceLabsHQ/.github**"]` — a package selector, not a
  # preset reference — and default.json itself contains exactly that.
  entries="$(printf '%s' "$content" | jq -r '(.extends // []) | .[]' 2>/dev/null || true)"
  if [ -n "$entries" ]; then
    printf '%s\n' "$entries" | grep -qiE '^(github|local)>SpiceLabsHQ/\.github([#:].*)?$'
    return
  fi
  # json5 or commented configs jq can't parse: match the preset reference inside
  # an extends array, still avoiding the matchPackageNames form.
  printf '%s' "$content" | tr -d ' \n' \
    | grep -qiE '"extends":\[[^]]*"(github|local)>SpiceLabsHQ/\.github'
}

# Echoes the path of the repo's Renovate config, or empty if it has none.
# Only the documented file locations; a `renovate` key inside package.json is
# reported by renovate_state but has no standalone path.
renovate_config_path() {
  local repo="$1" p
  for p in $RENOVATE_CONFIG_PATHS; do
    if gh api "repos/${ORG:?}/${repo}/contents/${p}" >/dev/null 2>&1; then
      printf '%s' "$p"
      return 0
    fi
  done
  return 1
}

# Echoes every Renovate config path present in the repo, newline-separated, in
# resolution order. More than one line means the later ones are SHADOWED: they
# are dead files that still read like live config, so someone editing one sees
# no effect and no error. Callers should surface that rather than silently
# acting on the winner.
renovate_config_all_paths() {
  local repo="$1" p
  for p in $RENOVATE_CONFIG_PATHS; do
    gh api "repos/${ORG:?}/${repo}/contents/${p}" >/dev/null 2>&1 && printf '%s\n' "$p"
  done
  return 0
}

# Echoes the raw (base64-decoded) contents of a file in a repo, or empty.
renovate_fetch() {
  gh api "repos/${ORG:?}/$1/contents/$2" --jq '.content' 2>/dev/null \
    | base64 -d 2>/dev/null || true
}

# Echoes the repo's Renovate state: `none`, `off-preset`, or `on-preset`.
#
# Presence alone is not compliance (DEV-1153). The shared preset is where org
# dependency policy lives — Pepper-gated auto-merge, the 7-day
# minimumReleaseAge soak, and the vulnerabilityAlerts carve-out that lets a CVE
# fix skip that soak. A config that omits the `extends` line inherits none of
# it. The audit previously checked only that a file existed, so nine repos on a
# preset-less seed scored identically to compliant ones for six weeks
# (DEV-1150).
renovate_state() {
  local repo="$1" p content nested
  p="$(renovate_config_path "$repo" || true)"
  if [ -n "$p" ]; then
    content="$(renovate_fetch "$repo" "$p")"
    if extends_has_preset "$content"; then echo "on-preset"; else echo "off-preset"; fi
    return
  fi
  # Also honor a `renovate` key inside package.json.
  content="$(renovate_fetch "$repo" package.json)"
  if printf '%s' "$content" | grep -q '"renovate"'; then
    nested="$(printf '%s' "$content" | jq -c '.renovate // empty' 2>/dev/null || true)"
    if [ -n "$nested" ] && extends_has_preset "$nested"; then echo "on-preset"; else echo "off-preset"; fi
    return
  fi
  echo "none"
}

# Rewrites a Renovate config so it extends the shared preset, echoing the new
# JSON. Deliberately MINIMAL — it touches `extends` and nothing else:
#
#   - `enabledManagers` is PRESERVED. Dropping it would silently enable npm on
#     repos whose engines floor has not been settled yet (DEV-1103), turning a
#     config sweep into an unreviewed dependency bump wave. The sweep widens
#     coverage only where a repo has no config at all.
#   - `packageRules` are PRESERVED even when a rule duplicates preset policy.
#     Pruning them is a judgement call per repo, not something to do unattended
#     across 20+ repos; the sweep reports duplicates for a human instead.
#   - `config:recommended` is dropped from `extends` because the preset already
#     extends it, so keeping it is noise that invites the "which one wins?"
#     confusion this whole effort exists to remove.
#
# Idempotent: a config already naming the preset comes back unchanged in effect.
apply_preset_to_config() {
  printf '%s' "$1" | jq --arg preset "$RENOVATE_PRESET" '
    .extends = ([$preset] + ((.extends // [])
      | map(select(. != "config:recommended" and . != $preset))))
  '
}

# The config seeded into a repo that has none. Matches what Template-Code and
# Template-Docs ship. No `enabledManagers`: a narrowing fails silently — no
# check goes red, the update PRs simply never appear — so it must be a
# deliberate per-repo decision, never a default (DEV-1152).
renovate_seed_config() {
  cat <<JSON
{
  "\$schema": "https://docs.renovatebot.com/renovate-schema.json",
  "extends": ["${RENOVATE_PRESET}"]
}
JSON
}
