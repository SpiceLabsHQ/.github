#!/usr/bin/env bash
# Rolls out the centralized Claude PR review caller workflow to SpiceLabsHQ repos.
#
# For each target repo this script will:
#   1. Skip if .github/workflows/claude.yml already exists on the default branch
#   2. Create a branch, commit the caller workflow, push, open a PR
#
# Usage:
#   scripts/rollout-claude-review.sh                      # dry-run across all non-archived org repos
#   scripts/rollout-claude-review.sh --apply              # actually open PRs
#   scripts/rollout-claude-review.sh --apply repo1 repo2  # only the named repos
#
# Requirements: gh (authenticated), git, jq.

set -euo pipefail

ORG="SpiceLabsHQ"
CALLER_TEMPLATE="$(cd "$(dirname "$0")/.." && pwd)/examples/caller-claude-pr-review.yml"
TARGET_PATH=".github/workflows/claude.yml"
BRANCH="chore/centralize-claude-pr-review"
COMMIT_MSG="chore: adopt centralized Claude PR review workflow"
PR_TITLE="Adopt centralized Claude PR review workflow"
PR_BODY=$(cat <<'EOF'
Adds a thin caller for the reusable Claude PR review workflow maintained in
[SpiceLabsHQ/.github](https://github.com/SpiceLabsHQ/.github).

- Auto-reviews on PR open and `ready_for_review`.
- On-demand review by mentioning `@claude` in a PR comment.
- Add `.claude/pr-review-standards.md` to layer in repo-specific standards.

Tracking: DEV-210
EOF
)

DRY_RUN=true
TARGETS=()

for arg in "$@"; do
  case "$arg" in
    --apply) DRY_RUN=false ;;
    -h|--help)
      sed -n '2,15p' "$0"
      exit 0
      ;;
    *) TARGETS+=("$arg") ;;
  esac
done

if [ ! -f "$CALLER_TEMPLATE" ]; then
  echo "Caller template not found at $CALLER_TEMPLATE" >&2
  exit 1
fi

if [ ${#TARGETS[@]} -eq 0 ]; then
  mapfile -t TARGETS < <(
    gh repo list "$ORG" --limit 1000 --no-archived \
      --json name,isFork \
      --jq '.[] | select(.isFork == false) | .name'
  )
fi

echo "Rollout mode: $([ "$DRY_RUN" = true ] && echo 'DRY RUN' || echo 'APPLY')"
echo "Targets (${#TARGETS[@]}): ${TARGETS[*]}"
echo

WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR"' EXIT

for repo in "${TARGETS[@]}"; do
  echo "── $ORG/$repo ──"

  if [ "$repo" = ".github" ]; then
    echo "  skip: this is the host repo for the reusable workflow"
    continue
  fi

  if gh api "repos/$ORG/$repo/contents/$TARGET_PATH" >/dev/null 2>&1; then
    echo "  skip: $TARGET_PATH already exists"
    continue
  fi

  if [ "$DRY_RUN" = true ]; then
    echo "  would: clone, add $TARGET_PATH, push branch '$BRANCH', open PR"
    continue
  fi

  clone_dir="$WORKDIR/$repo"
  gh repo clone "$ORG/$repo" "$clone_dir" -- --depth=1 --quiet
  pushd "$clone_dir" >/dev/null

  git checkout -b "$BRANCH"
  mkdir -p "$(dirname "$TARGET_PATH")"
  cp "$CALLER_TEMPLATE" "$TARGET_PATH"
  git add "$TARGET_PATH"
  git commit -m "$COMMIT_MSG" --quiet
  git push --set-upstream origin "$BRANCH" --quiet

  gh pr create \
    --title "$PR_TITLE" \
    --body "$PR_BODY" \
    --base main \
    --head "$BRANCH"

  popd >/dev/null
done

echo
echo "Done."
