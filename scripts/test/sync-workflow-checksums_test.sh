#!/usr/bin/env bash
# Fixture test for sync-workflow-checksums.sh --check-routing — the DEV-1311
# diff-scoped release-routing invariant that gates every PR. Exercises the EXACT
# program CI runs, fed the same way (changed paths on stdin), so the test cannot
# drift from production.
#
# The case this test exists for is the FALSE POSITIVE (DEV-726). The old gate
# recomputed every workflow's hash and compared it repo-wide, so one stale
# workflows/<name>/workflow.sha256 left on main by a merged Renovate bump turned
# the check red on PRs that touched none of it — seven packages stale at once at
# the worst of it. `stale-on-main` below reproduces that shape for real (the
# fixture's checksum genuinely disagrees with its workflow, and `--check` is
# asserted to notice) and pins that `--check-routing` passes anyway, because it
# never reads a checksum's value at all.
#
# Fixtures are built rather than checked in, for two reasons:
#   * The diff is DATA. --check-routing takes the changed paths on stdin instead
#     of shelling out to git, so a case is a handful of strings — no synthetic
#     history, no repo state to unwind.
#   * The inventory is a directory shape. The script derives its own root from
#     $0, so a copy of the script plus .github/workflows/, workflows/ and the
#     two release-please files is a complete repo as far as it is concerned.
#     That is what makes the delete, orphan and stale cases testable without
#     mutating this repo.
#
# The final section runs against this repo's REAL tree, so the fixtures cannot
# all agree with each other while production has drifted — and so the asset
# declarations for the real pepper-pr-review are exercised at their real paths.
#
# Run locally:  scripts/test/sync-workflow-checksums_test.sh
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${HERE}/../.." && pwd)"
SCRIPT="${ROOT}/scripts/sync-workflow-checksums.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

fails=0

# Indent a captured report so a failure is readable next to the PASS lines.
indent() { while IFS= read -r line; do echo "    ${line}"; done <<<"$1"; }

# Build a minimal repo the script can run against, in sync to begin with. Args:
#   $1    dir name under $TMP
#   $2..  reusable workflow names (YAML + package dir + release-please entries)
fixture() {
  local dir="${TMP}/$1"
  shift
  mkdir -p "${dir}/scripts" "${dir}/.github/workflows"
  cp "${SCRIPT}" "${dir}/scripts/"

  local name
  for name in "$@"; do
    mkdir -p "${dir}/workflows/${name}"
    cat >"${dir}/.github/workflows/${name}.yml" <<YAML
name: ${name}
on:
  workflow_call:
jobs:
  run:
    runs-on: ubuntu-latest
    steps:
      - run: "true"
YAML
    printf '0.0.0\n' >"${dir}/workflows/${name}/version.txt"
  done

  register "$dir" "$@"
  # Generate the checksums with the real script, so a fixture starts in the same
  # state a correctly-maintained repo is in.
  (cd "$dir" && scripts/sync-workflow-checksums.sh >/dev/null)
  printf '%s\n' "$dir"
}

# Rewrite the release-please config and manifest to name exactly these packages.
register() {
  local dir="$1"
  shift
  jq -n --args '{packages: ($ARGS.positional | map({("workflows/" + .): {}}) | add)}' "$@" \
    >"${dir}/release-please-config.json"
  jq -n --args '$ARGS.positional | map({("workflows/" + .): "0.0.0"}) | add' "$@" \
    >"${dir}/.release-please-manifest.json"
}

# Assert the routing gate's exit status, and that its report does (or does not)
# name something. A gate that fails without naming the offending workflow is not
# actionable; one that names a workflow it should have ignored is noise the next
# reader has to disprove. Args:
#   $1 label  $2 expected status  $3 repo  $4 must mention  $5 must NOT mention
#   $6.. the changed paths making up the diff
check() {
  local label="$1" expected="$2" repo="$3" must="$4" must_not="$5"
  shift 5
  local out status
  set +e
  out="$(printf '%s\n' "$@" | "${repo}/scripts/sync-workflow-checksums.sh" --check-routing 2>&1)"
  status=$?
  set -e

  if [ "$status" -ne "$expected" ]; then
    echo "FAIL: ${label}"
    echo "  expected exit ${expected}, got ${status}"
    indent "${out}"
    fails=$((fails + 1))
    return
  fi
  if [ -n "$must" ] && ! grep -qF -- "$must" <<<"$out"; then
    echo "FAIL: ${label}"
    echo "  report never mentions '${must}':"
    indent "${out}"
    fails=$((fails + 1))
    return
  fi
  if [ -n "$must_not" ] && grep -qF -- "$must_not" <<<"$out"; then
    echo "FAIL: ${label}"
    echo "  report should not mention '${must_not}':"
    indent "${out}"
    fails=$((fails + 1))
    return
  fi
  echo "PASS: ${label}"
}

# --- the invariant ----------------------------------------------------------
SYNCED="$(fixture synced alpha beta)"

