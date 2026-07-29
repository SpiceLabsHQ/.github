#!/usr/bin/env bash
# Fixture test for check-bot-allowlists.sh — the DEV-679 bot-allowlist drift
# check. Exercises the EXACT program CI runs (via its `--workflows` flag), so
# the test cannot drift from production.
#
# The case this test exists for is the FALSE POSITIVE, not the true positive.
# floor-pepper's initiator list legitimately carries `pepper-pr-review` (the
# DEV-667 sweep reopens stranded PRs as Pepper's own App) while
# floor-automerge's author list legitimately does not. A check that reads that
# difference as drift fires on every run and gets disabled within a week, at
# which point the real divergences it was built for stop being caught. So the
# "legitimate initiator-only difference" cases below are load-bearing.
#
# Fixtures are generated rather than checked in: they must stay structurally
# identical to the production workflows in exactly the places the extractors
# read (`.on.workflow_call.inputs.allowed_bots.default`, a job's
# `.with.allowed_bots`, the `fromJSON('[...]')` literal in a job-level `if:`),
# and a template makes that one edit instead of eight.
#
# Run locally:  scripts/test/check-bot-allowlists_test.sh
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHECK="${HERE}/../check-bot-allowlists.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

fails=0

# Indent a captured report so a failure is readable next to the PASS lines.
indent() { while IFS= read -r line; do echo "    ${line}"; done <<<"$1"; }

