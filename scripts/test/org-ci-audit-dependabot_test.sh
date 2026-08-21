#!/usr/bin/env bash
# Fixture test for dependabot_state_from_response() in scripts/org-ci-audit.sh —
# the decision behind the audit dashboard's `Dep-alerts` column (DEV-1142).
#
# WHY THIS EXISTS: the column reports whether a repo has Dependabot alerts on,
# which is what the org Renovate preset's `vulnerabilityAlerts` carve-out reads
# from. With alerts off the carve-out matches nothing, a CVE fix waits out the
# full 7-day `minimumReleaseAge`, and GitHub Actions CVEs are not covered at all
# (OSV has no `github-tags` ecosystem). None of that fails loudly anywhere — it
# is a security guarantee that is simply absent — so the dashboard is the only
# place it surfaces, and the audit runs weekly against the live org where a
# defect shows up as a dashboard quietly saying the wrong thing, not a red PR.
#
# THE LOAD-BEARING CASES ARE THE `unknown` ONES. The audit's App token may not
# be able to read the field at all, and GraphQL reports that as an `errors`
# block with `data.repository` null. If that ever collapses to `off`, every repo
# in the org lights up as a security gap on the same run — the fix gets spent on
# repos that were already fine, and the real gaps lose credibility by
# association. Fixtures 4-8 are what stop that.
#
# To test the EXACT function that ships without duplicating it, this harness
# extracts the function definition from the shipping script and sources it. The
# function is pure (jq/printf, no globals, no network), which is why it can be
# tested this way; `dependabot_state` around it is not covered here because it
# calls the GitHub API and CI has no org-scoped token.
#
# Run locally:  scripts/test/org-ci-audit-dependabot_test.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AUDIT="${HERE}/../org-ci-audit.sh"

[ -r "${AUDIT}" ] || { echo "FAIL: cannot read ${AUDIT}" >&2; exit 1; }

command -v jq >/dev/null || { echo "jq not found" >&2; exit 2; }

# Extract the function definition from the shipping script and source it. If it
# is ever renamed or reshaped, this fails loudly rather than silently testing
# nothing.
FN="$(awk '/^dependabot_state_from_response\(\) \{$/,/^\}$/' "${AUDIT}")"
if [ -z "${FN}" ]; then
  echo "FAIL: could not extract dependabot_state_from_response() from ${AUDIT}" >&2
  echo "      (was it renamed? update this harness alongside, consciously)" >&2
  exit 1
fi
eval "${FN}"

pass=0
fail=0

# check <expected: on|off|unknown> <description> <graphql-response>
check() {
  local expected="$1" desc="$2" response="$3" got
  got="$(dependabot_state_from_response "${response}")"
  if [ "${got}" = "${expected}" ]; then
    pass=$((pass + 1))
    printf 'ok   %s\n' "${desc}"
  else
    fail=$((fail + 1))
    printf 'FAIL %s\n     expected=%s got=%s\n     response: %s\n' \
      "${desc}" "${expected}" "${got}" "${response}"
  fi
}

# --- definite answers ------------------------------------------------------
check on "alerts enabled" \
  '{"data":{"repository":{"hasVulnerabilityAlertsEnabled":true}}}'

check off "alerts disabled" \
  '{"data":{"repository":{"hasVulnerabilityAlertsEnabled":false}}}'

# --- the unknowns: everything that is NOT a definite `false` ---------------
# The permission case. GraphQL answers a field the token cannot read with an
# errors block AND a null repository — so a reader that only looked at `.data`
# would see "no alerts" and report a gap that does not exist.
check unknown "errors block with a null repository (no permission)" \
  '{"data":{"repository":null},"errors":[{"type":"FORBIDDEN","message":"Resource not accessible by integration"}]}'

# A partial GraphQL response carries real data alongside an error. It is still
# not an answer about this field, so it must not be read as one.
check unknown "errors block alongside a populated repository" \
  '{"data":{"repository":{"hasVulnerabilityAlertsEnabled":false}},"errors":[{"message":"partial"}]}'

check unknown "repository null with no errors block (repo not visible)" \
  '{"data":{"repository":null}}'

check unknown "field absent from the response" \
  '{"data":{"repository":{}}}'

# gh exiting non-zero leaves the response empty; that is the shape the network
# wrapper hands over on any transport failure, and it must not read as `off`.
check unknown "empty response (gh failed or returned nothing)" \
  ''

check unknown "unparseable response (HTML error page, rate-limit body)" \
  '<html><body>502 Bad Gateway</body></html>'

# `null` for the field itself, which GraphQL returns for a nullable field the
# viewer cannot resolve.
check unknown "field explicitly null" \
  '{"data":{"repository":{"hasVulnerabilityAlertsEnabled":null}}}'

# A JSON string "false" is not a boolean false. Anything that is not the literal
# boolean is an answer we did not understand, not a negative one.
check unknown "field is the string \"false\", not the boolean" \
  '{"data":{"repository":{"hasVulnerabilityAlertsEnabled":"false"}}}'

echo
if [ "${fail}" -eq 0 ]; then
  echo "All $((pass)) Dependabot-alerts cases passed."
else
  echo "${fail} of $((pass + fail)) Dependabot-alerts cases FAILED." >&2
  exit 1
fi
