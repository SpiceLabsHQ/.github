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
# What workflows/<name>/pins.yml is (DEV-1313):
#
#   The checksum above is the affordance a HUMAN uses to satisfy the routing
#   invariant. pins.yml is the affordance a BOT uses, and it works without
#   anyone touching the PR.
#
#   Renovate is pointed at workflows/*/pins.yml by managerFilePatterns in
#   .github/renovate.json, so it manages the same action refs in two places: the
#   workflow YAML and this mirror inside the package directory. Nothing syncs
#   those two files to each other at bump time — each occurrence is independently
#   managed, so one bump PR edits both, and the bot's own commit therefore
#   contains a file under workflows/<name>/ and routes. Without it a bump would
#   touch only .github/workflows/<name>.yml, reach no package, cut no release,
#   and leave every repo pinned to the moving <name>-vN alias on the old action.
#
#   Completeness is the whole point: pins.yml must mirror every `uses:` ref
#   Renovate can bump, not just the SHA-pinned third-party ones. A first-party
#   `actions/checkout@v7` is bumpable too (v7 -> v8), and an omission there is a
#   silent hole that only surfaces as a red --check-routing on some future bot
#   PR. See workflow_uses() for the extraction rule and what it deliberately
#   drops.
#
#   Enforcement lives in --check, never in --check-routing. A stale or
#   hand-edited pins.yml is whole-repo drift, and DEV-726 is the standing lesson
#   about letting whole-repo drift fail PRs that touched none of it. A MISSING
#   pins.yml is only a warning: it degrades to the pre-DEV-1313 world, where the
#   consequence is caught loudly by --check-routing on the bot PR itself.
#
# Usage:
#   scripts/sync-workflow-checksums.sh          # rewrite checksum + pins files in place
#   scripts/sync-workflow-checksums.sh --check  # whole-repo hash/pins view; exit 1 on drift
#   git diff --name-only "origin/$base...HEAD" |
#     scripts/sync-workflow-checksums.sh --check-routing   # the PR gate
#
# Requirements: sha256sum or shasum. The script never invokes git — the diff
# arrives as data on stdin, which is what lets the fixture tests drive every
# case with plain path lists. `--check` and `--check-routing` additionally need
# jq to validate release-please-config.json / .release-please-manifest.json
# coverage.

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

# --- pins.yml (DEV-1313) ----------------------------------------------------

# The `uses:` refs Renovate can bump in a workflow, deduplicated and sorted.
#
# This deliberately mirrors Renovate's github-actions manager, which extracts
# with a LINE regex and never parses the YAML (verified against Renovate 44.39.1
# in DEV-1310):
#
#   /^(?<prefix>\s+(?:-\s+)?uses\s*:\s*)(?<remainder>.+)$/
#
# Two consequences are load-bearing:
#
#   * The leading whitespace is REQUIRED. A `uses:` in column 0 is silently NOT
#     extracted. That is why render_pins() indents its steps, and why matching
#     the same rule here keeps pins.yml a mirror of exactly the set Renovate
#     sees in the workflow — no more, no less.
#   * YAML structure is irrelevant, and so is anything that merely CONTAINS
#     "uses:". actions-audit.yml is full of shell strings and comments that do
#     ("echo \"  uses: owner/repo@<sha>\""); none of them match, because the
#     line has to START with `uses:` after its indent.
#
# The remainder is copied VERBATIM — SHA, trailing `# vX.Y.Z` comment, quoting
# and all — because Renovate rewrites that whole remainder in both files, and a
# reformatting here would show up as permanent drift.
#
# Dropped: local refs (`uses: ./.github/actions/foo`). They name a path in this
# repo, carry no version and resolve to no datasource, so Renovate can never
# open a bump PR for one and there is no commit for it to route. Every other
# form is kept, including subpaths (`github/codeql-action/init@v4`), first-party
# major tags (`actions/checkout@v7`) and `docker://` refs — all of which
# Renovate does bump.
workflow_uses() {
  awk '
    match($0, /^[[:space:]]+(-[[:space:]]+)?uses[[:space:]]*:[[:space:]]*/) {
      ref = substr($0, RSTART + RLENGTH)
      sub(/[[:space:]]+$/, "", ref)
      if (ref == "" || ref ~ /^\.\.?\//) next
      print ref
    }
  ' "$1" | LC_ALL=C sort -u
}

# The exact intended content of workflows/<name>/pins.yml, on stdout. Sync
# writes it; --check compares against it. One producer, so the two can't drift.
render_pins() {
  local name="$1" uses ref
  uses="$(workflow_uses ".github/workflows/$name.yml")"

  cat <<EOF
# GENERATED FILE — do not edit by hand.
# Written by scripts/sync-workflow-checksums.sh from .github/workflows/$name.yml.
#
# GitHub Actions never executes this file, and nothing here affects what
# $name.yml does. It exists so Renovate has something to edit INSIDE
# workflows/$name/ when it bumps an action $name.yml references. release-please
# routes commits to packages by directory path, so a bump touching only the
# workflow YAML would reach no package — no release, no tag, and every repo
# pinned to the moving $name-vN alias would keep the old action. Renovate is
# pointed here by managerFilePatterns in .github/renovate.json and manages each
# ref below independently of its twin in the workflow, which is why a single
# bump PR updates both files.
#
# The composite-action shape is what Renovate's github-actions manager reads
# most cleanly; the indentation on each step is required, because Renovate does
# not extract a \`uses:\` written in column 0.
runs:
  using: composite
EOF

  if [ -z "$uses" ]; then
    # A workflow with no bumpable ref still gets a file, so the package
    # directory's shape never depends on today's action inventory. `steps: []`
    # and not the jobs:/runs-on: shape: that one manufactures a phantom `ubuntu`
    # runner dependency out of a workflow that has no dependencies at all.
    printf '  steps: []\n'
    return
  fi

  printf '  steps:\n'
  while IFS= read -r ref; do
    printf '    - uses: %s\n' "$ref"
  done <<<"$uses"
}

# Package directory names config:recommended's ignorePaths would make Renovate
# skip. workflows/<name>/pins.yml sits under <name>, so a workflow named any of
# these has a pins.yml Renovate silently never reads — its bumps stop routing
# with no error anywhere. Nothing collides today; this is here because the
# failure would be invisible and the check costs nothing.
renovate_ignores_name() {
  case "$1" in
    node_modules|bower_components|vendor|examples|__tests__|test|tests|__fixtures__)
      return 0
      ;;
  esac
  return 1
}

