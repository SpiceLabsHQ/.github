#!/usr/bin/env bash
# Maintains and checks the per-workflow release-please routing invariant.
#
# Why workflows/<name>/ exists: release-please routes commits to packages by
# DIRECTORY path prefix (see src/util/commit-split.ts upstream), but GitHub
# requires every reusable workflow to live flat in .github/workflows/. The
# package directory is the bridge: any commit that changes
# .github/workflows/<name>.yml must ALSO touch a file under workflows/<name>/,
# or release-please never assigns the commit to that workflow's package — no
# release PR, no changelog entry, no tag, and every consumer pinned to the
# moving tag alias silently keeps the old behavior.
#
# A workflow's behavior can also live outside its YAML. pepper-pr-review reads
# its review prompts from prompts/ at the release commit, so a prompt-only edit
# needs the same bridge or it never reaches a caller pinned to the moving tag
# alias (DEV-637). Those files are declared in workflow_asset_patterns() below,
# count as changes to the workflow for routing purposes, and are hashed into the
# same checksum file.
#
# What workflow.sha256 is, and what it is NOT (DEV-1311):
#
#   It is the AFFORDANCE a human uses to satisfy the routing invariant when
#   editing a workflow by hand: run this script with no arguments, the checksum
#   file changes, the commit lands inside workflows/<name>/, and release-please
#   routes it. That is its entire job.
#
#   Nothing ever READS the value.
#   `git grep -n "workflow.sha256" -- . ':!workflows/*/workflow.sha256'` finds
#   only this writer, the CI caller, and prose. It is a routing shim, not an
#   integrity artifact.
#
#   Its value is therefore NOT globally enforced. The PR gate is
#   `--check-routing`, which asks only whether this PR's diff routes; it never
#   hashes anything. So a workflow.sha256 MAY sit permanently stale on main —
#   most likely for a workflow whose most recent change was a Renovate action
#   bump that routed via some other file in the package directory. That is
#   harmless and expected, not a bug: do not "fix" it by making the hash
#   comparison a PR gate again. Whole-repo drift is exactly what made one stale
#   checksum on main fail every unrelated open PR (DEV-726).
#
#   `--check` keeps the whole-repo hash view for a human who wants it, and for
#   any future non-blocking drift report.
#
# Usage:
#   scripts/sync-workflow-checksums.sh          # rewrite checksum files in place
#   scripts/sync-workflow-checksums.sh --check  # whole-repo hash view; exit 1 on drift
#   git diff --name-only "origin/$base...HEAD" |
#     scripts/sync-workflow-checksums.sh --check-routing   # the PR gate
#
# Requirements: git, sha256sum or shasum. `--check` and `--check-routing`
# additionally need jq to validate release-please-config.json /
# .release-please-manifest.json coverage.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

MODE=sync
case "${1:-}" in
  --check) MODE=check ;;
  --check-routing) MODE=check-routing ;;
  -h|--help)
    # The header comment block IS the help text, so the two cannot drift.
    awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"
    exit 0
    ;;
  "") ;;
  *)
    echo "Unknown argument: $1" >&2
    exit 2
    ;;
esac

sha256() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

