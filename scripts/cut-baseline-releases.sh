#!/usr/bin/env bash
# One-time DEV-408 migration step: cuts the baseline per-workflow releases.
#
# For every reusable workflow (workflows/<name>/ package) this script:
#   1. Creates the immutable release <name>-v1.0.0 (tag + GitHub Release) at
#      the given commit — the anchor release-please bumps from
#   2. Creates/moves the floating major alias <name>-v1 to the same commit
#
# Run this ONCE, immediately after the DEV-408 migration PR merges, pointed at
# the merge commit on main. Until it runs, release-please has no per-workflow
# tags to anchor on and consumers have no per-workflow refs to migrate to.
#
# Skips any workflow whose <name>-v1.0.0 tag already exists, so it is safe to
# re-run after a partial failure.
#
# Usage:
#   scripts/cut-baseline-releases.sh                 # dry-run against origin/main HEAD
#   scripts/cut-baseline-releases.sh --apply         # actually create tags + releases
#   scripts/cut-baseline-releases.sh --apply --ref <sha>   # explicit commit
#
# Requirements: gh (authenticated with push + release rights), git.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

REPO="SpiceLabsHQ/.github"
DRY_RUN=true
REF=""

while [ $# -gt 0 ]; do
  case "$1" in
    --apply) DRY_RUN=false; shift ;;
    --ref) REF="$2"; shift 2 ;;
    -h|--help)
      sed -n '2,21p' "$0"
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      exit 2
      ;;
  esac
done

git fetch origin --tags --quiet
if [ -z "$REF" ]; then
  REF="$(git rev-parse origin/main)"
fi
SHA="$(git rev-parse "$REF")"

# The baseline commit must contain the per-workflow package dirs, otherwise
# release-please and the alias workflow have nothing to work with.
if ! git cat-file -e "${SHA}:workflows" 2>/dev/null; then
  echo "ERROR: ${SHA} does not contain the workflows/ package dirs — point --ref at the DEV-408 merge commit (or later)." >&2
  exit 1
fi

existing_tags="$(git ls-remote --tags origin | awk '{print $2}' | sed 's|refs/tags/||')"

for dir in workflows/*/; do
  name="$(basename "$dir")"
  tag="${name}-v1.0.0"
  alias="${name}-v1"

  if printf '%s\n' "$existing_tags" | grep -qx "$tag"; then
    echo "skip   $tag (already exists)"
    continue
  fi

  if $DRY_RUN; then
    echo "would  create release $tag + alias $alias at $SHA"
    continue
  fi

  echo "create $tag + $alias at $SHA"
  gh release create "$tag" \
    --repo "$REPO" \
    --target "$SHA" \
    --title "$name v1.0.0" \
    --notes "Baseline per-workflow release (DEV-408). Functionally identical to the legacy shared \`v1\` tag at this commit. Pin with \`@${tag}\` (immutable), \`@${alias}\` (floating major), or the commit SHA. See the README's *Versioning & releases* section."
  git push --force origin "${SHA}:refs/tags/${alias}"
done

if $DRY_RUN; then
  echo ""
  echo "Dry-run only. Re-run with --apply to create the tags and releases."
fi
