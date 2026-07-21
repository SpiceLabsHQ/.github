#!/usr/bin/env bash
# Regenerates workflows/<name>/workflow.sha256 for every reusable workflow.
#
# Why these files exist: release-please routes commits to packages by DIRECTORY
# path prefix (see src/util/commit-split.ts upstream), but GitHub requires every
# reusable workflow to live flat in .github/workflows/. The checksum file is the
# bridge: any commit that changes .github/workflows/<name>.yml must also change
# workflows/<name>/workflow.sha256, which routes the commit to that workflow's
# release-please package. CI enforces the invariant via `--check`.
#
# A workflow's behavior can also live outside its YAML. pepper-pr-review reads
# its review prompts from prompts/ at the release commit, so a prompt-only edit
# needs the same bridge or it never reaches a caller pinned to the moving tag
# alias (DEV-637). Those files are declared in workflow_assets() below and
# hashed into the same checksum file.
#
# Usage:
#   scripts/sync-workflow-checksums.sh            # rewrite checksum files in place
#   scripts/sync-workflow-checksums.sh --check    # verify; exit 1 on drift (CI mode)
#
# Requirements: git, sha256sum or shasum. `--check` additionally needs jq to
# validate release-please-config.json / .release-please-manifest.json coverage.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

CHECK=false
case "${1:-}" in
  --check) CHECK=true ;;
  -h|--help)
    sed -n '2,16p' "$0"
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
reusable_workflows() {
  grep -lE '^[[:space:]]+workflow_call:' .github/workflows/*.yml | sort
}

# Files outside .github/workflows/<name>.yml whose content a workflow ships as
# behavior, and which must therefore route to its release package too.
workflow_assets() {
  case "$1" in
    pepper-pr-review)
      for asset in prompts/*.md; do
        [ -f "$asset" ] && printf '%s\n' "$asset"
      done | sort
      ;;
  esac
}

errors=0
fail() {
  echo "ERROR: $1" >&2
  errors=$((errors + 1))
}

names=()
while IFS= read -r file; do
  name="$(basename "$file" .yml)"
  names+=("$name")
  dir="workflows/$name"
  expected="$(sha256 "$file")  $file"
  while IFS= read -r asset; do
    [ -n "$asset" ] || continue
    expected+=$'\n'"$(sha256 "$asset")  $asset"
  done < <(workflow_assets "$name")

  if $CHECK; then
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
for dir in workflows/*/; do
  [ -d "$dir" ] || continue
  name="$(basename "$dir")"
  if [ ! -f ".github/workflows/$name.yml" ] || ! printf '%s\n' "${names[@]}" | grep -qx "$name"; then
    fail "workflows/$name/ has no matching reusable workflow at .github/workflows/$name.yml — remove the dir and its release-please config/manifest entries (or restore the workflow)"
  fi
done

if $CHECK; then
  # Every reusable workflow must be registered in the release-please config and
  # manifest, and vice versa — otherwise its releases silently never happen.
  command -v jq >/dev/null 2>&1 || { echo "ERROR: jq is required for --check" >&2; exit 2; }

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
  echo "OK: checksums, package dirs, release-please config and manifest are all in sync."
fi
