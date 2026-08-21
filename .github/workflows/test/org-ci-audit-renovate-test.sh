#!/usr/bin/env bash
# Fixture tests for the Renovate preset detection in scripts/org-ci-audit.sh
# (DEV-1153).
#
# The audit used to score Renovate on file presence alone, so a config that
# extended nothing but `config:recommended` — and therefore inherited none of
# the org's auto-merge, release-age-soak, or vulnerabilityAlerts policy — scored
# identically to a compliant one. Nine repos sat green that way for six weeks
# (DEV-1150). `extends_has_preset` is what tells the two apart, so its matching
# is pinned down here rather than eyeballed once.
#
# To test the EXACT function that ships without duplicating it, this harness
# extracts `extends_has_preset` straight out of the audit script and sources it.
# The function is pure (jq/grep/printf/tr, no globals, no network), which is why
# it can be tested this way; `renovate_state` around it is not covered here
# because it calls the GitHub API and CI has no org-scoped token.
#
# The load-bearing case is the `matchPackageNames` trap: default.json itself
# contains "SpiceLabsHQ/.github**" as a PACKAGE SELECTOR, so a naive substring
# match would report every repo carrying that rule as on-preset — including the
# preset-less seed that caused DEV-1150. That is fixture 7.
#
# Run locally:  .github/workflows/test/org-ci-audit-renovate-test.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AUDIT="${HERE}/../../../scripts/org-ci-audit.sh"

[ -r "$AUDIT" ] || { echo "FAIL: cannot read ${AUDIT}" >&2; exit 1; }

# Extract the function definition from the shipping script and source it. If the
# function is ever renamed or reshaped, this fails loudly rather than silently
# testing nothing.
FN="$(awk '/^extends_has_preset\(\) \{$/,/^\}$/' "$AUDIT")"
if [ -z "$FN" ]; then
  echo "FAIL: could not extract extends_has_preset() from ${AUDIT}" >&2
  echo "      (was it renamed? update this harness alongside, consciously)" >&2
  exit 1
fi
eval "$FN"

command -v jq >/dev/null || { echo "jq not found" >&2; exit 2; }

pass=0
fail=0

# check <expected: yes|no> <description> <config>
check() {
  local expected="$1" desc="$2" config="$3" got
  if extends_has_preset "$config"; then got="yes"; else got="no"; fi
  if [ "$got" = "$expected" ]; then
    pass=$((pass + 1))
    printf 'ok   %s\n' "$desc"
  else
    fail=$((fail + 1))
    printf 'FAIL %s\n     expected=%s got=%s\n     config: %s\n' "$desc" "$expected" "$got" "$config"
  fi
}

# --- on-preset -------------------------------------------------------------
check yes "bare preset reference" \
  '{"extends":["github>SpiceLabsHQ/.github"]}'

check yes "preset alongside another preset" \
  '{"extends":["config:recommended","github>SpiceLabsHQ/.github"]}'

check yes "preset pinned to a branch" \
  '{"extends":["github>SpiceLabsHQ/.github#main"]}'

check yes "local> shorthand" \
  '{"extends":["local>SpiceLabsHQ/.github"]}'

check yes "owner casing differs" \
  '{"extends":["github>spicelabshq/.github"]}'

# --- off-preset ------------------------------------------------------------
check no "config:recommended only (the DEV-1150 seed)" \
  '{"extends":["config:recommended"],"enabledManagers":["github-actions"]}'

check no "no extends key at all" \
  '{"$schema":"https://docs.renovatebot.com/renovate-schema.json"}'

check no "empty extends array" \
  '{"extends":[]}'

# Fixture 7 — the false-positive guard. This is the shape the preset-less seed
# actually had: config:recommended PLUS a packageRule naming SpiceLabsHQ/.github
# as a package. A substring match would call this compliant. It is not.
check no "matchPackageNames names the repo but extends does not" \
  '{"extends":["config:recommended"],"packageRules":[{"matchManagers":["github-actions"],"matchPackageNames":["SpiceLabsHQ/.github**"],"versioning":"semver"}]}'

check no "near-miss repo name" \
  '{"extends":["github>SpiceLabsHQ/.github-other"]}'

check no "different org, same repo name" \
  '{"extends":["github>SomeoneElse/.github"]}'

# --- json5 / commented configs (jq cannot parse; fallback path) -------------
check yes "json5 with a comment, on-preset" \
  '{ /* org preset */ "extends": ["github>SpiceLabsHQ/.github"] }'

check no "json5 with a comment, off-preset" \
  '{ /* nothing org-wide */ "extends": ["config:recommended"] }'

check no "json5 comment mentioning the preset outside extends" \
  '{ /* see github>SpiceLabsHQ/.github */ "extends": ["config:recommended"] }'

# --- result ----------------------------------------------------------------
printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ] || exit 1