# Build a three-file workflow tree. Args:
#   $1 dir name
#   $2 pepper-pr-review `allowed_bots` input default  (comma string, INITIATOR)
#   $3 floor-pepper `allowed_bots` override           (comma string, INITIATOR)
#   $4 floor-automerge author allowlist               (JSON array literal, AUTHOR)
fixture() {
  local dir="${TMP}/$1" pepper="$2" floor="$3" authors="$4"
  mkdir -p "$dir"

  cat >"${dir}/pepper-pr-review.yml" <<YAML
name: Pepper PR Review
on:
  workflow_call:
    inputs:
      allowed_bots:
        description: Comma-separated bot logins (without the \`[bot]\` suffix).
        required: false
        type: string
        default: ${pepper}
jobs:
  gate:
    runs-on: ubuntu-latest
    steps:
      - run: "true"
YAML

  cat >"${dir}/floor-pepper.yml" <<YAML
name: Floor Pepper
on:
  pull_request:
jobs:
  pepper:
    uses: SpiceLabsHQ/.github/.github/workflows/pepper-pr-review.yml@pepper-pr-review-v1
    with:
      allowed_bots: ${floor}
YAML

  cat >"${dir}/floor-automerge.yml" <<YAML
name: Floor Auto-merge
on:
  pull_request:
jobs:
  enable-auto-merge:
    if: >-
      github.event.pull_request.draft == false &&
      (
        contains(fromJSON('${authors}'),
                 github.event.pull_request.user.login) ||
        (
          github.event.repository.custom_properties['automerge-humans'] == 'true' &&
          github.event.pull_request.user.type == 'User'
        )
      )
    runs-on: ubuntu-latest
    steps:
      - run: "true"
YAML

  echo "$dir"
}

# Assert the check's exit status, and (on an expected failure) that the report
# names the offending bot — a drift report that does not say WHICH entry drifted
# is not actionable.
check() {
  local label="$1" expected="$2" dir="$3" must_mention="${4:-}"
  local out status
  set +e
  out="$("${CHECK}" --workflows "$dir" 2>&1)"
  status=$?
  set -e
  if [ "$status" -ne "$expected" ]; then
    echo "FAIL: ${label}"
    echo "  expected exit ${expected}, got ${status}"
    indent "${out}"
    fails=$((fails + 1))
    return
  fi
  # -F: expected fragments contain `[bot]`, which is a bracket expression to a
  # basic-regex grep and would match the wrong thing (or nothing).
  if [ -n "$must_mention" ] && ! grep -qF -- "$must_mention" <<<"$out"; then
    echo "FAIL: ${label}"
    echo "  report never mentions '${must_mention}':"
    indent "${out}"
    fails=$((fails + 1))
    return
  fi
  echo "PASS: ${label}"
}

# --- in sync ----------------------------------------------------------------
# Production's exact shape: two dependency bots, plus the sweep initiator on the
# floor-pepper side only.
check "lists in sync (production shape)" 0 \
  "$(fixture in-sync 'renovate,dependabot' 'renovate,dependabot,pepper-pr-review' \
       '["renovate[bot]","dependabot[bot]"]')"

# The inventory is READ from the files, not hardcoded here — a third dependency
# bot added consistently everywhere must pass.
check "lists in sync with a third dependency bot" 0 \
  "$(fixture in-sync-three 'renovate,dependabot,mergify' 'renovate,dependabot,mergify,pepper-pr-review' \
       '["renovate[bot]","dependabot[bot]","mergify[bot]"]')"

# Whitespace and ordering are formatting, not drift.
check "in sync modulo order and whitespace" 0 \
  "$(fixture in-sync-messy 'dependabot, renovate' ' pepper-pr-review ,renovate, dependabot' \
       '["dependabot[bot]","renovate[bot]"]')"

# --- the legitimate initiator-only difference -------------------------------
# THE false-positive guard. `pepper-pr-review` is an initiator (DEV-667 sweep)
# and deliberately absent from the author list. This must NOT be drift.
check "sweep initiator absent from the author list is NOT drift" 0 \
  "$(fixture sweep-ok 'renovate,dependabot' 'renovate,dependabot,pepper-pr-review' \
       '["renovate[bot]","dependabot[bot]"]')"

# Dropping the sweep initiator disables the DEV-667 sweep with no other signal
# (a skipped required check still passes), so it is drift in the other
# direction.
check "sweep initiator dropped from floor-pepper is drift" 1 \
  "$(fixture sweep-dropped 'renovate,dependabot' 'renovate,dependabot' \
       '["renovate[bot]","dependabot[bot]"]')" \
  "missing from floor-pepper's initiator allowlist"

# The sweep initiator is an initiator, never an author: in the author list it
# would arm auto-merge for Pepper's own App.
check "sweep initiator leaked into the author list is drift" 1 \
  "$(fixture sweep-leaked 'renovate,dependabot' 'renovate,dependabot,pepper-pr-review' \
       '["renovate[bot]","dependabot[bot]","pepper-pr-review[bot]"]')" \
  "must never appear in floor-automerge's AUTHOR allowlist"

# --- author-list divergence -------------------------------------------------
# Armed with no review path.
check "bot in the author list only" 1 \
  "$(fixture author-extra 'renovate,dependabot' 'renovate,dependabot,pepper-pr-review' \
       '["renovate[bot]","dependabot[bot]","mergify[bot]"]')" \
  "auto-arm with no review path"

# Reviewed, then strands unmerged.
check "bot in the initiator default only" 1 \
  "$(fixture author-missing 'renovate,dependabot,mergify' 'renovate,dependabot,mergify,pepper-pr-review' \
       '["renovate[bot]","dependabot[bot]"]')" \
  "strand unmerged"

# floor-pepper widened with an entry that is neither a dependency bot nor a
# recorded operational initiator.
check "undocumented initiator added to floor-pepper" 1 \
  "$(fixture initiator-extra 'renovate,dependabot' 'renovate,dependabot,pepper-pr-review,mystery' \
       '["renovate[bot]","dependabot[bot]"]')" \
  "undocumented entries in floor-pepper"

# --- shape drift ------------------------------------------------------------
# Author entries are matched against `pull_request.user.login`; without the
# suffix the entry matches nothing and fails open.
check "author entry missing the [bot] suffix" 1 \
  "$(fixture author-shape 'renovate,dependabot' 'renovate,dependabot,pepper-pr-review' \
       '["renovate[bot]","dependabot"]')" \
  "author entries MUST carry the [bot] suffix"

# The initiator gate appends `[bot]` itself, so a pre-suffixed entry double-
# suffixes and matches nothing.
check "initiator entry carrying the [bot] suffix" 1 \
  "$(fixture initiator-shape 'renovate,dependabot[bot]' 'renovate,dependabot[bot],pepper-pr-review' \
       '["renovate[bot]","dependabot[bot]"]')" \
  "initiator entries must NOT carry the [bot] suffix"

# --- globs (ADR-0017) -------------------------------------------------------
check "glob in the author list" 1 \
  "$(fixture glob-author 'renovate,dependabot' 'renovate,dependabot,pepper-pr-review' \
       '["renovate[bot]","dependabot[bot]","*[bot]"]')" \
  "glob-shaped entries"

check "glob in the initiator list" 1 \
  "$(fixture glob-initiator 'renovate,dependabot,*' 'renovate,dependabot,*,pepper-pr-review' \
       '["renovate[bot]","dependabot[bot]"]')" \
  "glob-shaped entries"

# --- the check must not become vacuous --------------------------------------
# If a key moves, the check has to fail LOUDLY (exit 2) rather than silently
# find nothing and pass.
vacuous="$(fixture vacuous 'renovate,dependabot' 'renovate,dependabot,pepper-pr-review' \
             '["renovate[bot]","dependabot[bot]"]')"
yq -i 'del(.jobs.enable-auto-merge.if)' "${vacuous}/floor-automerge.yml"
check "author allowlist gone from floor-automerge is a hard error" 2 "$vacuous"

vacuous2="$(fixture vacuous2 'renovate,dependabot' 'renovate,dependabot,pepper-pr-review' \
              '["renovate[bot]","dependabot[bot]"]')"
yq -i 'del(.on.workflow_call.inputs.allowed_bots.default)' "${vacuous2}/pepper-pr-review.yml"
check "initiator default gone from pepper-pr-review is a hard error" 2 "$vacuous2"

# --- production ---------------------------------------------------------------
# The real workflows must pass. Without this the fixtures could all agree with
# each other while the repo itself has drifted.
check "the repo's own .github/workflows" 0 "${HERE}/../../.github/workflows"

if [ "$fails" -ne 0 ]; then
  echo "${fails} test(s) failed" >&2
  exit 1
fi
echo "all checks passed"
