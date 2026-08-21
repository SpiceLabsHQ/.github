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

# --- formatting preservation (DEV-1178) -------------------------------------
# Every assertion above compares PARSED JSON, which is exactly how the original
# defect shipped: apply_preset_to_config round-tripped through jq, re-rendered
# the whole document, and stayed semantically perfect while failing
# `prettier --check` in every repo that lints JSON (Atelier#262, Lumen-BI#382).
# These assert on the TEXT, so a return to whole-document rendering fails here.

# check_text <description> <input> <expected-exact-output>
check_text() {
  local desc="$1" input="$2" expected="$3" got
  got="$(apply_preset_to_config "$input")"
  if [ "$got" = "$expected" ]; then
    pass=$((pass + 1)); printf 'ok   %s\n' "$desc"
  else
    fail=$((fail + 1))
    printf 'FAIL %s\n--- expected ---\n%s\n--- got ---\n%s\n' "$desc" "$expected" "$got"
  fi
}

check_text "an inline extends array stays inline" \
  '{
  "$schema": "x",
  "extends": ["config:recommended"],
  "enabledManagers": ["github-actions"]
}' \
  '{
  "$schema": "x",
  "extends": ["github>SpiceLabsHQ/.github"],
  "enabledManagers": ["github-actions"]
}'

check_text "a multi-line extends array stays multi-line at its own indent" \
  '{
  "extends": [
    "config:recommended"
  ],
  "timezone": "America/Los_Angeles"
}' \
  '{
  "extends": [
    "github>SpiceLabsHQ/.github"
  ],
  "timezone": "America/Los_Angeles"
}'

check_text "a missing extends key is inserted inline, other keys untouched" \
  '{
  "enabledManagers": ["github-actions"]
}' \
  '{
  "extends": ["github>SpiceLabsHQ/.github"],
  "enabledManagers": ["github-actions"]
}'

# The real Group A config, byte for byte. Only the extends line may differ —
# brackets inside the versioning regex and the matchPackageNames glob must not
# confuse the value-span scan.
check_text "the real Group A config changes exactly one line" \
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

# --- top-level key removal (DEV-1182) ---------------------------------------
# Used to prune the duplicated -vN packageRule from repos that inherited it from
# the 2026-07-04 seed. The comma handling is the whole risk: swallow the wrong
# one and the result is either a dangling comma or a missing one, shipped to
# nine repos at once. The helper re-parses its own output and refuses on invalid
# JSON, but these pin the two positional cases directly.

EDITOR="${HERE}/../../../scripts/lib/renovate-extends-edit.py"

# check_removal <description> <key> <input> <expected-exact-output>
check_removal() {
  local desc="$1" key="$2" input="$3" expected="$4" got
  got="$(printf '%s' "$input" | python3 "$EDITOR" --remove-key "$key" 2>/dev/null)"
  if [ "$got" = "$expected" ]; then
    pass=$((pass + 1)); printf 'ok   %s\n' "$desc"
  else
    fail=$((fail + 1))
    printf 'FAIL %s\n--- expected ---\n%s\n--- got ---\n%s\n' "$desc" "$expected" "$got"
  fi
}

# The real shape being pruned: packageRules is the LAST member, so the comma
# before it must go with it. Brackets inside the versioning regex and the
# matchPackageNames glob must not confuse the span scan.
check_removal "removing a trailing key takes the comma before it" packageRules \
  '{
  "$schema": "x",
  "extends": ["github>SpiceLabsHQ/.github"],
  "enabledManagers": ["github-actions"],
  "packageRules": [
    {
      "matchPackageNames": ["SpiceLabsHQ/.github**"],
      "versionCompatibility": "^(?<compatibility>.*)-v(?<version>.*)$"
    }
  ]
}' \
  '{
  "$schema": "x",
  "extends": ["github>SpiceLabsHQ/.github"],
  "enabledManagers": ["github-actions"]
}'

check_removal "removing a middle key takes the comma after it" enabledManagers \
  '{
  "extends": ["github>SpiceLabsHQ/.github"],
  "enabledManagers": ["github-actions"],
  "timezone": "America/Los_Angeles"
}' \
  '{
  "extends": ["github>SpiceLabsHQ/.github"],
  "timezone": "America/Los_Angeles"
}'

check_removal "removing a scalar-valued key works too" timezone \
  '{
  "extends": ["github>SpiceLabsHQ/.github"],
  "timezone": "America/Los_Angeles"
}' \
  '{
  "extends": ["github>SpiceLabsHQ/.github"]
}'

# Pepper caught this one in review on #206: with no preceding comma to absorb,
# `start` never moved and the object was left holding a bare whitespace line —
# valid JSON, so the re-parse guard passed it, but the exact shape
# `prettier --check` rejects. Collapsing to `{}` is the only correct rendering.
check_removal "removing the only key collapses the object" extends \
  '{
  "extends": ["github>SpiceLabsHQ/.github"]
}' \
  '{}'

