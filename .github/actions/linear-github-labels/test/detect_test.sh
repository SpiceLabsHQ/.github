#!/usr/bin/env bash
# Fixture test for is_reusable_workflow() — the heuristic that decides which
# workflow files become `org-actions` labels. Sources the production function
# from detect.sh so it can't drift.
#
# Run locally:  .github/actions/linear-github-labels/test/detect_test.sh
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../detect.sh
. "${HERE}/../detect.sh"

fails=0

# expect <want:yes|no> <case-name> <yaml>
expect() {
  local want="$1" name="$2" yaml="$3" got
  if is_reusable_workflow "$yaml"; then got="yes"; else got="no"; fi
  if [ "$got" = "$want" ]; then
    echo "PASS: ${name} (${got})"
  else
    echo "FAIL: ${name} — want '${want}', got '${got}'"
    fails=$((fails+1))
  fi
}

expect yes "block form" "$(cat <<'YAML'
name: SAST
on:
  workflow_call:
    inputs:
      config:
        type: string
YAML
)"

expect yes "block form alongside other triggers" "$(cat <<'YAML'
on:
  push:
    branches: [main]
  workflow_call:
YAML
)"

expect yes "block form with inline value" "$(cat <<'YAML'
on:
  workflow_call: {}
YAML
)"

expect yes "inline list form" "$(cat <<'YAML'
name: Thing
on: [workflow_call, push]
YAML
)"

expect no "caller referencing a reusable workflow" "$(cat <<'YAML'
name: CI Floor — SAST
on:
  pull_request:
jobs:
  sast:
    uses: SpiceLabsHQ/.github/.github/workflows/sast.yml@sast-v1
YAML
)"

expect no "workflow_call only in a comment" "$(cat <<'YAML'
# This workflow deliberately does NOT expose workflow_call:
# see the ADR for why.
on:
  schedule:
    - cron: "0 6 * * *"
YAML
)"

expect no "commented-out trigger block" "$(cat <<'YAML'
on:
  push:
#  workflow_call:
YAML
)"

expect no "plain scheduled workflow" "$(cat <<'YAML'
on:
  schedule:
    - cron: "37 6 * * *"
  workflow_dispatch:
YAML
)"

if [ "$fails" -eq 0 ]; then
  echo "All detect.sh cases passed."
  exit 0
fi
echo "${fails} detect.sh assertion(s) failed."
exit 1
