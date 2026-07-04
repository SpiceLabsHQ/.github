#!/usr/bin/env bash
# Migrates SpiceLabsHQ repos off the frozen legacy `@v1` reusable-workflow tag
# onto per-workflow tags, and seeds Dependabot config so future workflow
# releases arrive as reviewable update PRs instead of manual sweeps.
#
# For each target repo this script will:
#   1. Scan .github/workflows/ for `SpiceLabsHQ/.github/.github/workflows/<wf>.yml@v1`
#      (or `@v1.0.0`) and rewrite each pin to `@<wf>-v1` (per-workflow floating major)
#   2. Seed .github/renovate.json (github-actions manager only) if the repo has no
#      Renovate config — inert until the Mend Renovate GitHub App is installed on
#      the org (DEV-494 decision: Renovate over Dependabot; Dependabot mis-handles
#      the component-prefixed tags this org releases)
#   3. Report third-party actions that are not SHA-pinned (flag only, no changes)
#   4. Create a branch, commit, push, open a PR against the repo's default branch
#
# Repos with no legacy pins and an existing Renovate config are skipped.
#
# Usage:
#   scripts/migrate-legacy-v1-pins.sh                      # dry-run across all non-archived org repos
#   scripts/migrate-legacy-v1-pins.sh --apply              # actually open PRs
#   scripts/migrate-legacy-v1-pins.sh --apply repo1 repo2  # only the named repos
#
# Requirements: gh (authenticated), git, jq.

set -euo pipefail

ORG="SpiceLabsHQ"
BRANCH="chore/migrate-legacy-v1-pins"
COMMIT_MSG="chore(ci): migrate reusable workflow pins to per-workflow tags [DEV-494]"
PR_TITLE="Migrate reusable workflow pins off frozen legacy @v1 [DEV-494]"
SEED_COMMIT_MSG="chore(ci): seed Renovate config for GitHub Actions updates [DEV-494]"
SEED_PR_TITLE="Seed Renovate config for GitHub Actions updates [DEV-494]"
read -r -d '' SEED_PR_BODY <<'EOF' || true
Seeds `.github/renovate.json` (github-actions manager only) so GitHub Actions
refs — third-party actions and any
[SpiceLabsHQ/.github](https://github.com/SpiceLabsHQ/.github) reusable-workflow
pins — get update PRs instead of going stale silently. The config is inert until
the Mend Renovate GitHub App is installed on the org. Renovate was chosen over
Dependabot because Dependabot mis-handles the component-prefixed release tags
(`<workflow>-vX.Y.Z`) this org's reusable workflows use (details in DEV-494).
Version-update config cannot be inherited org-wide from the `.github` repo, so
it lives per-repo.

This repo has no legacy `@v1` reusable-workflow pins; this is the
config-seeding half of the DEV-494 sweep only.

Tracking: DEV-494
EOF
read -r -d '' PR_BODY <<'EOF' || true
The org-wide `v1` tag on [SpiceLabsHQ/.github](https://github.com/SpiceLabsHQ/.github)
was frozen at `60a48c1` when reusable workflows moved to per-workflow versioning
(DEV-408). Repos still pinning `@v1` receive **no fixes and no upgrades** — including
the Pepper → Claude Sonnet 5 move (DEV-492).

This PR:
- Rewrites each `SpiceLabsHQ/.github/.github/workflows/<workflow>.yml@v1` pin to the
  per-workflow floating major `@<workflow>-v1`, which advances automatically to the
  latest non-breaking release (never across a major).
- Seeds `.github/renovate.json` (github-actions manager only; inert until the Mend
  Renovate GitHub App is installed on the org) so future workflow majors and
  third-party action updates arrive as reviewable PRs. Renovate over Dependabot
  because Dependabot mis-handles this org's component-prefixed release tags
  (`<workflow>-vX.Y.Z`) — details in DEV-494.

The green run of the migrated workflow on this PR doubles as the live test of the
per-workflow tag in this repo.

Tracking: DEV-494
EOF

RENOVATE_CONFIG='{
  "$schema": "https://docs.renovatebot.com/renovate-schema.json",
  "extends": ["config:recommended"],
  "enabledManagers": ["github-actions"],
  "packageRules": [
    {
      "description": "SpiceLabsHQ reusable workflows: release-please monorepo tags like pepper-pr-review-v1.2.3",
      "matchManagers": ["github-actions"],
      "matchDatasources": ["github-tags"],
      "matchPackageNames": ["SpiceLabsHQ/.github**"],
      "versionCompatibility": "^(?<compatibility>.*)-v(?<version>.*)$",
      "versioning": "semver"
    }
  ]
}'

DRY_RUN=true
TARGETS=()

for arg in "$@"; do
  case "$arg" in
    --apply) DRY_RUN=false ;;
    -h|--help)
      sed -n '2,21p' "$0"
      exit 0
      ;;
    *) TARGETS+=("$arg") ;;
  esac
