#!/usr/bin/env bash
# Fixture tests for the Renovate config rewrite in scripts/lib/renovate-preset.sh
# (DEV-1167).
#
# `apply_preset_to_config` is the one piece of this sweep that runs unattended
# against 20+ repos and edits a file in each. Two of its properties are
# load-bearing and neither is obvious from reading the jq:
#
#   1. enabledManagers MUST survive untouched. Dropping it silently enables the
#      npm manager on repos whose engines floor is unsettled (DEV-1103), which
#      turns a config sweep into an unreviewed dependency-bump wave. The sweep
#      widens coverage only where a repo has no config at all.
#   2. packageRules MUST survive untouched, even when a rule restates preset
#      policy. Pruning is a per-repo judgement call, not something to do
#      unattended.
#
# The harness SOURCES the shipping library rather than restating the jq, so a
# change to the real function is what gets tested.
#
# Run locally:  .github/workflows/test/renovate-sweep-rewrite-test.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="${HERE}/../../../scripts/lib/renovate-preset.sh"

[ -r "$LIB" ] || { echo "FAIL: cannot read ${LIB}" >&2; exit 1; }
# shellcheck source=scripts/lib/renovate-preset.sh
. "$LIB"

command -v jq >/dev/null || { echo "jq not found" >&2; exit 2; }

pass=0
fail=0

# check <description> <input> <expected>  — compared as normalized JSON.
check() {
  local desc="$1" input="$2" expected="$3" got
  got="$(apply_preset_to_config "$input" | jq -S -c . 2>/dev/null)"
  expected="$(printf '%s' "$expected" | jq -S -c .)"
  if [ "$got" = "$expected" ]; then
    pass=$((pass + 1)); printf 'ok   %s\n' "$desc"
  else
    fail=$((fail + 1))
    printf 'FAIL %s\n     expected: %s\n     got:      %s\n' "$desc" "$expected" "$got"
  fi
}

# --- the shape this sweep actually meets ------------------------------------
# Verbatim from the July 4 seed that nine repos still carry (DEV-1150).
SEEDED='{
  "$schema": "https://docs.renovatebot.com/renovate-schema.json",
  "extends": ["config:recommended"],
  "enabledManagers": ["github-actions"],
  "packageRules": [
    {
      "description": "SpiceLabsHQ reusable workflows: release-please monorepo tags like pepper-pr-review-v1.2.3",
      "matchManagers": ["github-actions"],
      "matchDatasources": ["github-tags"],
      "matchPackageNames": ["SpiceLabsHQ/.github**"],
      "versionCompatibility": "^(?<compatibility>.*)-v(?<version>.*)$",
      "versioning": "semver"
    }
  ]
}'

check "the real Group A seed: extends repointed, everything else intact" \
  "$SEEDED" \
  '{
    "$schema": "https://docs.renovatebot.com/renovate-schema.json",
    "extends": ["github>SpiceLabsHQ/.github"],
    "enabledManagers": ["github-actions"],
    "packageRules": [
      {
        "description": "SpiceLabsHQ reusable workflows: release-please monorepo tags like pepper-pr-review-v1.2.3",
        "matchManagers": ["github-actions"],
        "matchDatasources": ["github-tags"],
        "matchPackageNames": ["SpiceLabsHQ/.github**"],
        "versionCompatibility": "^(?<compatibility>.*)-v(?<version>.*)$",
        "versioning": "semver"
      }
    ]
  }'

# --- the load-bearing preservation guarantees -------------------------------
check "enabledManagers is preserved verbatim (the DEV-1103 guard)" \
  '{"extends":["config:recommended"],"enabledManagers":["github-actions","mise"]}' \
  '{"extends":["github>SpiceLabsHQ/.github"],"enabledManagers":["github-actions","mise"]}'

check "absent enabledManagers is not invented" \
  '{"extends":["config:recommended"]}' \
  '{"extends":["github>SpiceLabsHQ/.github"]}'

check "unrelated top-level keys are preserved" \
  '{"$schema":"x","description":["why"],"extends":["config:recommended"],"timezone":"America/Los_Angeles"}' \
  '{"$schema":"x","description":["why"],"extends":["github>SpiceLabsHQ/.github"],"timezone":"America/Los_Angeles"}'

# --- extends handling -------------------------------------------------------
check "config:recommended is dropped (the preset already extends it)" \
  '{"extends":["config:recommended"]}' \
  '{"extends":["github>SpiceLabsHQ/.github"]}'

check "an unrelated preset is kept, after ours" \
  '{"extends":["config:recommended","github>SomeOrg/renovate-presets"]}' \
  '{"extends":["github>SpiceLabsHQ/.github","github>SomeOrg/renovate-presets"]}'

check "a missing extends key is created" \
  '{"enabledManagers":["github-actions"]}' \
  '{"extends":["github>SpiceLabsHQ/.github"],"enabledManagers":["github-actions"]}'

check "an empty extends array is populated" \
  '{"extends":[]}' \
  '{"extends":["github>SpiceLabsHQ/.github"]}'

check "already on-preset is unchanged (no duplicate entry)" \
  '{"extends":["github>SpiceLabsHQ/.github"]}' \
  '{"extends":["github>SpiceLabsHQ/.github"]}'

# --- idempotency ------------------------------------------------------------
# The sweep no-ops on on-preset repos, but a rerun must never compound.
once="$(apply_preset_to_config "$SEEDED")"
twice="$(apply_preset_to_config "$once")"
if [ "$(printf '%s' "$once" | jq -S -c .)" = "$(printf '%s' "$twice" | jq -S -c .)" ]; then
  pass=$((pass + 1)); printf 'ok   %s\n' "applying twice is identical to applying once"
else
  fail=$((fail + 1)); printf 'FAIL %s\n' "applying twice differs from applying once"
fi

# --- output is valid, writable JSON -----------------------------------------
if printf '%s' "$once" | jq empty 2>/dev/null; then
  pass=$((pass + 1)); printf 'ok   %s\n' "output parses as JSON"
else
  fail=$((fail + 1)); printf 'FAIL %s\n' "output does not parse as JSON"
fi

# --- the seed config the sweep writes for unconfigured repos ----------------
seed="$(renovate_seed_config)"
if printf '%s' "$seed" | jq -e --arg p "$RENOVATE_PRESET" \
     '.extends == [$p] and (has("enabledManagers") | not)' >/dev/null 2>&1; then
  pass=$((pass + 1)); printf 'ok   %s\n' "seed config extends the preset and sets no enabledManagers"
else
  fail=$((fail + 1)); printf 'FAIL %s\n     got: %s\n' "seed config is wrong" "$seed"
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ] || exit 1