# The failure this gate exists to catch: the YAML moved, nothing in the package
# directory did, so release-please would assign the squash commit to no package.
check "workflow YAML alone does not route" 1 "$SYNCED" \
  "no file under workflows/alpha/ is" "" \
  .github/workflows/alpha.yml

check "workflow YAML with its regenerated checksum routes" 0 "$SYNCED" "" "" \
  .github/workflows/alpha.yml workflows/alpha/workflow.sha256

# release-please routes by directory prefix and never opens the file, so ANY
# file in the package dir satisfies the invariant. Pinned because the checksum
# is only today's affordance for producing one — DEV-1313's pins.yml is another,
# and swapping the affordance must not need the gate rewritten.
check "any file in the package dir routes, not just the checksum" 0 "$SYNCED" "" "" \
  .github/workflows/alpha.yml workflows/alpha/pins.yml

# Routing is per package. Another workflow's package dir does not stand in.
check "a sibling package dir does not route" 1 "$SYNCED" \
  "no file under workflows/alpha/ is" "" \
  .github/workflows/alpha.yml workflows/beta/workflow.sha256

# Each workflow is judged on its own: the report names the one that failed and
# stays silent about the one that is fine.
check "two workflows, only one unrouted" 1 "$SYNCED" \
  "no file under workflows/alpha/ is" "no file under workflows/beta/ is" \
  .github/workflows/alpha.yml .github/workflows/beta.yml workflows/beta/workflow.sha256

check "package dir touched on its own" 0 "$SYNCED" "" "" \
  workflows/alpha/CHANGELOG.md

check "unrelated file only" 0 "$SYNCED" "" "" \
  README.md

# --- DEV-726: staleness elsewhere on main is not this PR's problem ----------
# alpha.yml is edited without regenerating its checksum, exactly as a merged
# Renovate action bump leaves main.
STALE="$(fixture stale-on-main alpha beta)"
printf '# a Renovate bump landed here without a checksum sync\n' >>"${STALE}/.github/workflows/alpha.yml"

# Premise guard: if the drift is not real, every assertion below is vacuous.
if "${STALE}/scripts/sync-workflow-checksums.sh" --check >/dev/null 2>&1; then
  echo "FAIL: stale fixture is not actually stale — --check should have failed" >&2
  exit 2
fi
echo "PASS: stale fixture is genuinely stale (--check fails on it)"

# THE regression test. Under the old whole-repo hash gate this PR went red for a
# workflow it never touched.
check "unrelated PR passes while another package is stale on main" 0 "$STALE" "" "" \
  README.md

# And a PR on a DIFFERENT workflow is likewise unaffected by alpha's staleness.
check "another workflow's PR passes while alpha is stale on main" 0 "$STALE" "" "" \
  .github/workflows/beta.yml workflows/beta/workflow.sha256

# The stale workflow's own PR is still judged on routing alone, never on the
# hash — touching alpha.yml and its package dir passes even though the stored
# checksum disagrees with the file.
check "the stale workflow's own PR passes when it routes" 0 "$STALE" "" "" \
  .github/workflows/alpha.yml workflows/alpha/workflow.sha256

# --- deletes and renames ----------------------------------------------------
# A workflow removed together with its package dir and its release-please
# entries is a complete, correct change: there is nothing left to route to, and
# the gate must not invent a failure for it.
DELETED="$(fixture deleted alpha beta)"
rm -f "${DELETED}/.github/workflows/beta.yml"
rm -rf "${DELETED}/workflows/beta"
register "$DELETED" alpha

check "workflow deleted together with its package dir" 0 "$DELETED" "" "" \
  .github/workflows/beta.yml workflows/beta/version.txt workflows/beta/workflow.sha256

# A delete (or the old half of a rename) that strands the package dir is caught
# by the whole-repo orphan check — which no per-PR diff can express, and which
# is why that check stays repo-wide. The routing check must stay quiet about
# beta so the report carries one diagnosis, not two in two vocabularies.
ORPHANED="$(fixture orphaned alpha beta)"
rm -f "${ORPHANED}/.github/workflows/beta.yml"

check "deleted workflow with a stranded package dir is one orphan error" 1 "$ORPHANED" \
  "workflows/beta/ has no matching reusable workflow" "no file under workflows/beta/ is" \
  .github/workflows/beta.yml

# The new half of a rename is an ordinary new workflow and must route like one.
RENAMED="$(fixture renamed alpha gamma)"
check "the new name of a renamed workflow must route" 1 "$RENAMED" \
  "no file under workflows/gamma/ is" "" \
  .github/workflows/beta.yml .github/workflows/gamma.yml workflows/beta/workflow.sha256

check "a renamed workflow that carries its new package dir routes" 0 "$RENAMED" "" "" \
  .github/workflows/beta.yml .github/workflows/gamma.yml \
  workflows/beta/workflow.sha256 workflows/gamma/workflow.sha256

# --- non-reusable workflows -------------------------------------------------
# A workflow with no workflow_call trigger has no package and no release, so it
# has nothing to route and must be ignored entirely.
LOCAL="$(fixture repo-local alpha)"
cat >"${LOCAL}/.github/workflows/local-only.yml" <<'YAML'
name: local only
on:
  pull_request:
