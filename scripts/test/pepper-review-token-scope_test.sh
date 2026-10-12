#!/usr/bin/env bash
# Pins the permission set of the review job's App token (DEV-2892).
#
# Without `permission-*` inputs, actions/create-github-app-token hands back a
# token carrying every permission the App installation holds, `contents: write`
# included. This test fails if the review job's token step loses its inputs,
# gains a permission nobody listed, or widens one, so a change to the token's
# reach has to be made here on purpose rather than slip in with a new step.
#
# It reads the workflow file; it cannot show GitHub refusing a write. That
# proof comes from a run with the narrowed token (see the PR for DEV-2892).
#
# Needs yq (mikefarah v4), preinstalled on ubuntu-latest.
# Run locally:  scripts/test/pepper-review-token-scope_test.sh
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKFLOW="${1:-${HERE}/../../.github/workflows/pepper-pr-review.yml}"

# The permissions the review job's steps use, and no others. Sorted.
EXPECTED='permission-contents=read
permission-issues=read
permission-members=read
permission-pull-requests=write'

fails=0
fail() { echo "FAIL: $*"; fails=$((fails + 1)); }

STEP='.jobs.review.steps[] | select(.id == "app-token")'

uses="$(yq -r "${STEP} | .uses" "${WORKFLOW}")"
case "${uses}" in
  actions/create-github-app-token@*) echo "PASS: review job mints its token with actions/create-github-app-token" ;;
  *) fail "review job's app-token step uses '${uses}', expected actions/create-github-app-token" ;;
esac

actual="$(yq -r "${STEP} | .with | to_entries | .[] | select(.key | test(\"^permission-\")) | .key + \"=\" + .value" "${WORKFLOW}" | sort)"
if [ "${actual}" = "${EXPECTED}" ]; then
  echo "PASS: review token requests exactly the listed permissions"
else
  fail "review token permissions differ from the expected set"
  echo "    expected:"; sed 's/^/      /' <<<"${EXPECTED}"
  echo "    actual:";   sed 's/^/      /' <<<"${actual:-<none>}"
fi

# `owner` or `repositories` would widen the token beyond the repo under review,
# which the prompt tells Pepper it cannot see past (prompts/pr-review-default.md).
for key in owner repositories; do
  if [ "$(yq -r "${STEP} | .with | has(\"${key}\")" "${WORKFLOW}")" = "true" ]; then
    fail "review token sets '${key}', which widens it beyond the repo under review"
  else
    echo "PASS: review token does not set '${key}'"
  fi
done

if [ "${fails}" -ne 0 ]; then
  echo "${fails} check(s) failed"
  exit 1
fi
echo "All checks passed"
