#!/usr/bin/env bash
# coverage-surface: render diff coverage to humans, without gating (DEV-526).
#
# Runs as one step in a repo's TEST job, right after the coverage file is
# produced, so it reads the report off local disk. It does three things and
# NEVER fails the build on a coverage number (ADR-0004):
#   1. Appends a diff-cover markdown table to $GITHUB_STEP_SUMMARY.
#   2. Emits ::warning file=,line=:: annotations on uncovered CHANGED lines,
#      which GitHub renders inline in the Files-changed diff.
#   3. Exposes counts as step outputs (percent-covered, changed-lines,
#      uncovered-lines, surfaced) for the caller.
# The raw coverage file is uploaded as an artifact by a sibling step in
# action.yml — that is the only piece Pepper's separate review job consumes.
#
# diff-cover exits 0 regardless of coverage because we never pass --fail-under.
# Any real failure here (missing file, unreadable format) is downgraded to a
# ::warning:: + a "surfaced=false" output so a coverage hiccup can never block a
# merge. The gate is Pepper's judgment informed by coverage, never this script.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

COVERAGE_FILE="${INPUT_COVERAGE_FILE:-}"
BASE_REF="${INPUT_BASE_REF:-}"
VER="${INPUT_DIFF_COVER_VERSION:-10.3.0}"

# Emit outputs with safe defaults up front so every early return still sets them.
emit() { printf '%s=%s\n' "$1" "$2" >> "${GITHUB_OUTPUT}"; }
give_up() {
  echo "::warning::coverage-surface: $1 — skipping diff-coverage surfacing (non-gating, build continues)."
  emit percent-covered "100"
  emit changed-lines "0"
  emit uncovered-lines "0"
  emit surfaced "false"
  exit 0
}

[ -n "${COVERAGE_FILE}" ] || give_up "no coverage-file input"
[ -f "${COVERAGE_FILE}" ] || give_up "coverage file '${COVERAGE_FILE}' not found"
if [ -z "${BASE_REF}" ]; then
  give_up "no base-ref (not a pull_request event); nothing to diff against"
fi

# Make the base branch reachable so diff-cover can compute the changed lines.
# Test-job checkouts are often shallow; unshallow best-effort, then fetch the
# base tip into origin/<base>. Both are best-effort: if the network hiccups,
# the diff step below fails cleanly into give_up rather than blocking the build.
git fetch --no-tags --quiet --unshallow 2>/dev/null || true
git fetch --no-tags --quiet origin "${BASE_REF}" 2>/dev/null || true

# Install diff-cover in an isolated way that survives PEP 668 (externally
# managed) pythons on modern runner images. pipx (preinstalled on GitHub-hosted
# ubuntu) is the clean path; fall back to a --user pip install.
if ! command -v diff-cover >/dev/null 2>&1; then
  if command -v pipx >/dev/null 2>&1; then
    pipx install --quiet "diff-cover==${VER}" >/dev/null 2>&1 || true
  fi
fi
if ! command -v diff-cover >/dev/null 2>&1; then
  python3 -m pip install --quiet --disable-pip-version-check --user "diff-cover==${VER}" >/dev/null 2>&1 \
    || python3 -m pip install --quiet --disable-pip-version-check --user --break-system-packages "diff-cover==${VER}" >/dev/null 2>&1 \
    || true
fi
export PATH="${HOME}/.local/bin:${PATH}"
command -v diff-cover >/dev/null 2>&1 || give_up "could not install diff-cover==${VER}"

MD_REPORT="$(mktemp)"
JSON_REPORT="$(mktemp)"

# One diff-cover invocation → both surfaces. --compare-branch uses the default
# `...` (merge-base) notation, which is what a PR's "changed lines" means.
if ! diff-cover "${COVERAGE_FILE}" \
      --compare-branch "origin/${BASE_REF}" \
      --format "markdown:${MD_REPORT},json:${JSON_REPORT}" \
      -q; then
  give_up "diff-cover failed against origin/${BASE_REF} (unsupported format or unreadable diff)"
fi

# --- Consumer 3: Actions job summary -----------------------------------------
if [ -n "${GITHUB_STEP_SUMMARY:-}" ] && [ -s "${MD_REPORT}" ]; then
  {
    echo "## Diff coverage (non-gating)"
    echo ""
    echo "_Informational only — no coverage number gates this PR. Pepper folds this into its review judgment (DEV-526 / ADR-0004)._"
    echo ""
    cat "${MD_REPORT}"
  } >> "${GITHUB_STEP_SUMMARY}"
fi

# --- Consumer 2: inline PR annotations on uncovered changed lines -------------
# diff-cover's JSON gives per-file `violation_lines` = changed lines with no
# coverage. annotate.py emits one ::warning:: per line (GitHub renders each as a
# yellow marker in the Files-changed tab) and prints "pct|changed|uncovered" to
# stdout. python3 is guaranteed present (we just used it to install diff-cover).
PCT_FILE="$(mktemp)"
python3 "${SCRIPT_DIR}/annotate.py" "${JSON_REPORT}" > "${PCT_FILE}"
PCT="$(cat "${PCT_FILE}")"

emit percent-covered "${PCT%%|*}"
rest="${PCT#*|}"
emit changed-lines "${rest%%|*}"
emit uncovered-lines "${rest##*|}"
emit surfaced "true"

echo "coverage-surface: ${PCT%%|*}% of ${rest%%|*} changed line(s) covered; ${rest##*|} uncovered (non-gating)."