jobs:
  run:
    runs-on: ubuntu-latest
    steps:
      - run: "true"
YAML

check "a non-reusable workflow is ignored" 0 "$LOCAL" "" "" \
  .github/workflows/local-only.yml

# --- shipped assets (DEV-637) -----------------------------------------------
# pepper-pr-review ships behavior from outside its YAML. Those files have to
# route to its package too, or a prompt-only edit never reaches a caller pinned
# to the moving tag alias. The fixture uses the real package name because the
# asset declarations are keyed by it.
ASSETS="$(fixture assets pepper-pr-review)"
mkdir -p "${ASSETS}/prompts"
printf 'review prompt\n' >"${ASSETS}/prompts/pr-review-default.md"
printf 'true\n' >"${ASSETS}/scripts/pepper-audit-record.jq"
(cd "$ASSETS" && scripts/sync-workflow-checksums.sh >/dev/null)

check "a shipped prompt alone does not route" 1 "$ASSETS" \
  "no file under workflows/pepper-pr-review/ is" "" \
  prompts/pr-review-default.md

check "a shipped prompt with the package dir routes" 0 "$ASSETS" "" "" \
  prompts/pr-review-default.md workflows/pepper-pr-review/workflow.sha256

check "a shipped script alone does not route" 1 "$ASSETS" \
  "no file under workflows/pepper-pr-review/ is" "" \
  scripts/pepper-audit-record.jq

# DELETING a prompt is a behavior change too, and the deleted path is not on
# disk to be globbed — which is why the assets are declared as patterns rather
# than as a file listing.
check "a DELETED prompt still has to route" 1 "$ASSETS" \
  "no file under workflows/pepper-pr-review/ is" "" \
  prompts/retired-prompt.md

# The declarations are per workflow: another package's prompt-shaped file is not
# pepper-pr-review's business.
check "an unrelated markdown file is not a shipped asset" 0 "$ASSETS" "" "" \
  docs/pepper-audit.md

# --- the gate must not become vacuous ---------------------------------------
# An empty diff means the caller's merge base was wrong or its checkout was too
# shallow. A gate that goes green on no input is worse than no gate, so this is
# a hard error, not a pass.
set +e
out="$("${SYNCED}/scripts/sync-workflow-checksums.sh" --check-routing </dev/null 2>&1)"
status=$?
set -e
if [ "$status" -eq 2 ] && grep -qF -- "read no changed paths on stdin" <<<"$out"; then
  echo "PASS: an empty diff is a hard error, not a pass"
else
  echo "FAIL: an empty diff is a hard error, not a pass"
  echo "  expected exit 2, got ${status}"
  indent "${out}"
  fails=$((fails + 1))
fi

# --- production -------------------------------------------------------------
# Against this repo's real tree. Premise guard first: these cases name real
# files, and a case whose subject has been renamed away would pass for the wrong
# reason.
premise_gone() {
  echo "FAIL: test premise gone — $1" >&2
  exit 2
}
if [ ! -f "${ROOT}/.github/workflows/secret-scan.yml" ] || [ ! -d "${ROOT}/workflows/secret-scan" ]; then
  premise_gone "secret-scan is no longer a reusable workflow with a package dir"
fi
if [ ! -f "${ROOT}/prompts/pr-review-default.md" ]; then
  premise_gone "pepper-pr-review no longer ships prompts/pr-review-default.md"
fi
if [ ! -f "${ROOT}/.github/workflows/pepper-self-review.yml" ]; then
  premise_gone "pepper-self-review.yml is gone — pick another repo-local workflow"
fi
if grep -qE '^[[:space:]]+workflow_call:' "${ROOT}/.github/workflows/pepper-self-review.yml"; then
  premise_gone "pepper-self-review.yml is now reusable — pick another repo-local workflow"
fi

check "real repo: secret-scan.yml alone does not route" 1 "$ROOT" \
  "no file under workflows/secret-scan/ is" "" \
  .github/workflows/secret-scan.yml

check "real repo: secret-scan.yml with its checksum routes" 0 "$ROOT" "" "" \
  .github/workflows/secret-scan.yml workflows/secret-scan/workflow.sha256

check "real repo: the real review prompt alone does not route" 1 "$ROOT" \
  "no file under workflows/pepper-pr-review/ is" "" \
  prompts/pr-review-default.md

check "real repo: the real repo-local pepper-self-review.yml is ignored" 0 "$ROOT" "" "" \
  .github/workflows/pepper-self-review.yml

# Also asserts the two whole-repo checks --check-routing still runs (orphaned
# package dirs, release-please config/manifest coverage) hold in this repo.
check "real repo: an unrelated file passes" 0 "$ROOT" "" "" \
  README.md

echo
if [ "$fails" -eq 0 ]; then
  echo "All checks passed."
else
  echo "${fails} check(s) failed."
  exit 1
fi