check_removal "removing an absent key is a no-op" packageRules \
  '{
  "extends": ["github>SpiceLabsHQ/.github"]
}' \
  '{
  "extends": ["github>SpiceLabsHQ/.github"]
}'

# --- the PR title the sweep opens 24 PRs with (DEV-1171) ---------------------
# A regression here does not fail quietly: it breaks every PR the sweep opens,
# all at once, on a blocking required check. Both properties are pinned.
#
# The allowed type list is read out of pr-hygiene.yml rather than restated, so
# this cannot pass while disagreeing with the check that actually gates merges.
SWEEP="${HERE}/../../../scripts/sweep-renovate-preset.sh"
HYGIENE="${HERE}/../pr-hygiene.yml"

pr_title="$(sed -n 's/^PR_TITLE="\(.*\)"$/\1/p' "$SWEEP")"
types="$(sed -n 's/^ *default: \(feat,fix,chore[a-z,]*\) *$/\1/p' "$HYGIENE" | head -1)"

if [ -z "$pr_title" ]; then
  fail=$((fail + 1)); printf 'FAIL %s\n' "could not extract PR_TITLE from ${SWEEP}"
elif [ -z "$types" ]; then
  fail=$((fail + 1)); printf 'FAIL %s\n' "could not extract the allowed type list from ${HYGIENE}"
else
  type_re="$(printf '%s' "$types" | tr ',' '|')"
  if printf '%s' "$pr_title" | grep -qE "^(${type_re})(\([^)]+\))?!?: .+"; then
    pass=$((pass + 1)); printf 'ok   %s\n' "sweep PR title is a Conventional Commit ($pr_title)"
  else
    fail=$((fail + 1))
    printf 'FAIL %s\n     title: %s\n     allowed types: %s\n' \
      "sweep PR title is not a Conventional Commit — pr-hygiene would fail every sweep PR" \
      "$pr_title" "$types"
  fi

  # `chore` specifically: it is what carries the intent_verification exemption
  # for these issue-less housekeeping PRs, and it is the only type that does not
  # cut a release in target repos running release-please.
  if printf '%s' "$pr_title" | grep -qE '^chore(\([^)]+\))?: '; then
    pass=$((pass + 1)); printf 'ok   %s\n' "sweep PR title uses the chore type"
  else
    fail=$((fail + 1))
    printf 'FAIL %s\n     title: %s\n' \
      "sweep PR title must use the chore type (exemption + no release bump)" "$pr_title"
  fi
fi

# --- failure containment wiring (DEV-1175) -----------------------------------
# These are structural assertions, not behavioural ones: the real behaviour needs
# the GitHub API and CI has no org-scoped token. What they pin is that the
# containment stays WIRED UP, because every property below fails silently if
# removed — the sweep would simply go back to dying on the first bad repo and
# taking the list of already-opened PRs with it.
sweep_src="$(cat "$SWEEP" 2>/dev/null)"

assert_contains() {
  local desc="$1" pattern="$2"
  if printf '%s' "$sweep_src" | grep -qE "$pattern"; then
    pass=$((pass + 1)); printf 'ok   %s\n' "$desc"
  else
    fail=$((fail + 1)); printf 'FAIL %s\n     no line matching: %s\n' "$desc" "$pattern"
  fi
}

assert_absent() {
  local desc="$1" pattern="$2"
  if printf '%s' "$sweep_src" | grep -qE "$pattern"; then
    fail=$((fail + 1)); printf 'FAIL %s\n     unexpected match: %s\n' "$desc" "$pattern"
  else
    pass=$((pass + 1)); printf 'ok   %s\n' "$desc"
  fi
}

if [ -z "$sweep_src" ]; then
  fail=$((fail + 1)); printf 'FAIL %s\n' "could not read ${SWEEP}"
else
  # Testing a function's result suspends set -e for its body, which is exactly
  # what stops one repo's failure from killing the run.
  assert_contains "per-repo work runs in a tested context (failure is contained)" \
    '^[[:space:]]*if ! run_repo '

  # The ledger must survive an abort, so it runs from the trap rather than from
  # the end of the script.
  assert_contains "the summary is wired to the EXIT trap" \
    "^trap '.*summarize.*' EXIT"

  # Without this, re-running after a partial sweep dies in gh pr create.
  assert_contains "an already-open PR is detected before creating one" \
    'gh pr list .*--head'

  # A tempting "fix" for a push that fails on an existing branch. The sweep does
  # not own every branch that happens to share its name, so a diverged branch
  # must surface as a failure, never be overwritten.
  assert_absent "the sweep never force-pushes" \
    'git push[^|&]*--force'
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ] || exit 1