# A workflow is "reusable" iff it declares a workflow_call trigger at the start
# of a line (repo-local workflows like pepper-self-review.yml never do; comments
# are indented or prefixed with '#', so they can't false-positive).
#
# Note this reads the WORKING TREE, i.e. the PR head. A workflow the PR deletes
# is not listed, which is what makes a delete behave correctly under
# --check-routing — see the routing loop below.
reusable_workflows() {
  grep -lE '^[[:space:]]+workflow_call:' .github/workflows/*.yml | sort
}

# Files outside .github/workflows/<name>.yml whose content a workflow ships as
# behavior, and which must therefore route to its release package too.
#
# Declared as GLOB PATTERNS rather than as a list of existing files because
# --check-routing has to classify paths the PR DELETED, which are no longer on
# disk to be globbed.
workflow_asset_patterns() {
  case "$1" in
    pepper-pr-review)
      # The review prompts, the DEV-674 post-verdict outcome-collapse programs,
      # and the DEV-653 audit-record programs. All are fetched by the workflow
      # from THIS repo at `job.workflow_sha` and all are behavior a caller pinned
      # to the moving tag alias only receives via a release — so an edit to any
      # of them has to route a commit to this package, exactly like a change to
      # the YAML itself. For the audit programs that also keeps the record schema
      # pinned to the workflow version a consumer is on, so a series does not
      # change shape underneath an in-flight comparison.
      printf '%s\n' \
        'prompts/*.md' \
        'scripts/pepper-bot-outcome-collapse.sh' \
        'scripts/pepper-bot-outcome-collapse-decide.jq' \
        'scripts/pepper-audit-record.sh' \
        'scripts/pepper-audit-record.jq' \
        'scripts/pepper-audit-collect.jq'
      ;;
  esac
}

# The declared assets that exist right now, sorted — the set hashed into the
# checksum file.
workflow_assets() {
  local pattern asset
  while IFS= read -r pattern; do
    # Unquoted on purpose: $pattern is a glob to expand here. A pattern that
    # matches nothing expands to itself and is filtered out by the -f test.
    # shellcheck disable=SC2086
    for asset in $pattern; do
      if [ -f "$asset" ]; then
        printf '%s\n' "$asset"
      fi
    done
  done < <(workflow_asset_patterns "$1") | sort
}

errors=0
fail() {
  echo "ERROR: $1" >&2
  errors=$((errors + 1))
}

# --- the diff (--check-routing only) ----------------------------------------
# The changed paths arrive on stdin, one per line — exactly
# `git diff --name-only <merge-base>...HEAD`. The script deliberately does not
# shell out to git: the caller already knows the merge base, and taking the list
# as data keeps every case in scripts/test/sync-workflow-checksums_test.sh a
# handful of strings instead of a synthetic history.
changed=()
if [ "$MODE" = check-routing ]; then
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    changed+=("$path")
  done
  # A pull request always changes something, so an empty list means the caller's
  # merge base was wrong or its checkout was too shallow. Refuse to pass
  # vacuously — a gate that is silently green is worse than no gate at all.
  if [ "${#changed[@]}" -eq 0 ]; then
    echo "ERROR: --check-routing read no changed paths on stdin; expected the output of 'git diff --name-only <merge-base>...HEAD'" >&2
    exit 2
  fi
fi

# The first changed path that is this workflow's YAML or one of its declared
# assets, or empty if this PR does not touch the workflow at all.
routing_trigger() {
  local name="$1" path pattern
  local patterns=()
  while IFS= read -r pattern; do
    [ -n "$pattern" ] || continue
    patterns+=("$pattern")
  done < <(workflow_asset_patterns "$name")

  for path in ${changed[@]+"${changed[@]}"}; do
    if [ "$path" = ".github/workflows/$name.yml" ]; then
      printf '%s\n' "$path"
      return
    fi
    for pattern in ${patterns[@]+"${patterns[@]}"}; do
      # shellcheck disable=SC2254  # $pattern is a glob to match with, not a literal
      case "$path" in
        $pattern)
          printf '%s\n' "$path"
          return
          ;;
      esac
    done
  done
}

# True if this PR already puts a file inside the workflow's package directory,
# which is all release-please needs to route the commit. ANY file counts — the
# checksum, version.txt, the changelog — because routing is by directory prefix
# and the file's content is never consulted.
routes_to() {
  local name="$1" path
  for path in ${changed[@]+"${changed[@]}"}; do
    case "$path" in
      "workflows/$name/"*) return 0 ;;
    esac
  done
  return 1
}

names=()
while IFS= read -r file; do
  name="$(basename "$file" .yml)"
  names+=("$name")
  dir="workflows/$name"

  if [ "$MODE" = check-routing ]; then
    # A workflow the PR DELETED never reaches here: reusable_workflows() reads
    # the PR head, where the YAML is already gone. That is the right behavior —
    # a delete that also removes workflows/<name>/ is a complete change with
    # nothing left to route, and a delete that strands the package directory is
    # reported once, by the orphan check below, instead of twice in two
    # different vocabularies. A RENAME is those two halves: the old name is gone
    # from the head and belongs to the orphan check, the new name is present
    # here and must route like any other new workflow.
    trigger="$(routing_trigger "$name")"
    [ -n "$trigger" ] || continue
    routes_to "$name" && continue
    fail "$trigger is in this PR but no file under $dir/ is — release-please routes commits to packages by directory path, so this commit would not reach the $name package (no release PR, no changelog entry, no tag). Run scripts/sync-workflow-checksums.sh and commit the updated $dir/workflow.sha256"
    continue
  fi

  expected="$(sha256 "$file")  $file"
  while IFS= read -r asset; do
    [ -n "$asset" ] || continue
    expected+=$'\n'"$(sha256 "$asset")  $asset"
  done < <(workflow_assets "$name")

  if [ "$MODE" = check ]; then
    if [ ! -f "$dir/workflow.sha256" ]; then
      fail "$dir/workflow.sha256 is missing — run scripts/sync-workflow-checksums.sh"
    elif [ "$(cat "$dir/workflow.sha256")" != "$expected" ]; then
      fail "$dir/workflow.sha256 is stale — $file or a file it ships changed; run scripts/sync-workflow-checksums.sh and commit the result"
    fi
  else
    mkdir -p "$dir"
    printf '%s\n' "$expected" > "$dir/workflow.sha256"
    echo "synced $dir/workflow.sha256"
  fi
done < <(reusable_workflows)

# Orphan package dirs: a workflows/<name>/ with no matching reusable workflow
# means the workflow was renamed or deleted without cleaning up its package.
# Whole-repo by necessity — no per-PR diff can express "nothing anywhere in the
# tree claims this directory".
for dir in workflows/*/; do
  [ -d "$dir" ] || continue
  name="$(basename "$dir")"
  if [ ! -f ".github/workflows/$name.yml" ] || ! printf '%s\n' "${names[@]}" | grep -qx "$name"; then
    fail "workflows/$name/ has no matching reusable workflow at .github/workflows/$name.yml — remove the dir and its release-please config/manifest entries (or restore the workflow)"
  fi
done

if [ "$MODE" != sync ]; then
  # Every reusable workflow must be registered in the release-please config and
  # manifest, and vice versa — otherwise its releases silently never happen.
  # Whole-repo for the same reason as the orphan check: it is an inventory
  # comparison, not a property of one PR's diff.
  command -v jq >/dev/null 2>&1 || { echo "ERROR: jq is required for --check and --check-routing" >&2; exit 2; }

  config_keys="$(jq -r '.packages | keys[]' release-please-config.json | sort)"
  manifest_keys="$(jq -r 'keys[]' .release-please-manifest.json | sort)"
  expected_keys="$(printf 'workflows/%s\n' "${names[@]}" | sort)"

  if [ "$config_keys" != "$expected_keys" ]; then
    fail "release-please-config.json packages do not match the reusable workflow inventory:
$(diff <(echo "$expected_keys") <(echo "$config_keys") | sed 's/^/  /' || true)"
  fi
  if [ "$manifest_keys" != "$expected_keys" ]; then
    fail ".release-please-manifest.json keys do not match the reusable workflow inventory:
$(diff <(echo "$expected_keys") <(echo "$manifest_keys") | sed 's/^/  /' || true)"
  fi

  if [ "$errors" -gt 0 ]; then
    echo "" >&2
    echo "$errors versioning-integrity error(s). Fix: run scripts/sync-workflow-checksums.sh, register new workflows in release-please-config.json + .release-please-manifest.json, and commit." >&2
    exit 1
  fi
  if [ "$MODE" = check ]; then
    echo "OK: checksums, package dirs, release-please config and manifest are all in sync."
  else
    echo "OK: every reusable workflow this PR touches also has a file in its package dir; package dirs, release-please config and manifest are in sync."
  fi
fi