errors=0
fail() {
  echo "ERROR: $1" >&2
  errors=$((errors + 1))
}

warnings=0
warn() {
  echo "WARNING: $1" >&2
  warnings=$((warnings + 1))
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

    # A MISSING pins.yml is a warning, not an error, for two reasons. It is the
    # intended interim state between DEV-1313 (this generator) and DEV-1314
    # (which commits the twelve files), and making it fatal would have broken
    # --check on main for everyone in between. And on its own merits: no
    # pins.yml just means Renovate manages that workflow's actions in one place
    # instead of two, which is the pre-DEV-1313 world — a bump then fails
    # --check-routing on the bot PR, loudly, rather than slipping through.
    #
    # A pins.yml that DISAGREES with its workflow is the dangerous state and is
    # an error: it routes (any file in the package dir does), so the PR gate
    # goes green while Renovate is bumping refs the workflow no longer has, or
    # missing refs it does.
    if [ ! -f "$dir/pins.yml" ]; then
      warn "$dir/pins.yml is missing — Renovate action bumps for $name will not route on their own; run scripts/sync-workflow-checksums.sh"
    elif [ "$(cat "$dir/pins.yml")" != "$(render_pins "$name")" ]; then
      fail "$dir/pins.yml disagrees with $file — it is generated, not hand-edited; run scripts/sync-workflow-checksums.sh and commit the result"
    fi

    if renovate_ignores_name "$name"; then
      fail "workflows/$name/ matches an ignorePaths entry inherited from config:recommended, so Renovate never reads $dir/pins.yml and bumps to $file would stop routing — rename the workflow, or override ignorePaths in .github/renovate.json"
    fi
  else
    mkdir -p "$dir"
    printf '%s\n' "$expected" > "$dir/workflow.sha256"
    echo "synced $dir/workflow.sha256"
    render_pins "$name" > "$dir/pins.yml"
    echo "synced $dir/pins.yml"
    if renovate_ignores_name "$name"; then
      warn "workflows/$name/ matches an ignorePaths entry inherited from config:recommended — Renovate will never read $dir/pins.yml, so bumps to $file will not route"
    fi
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
    if [ "$warnings" -gt 0 ]; then
      echo "OK: nothing is out of sync, but $warnings warning(s) above are worth reading."
    else
      echo "OK: checksums, pins files, package dirs, release-please config and manifest are all in sync."
    fi
  else
    echo "OK: every reusable workflow this PR touches also has a file in its package dir; package dirs, release-please config and manifest are in sync."
  fi
fi