done

if [ ${#TARGETS[@]} -eq 0 ]; then
  while IFS= read -r name; do
    TARGETS+=("$name")
  done < <(
    gh repo list "$ORG" --limit 1000 --no-archived \
      --json name,isFork \
      --jq '.[] | select(.isFork == false) | .name'
  )
fi

echo "Migration mode: $([ "$DRY_RUN" = true ] && echo 'DRY RUN' || echo 'APPLY')"
echo "Targets (${#TARGETS[@]}): ${TARGETS[*]}"
echo

WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR"' EXIT

PRS=()

for repo in "${TARGETS[@]}"; do
  echo "── $ORG/$repo ──"

  if [ "$repo" = ".github" ]; then
    echo "  skip: this is the host repo for the reusable workflows"
    continue
  fi

  if ! gh api "repos/$ORG/$repo/contents/.github/workflows" >/dev/null 2>&1; then
    echo "  skip: no .github/workflows directory"
    continue
  fi

  default_branch=$(gh api "repos/$ORG/$repo" --jq '.default_branch')

  clone_dir="$WORKDIR/$repo"
  gh repo clone "$ORG/$repo" "$clone_dir" -- --depth=1 --quiet
  pushd "$clone_dir" >/dev/null

  # 1. Rewrite legacy pins
  migrated=false
  legacy_files=()
  while IFS= read -r file; do
    legacy_files+=("$file")
  done < <(grep -rlE "SpiceLabsHQ/\.github/\.github/workflows/[A-Za-z0-9._-]+\.yml@v1(\.0\.0)?([^0-9.]|$)" .github/workflows/ 2>/dev/null || true)

  changed=false
  if [ ${#legacy_files[@]} -gt 0 ]; then
    for file in "${legacy_files[@]}"; do
      grep -nE "SpiceLabsHQ/\.github/\.github/workflows/[A-Za-z0-9._-]+\.yml@v1(\.0\.0)?([^0-9.]|$)" "$file" \
        | sed "s|^|  rewrite: $file:|"
      # `<wf>.yml@v1` / `<wf>.yml@v1.0.0` → `<wf>.yml@<wf>-v1`
      perl -pi -e 's{(SpiceLabsHQ/\.github/\.github/workflows/([A-Za-z0-9._-]+)\.yml)\@v1(\.0\.0)?(?![\w.])}{$1\@$2-v1}g' "$file"
    done
    changed=true
    migrated=true
  else
    echo "  no legacy @v1 pins"
  fi

  # 2. Seed renovate.json if the repo has no Renovate config
  has_renovate=false
  for cfg in renovate.json renovate.json5 .renovaterc .renovaterc.json .renovaterc.json5 \
             .github/renovate.json .github/renovate.json5; do
    [ -f "$cfg" ] && has_renovate=true
  done
  if [ "$has_renovate" = true ]; then
    echo "  renovate config already present"
  else
    echo "  seed: .github/renovate.json"
    printf '%s\n' "$RENOVATE_CONFIG" > .github/renovate.json
    changed=true
  fi

  # 3. Flag third-party actions that are not SHA-pinned (report only)
  grep -rnE '^\s*(-\s*)?uses:\s*[A-Za-z0-9._-]+/[A-Za-z0-9._/-]+@' .github/workflows/ 2>/dev/null \
    | grep -v "SpiceLabsHQ/" \
    | grep -vE '@[0-9a-f]{40}' \
    | sed 's|^|  flag (not SHA-pinned): |' || true

  if [ "$changed" = false ]; then
    echo "  skip: nothing to change"
    popd >/dev/null
    continue
  fi

  if [ "$DRY_RUN" = true ]; then
    echo "  would: commit, push branch '$BRANCH', open PR against '$default_branch'"
    popd >/dev/null
    continue
  fi

  commit_msg="$COMMIT_MSG"; pr_title="$PR_TITLE"; pr_body="$PR_BODY"
  if [ "$migrated" = false ]; then
    commit_msg="$SEED_COMMIT_MSG"; pr_title="$SEED_PR_TITLE"; pr_body="$SEED_PR_BODY"
  fi

  git checkout -b "$BRANCH" --quiet
  git add .github/
  git commit -m "$commit_msg" --quiet
  git push --set-upstream origin "$BRANCH" --quiet

  pr_url=$(gh pr create \
    --title "$pr_title" \
    --body "$pr_body" \
    --base "$default_branch" \
    --head "$BRANCH")
  echo "  PR: $pr_url"
  PRS+=("$pr_url")

  popd >/dev/null
done

echo
if [ ${#PRS[@]} -gt 0 ]; then
  echo "Opened PRs:"
  printf '  %s\n' "${PRS[@]}"
fi
echo "Done."
