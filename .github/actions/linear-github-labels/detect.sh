#!/usr/bin/env bash
# Reusable-workflow detection, kept in its own sourceable file so the fixture
# test exercises the EXACT function that runs in production (see test/detect_test.sh).
#
# A reusable workflow is one whose `on:` block declares workflow_call. Comments
# are stripped first so a mention in prose (or a commented-out block) can't
# produce a false positive. Both the block form and the inline-list form are
# recognized:
#
#   on:                    on: [workflow_call, push]
#     workflow_call:
#
# This is a deliberate text heuristic rather than a YAML parse: the runner is
# guaranteed to have bash/grep/sed, but not a YAML processor.
#
# The block-form pattern is deliberately IDENTICAL to `reusable_workflows()` in
# scripts/sync-workflow-checksums.sh, which is this repo's canonical definition
# of a reusable workflow and is CI-enforced 1:1 against the release-please
# inventory. Keep the two in step: if that regex changes, change this one. They
# can't share code — that one greps local files, this one takes file content
# fetched over the API from a possibly-remote repo.

# is_reusable_workflow <workflow-yaml-text> -> 0 if reusable, 1 otherwise
is_reusable_workflow() {
  local stripped
  stripped="$(sed 's/#.*$//' <<<"$1")"
  grep -Eq '^[[:space:]]+workflow_call:' <<<"$stripped" && return 0
  grep -Eq '^[[:space:]]*on:[[:space:]]*\[[^]]*workflow_call' <<<"$stripped" && return 0
  return 1
}
