#!/usr/bin/env bash
# Fixture test for sync-workflow-checksums.sh — the DEV-1311 diff-scoped
# release-routing invariant that gates every PR, and the sync-side checksum
# output that is how a human satisfies it. Exercises the EXACT program CI runs,
# fed the same way (changed paths on stdin), so the test cannot drift from
# production.
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
  verdict "$label" "$expected" "$status" "$out" "$must" "$must_not"
}

# The same assertion against `--check`, the whole-repo mode. Separate helper
# rather than a flag on check() because the two modes take their input
# differently — --check-routing reads a diff on stdin, --check reads the tree —
# and because keeping them apart is what makes it obvious, case by case, which
# mode a property is claimed for. Args as check(), minus the diff.
check_repo() {
  local label="$1" expected="$2" repo="$3" must="$4" must_not="$5"
  local out status
  set +e
  out="$("${repo}/scripts/sync-workflow-checksums.sh" --check 2>&1)"
  status=$?
  set -e
  verdict "$label" "$expected" "$status" "$out" "$must" "$must_not"
}

# Shared body: exit status, then what the report does and does not say. A gate
# that fails without naming the offending workflow is not actionable; one that
# names a workflow it should have ignored is noise the next reader has to
# disprove.
#   $1 label  $2 expected status  $3 actual status  $4 output
#   $5 must mention  $6 must NOT mention
verdict() {
  local label="$1" expected="$2" status="$3" out="$4" must="$5" must_not="$6"

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

# Assert that a generated pins file does ('have') or does not ('lack') contain a
# line matching an ERE.
#   $1 label  $2 have|lack  $3 file  $4 pattern
pins_match() {
  local label="$1" expect="$2" file="$3" pattern="$4" found=1
  if [ ! -f "$file" ]; then
    echo "FAIL: ${label}"
    echo "  ${file} does not exist"
    fails=$((fails + 1))
    return
  fi
  grep -qE -- "$pattern" "$file" && found=0
  if { [ "$expect" = have ] && [ "$found" -eq 0 ]; } ||
    { [ "$expect" = lack ] && [ "$found" -ne 0 ]; }; then
    echo "PASS: ${label}"
    return
  fi
  echo "FAIL: ${label}"
  echo "  expected ${file} to ${expect} a line matching /${pattern}/:"
  indent "$(cat "$file")"
  fails=$((fails + 1))
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

# --- the sync side of the same declarations ---------------------------------
# The routing rule and the checksum are two halves of one affordance: routing
# says a prompt edit must reach the package, and the sync run is what a human
# does to make it. If the assets stop reaching the CHECKSUM, a prompt-only edit
# produces no file change at all and DEV-637 is silently gone — while every
# routing case above stays green, because they never look at the checksum. So
# assert the sync-side output directly.
#
# This is what the glob expansion in workflow_assets() carries: quoting
# `$pattern` there drops every prompt from the checksum and is invisible to the
# rest of this file. Both pattern kinds are pinned — the glob and the literal.
for asset in prompts/pr-review-default.md scripts/pepper-audit-record.jq; do
  if grep -qF -- "  ${asset}" "${ASSETS}/workflows/pepper-pr-review/workflow.sha256"; then
    echo "PASS: ${asset} is hashed into the checksum file"
  else
    echo "FAIL: ${asset} is hashed into the checksum file"
    indent "$(cat "${ASSETS}/workflows/pepper-pr-review/workflow.sha256")"
    fails=$((fails + 1))
  fi
done

# --- prefix-sibling package names -------------------------------------------
# routes_to()'s correctness rests entirely on the trailing slash in its pattern,
# and workflows/ really does hold a prefix pair: scorecard and scorecard-public.
# Without the slash, "workflows/scorecard"* also matches
# workflows/scorecard-public/..., and a PR editing scorecard.yml while touching
# only scorecard-public's package dir would be waved through to no release.
SIBLINGS="$(fixture prefix-siblings scorecard scorecard-public)"

check "a prefix-sibling package dir does not route" 1 "$SIBLINGS" \
  "no file under workflows/scorecard/ is" "" \
  .github/workflows/scorecard.yml workflows/scorecard-public/workflow.sha256

# The positive control for the pair: the real package dir does route, so the
# case above fails for the right reason.
check "the prefix-sibling's own package dir routes" 0 "$SIBLINGS" "" "" \
  .github/workflows/scorecard.yml workflows/scorecard/workflow.sha256

check "the longer sibling routes on its own dir" 0 "$SIBLINGS" "" "" \
  .github/workflows/scorecard-public.yml workflows/scorecard-public/workflow.sha256

# --- pins.yml: the BOT-side routing affordance (DEV-1313) -------------------
# workflow.sha256 is how a HUMAN routes a workflow edit — run the script, commit
# the file. pins.yml is how a BOT does it with nobody watching: Renovate is
# pointed at workflows/*/pins.yml, so the same action ref is independently
# managed in the workflow and in the package directory, and one bump PR edits
# both. Nothing syncs the two at bump time; both just happen to be managed.
#
# Every case below is hermetic, deliberately. This suite runs in CI on every PR,
# so it must not assert anything about THIS repo's whole-tree pins state: that
# is exactly the DEV-726 shape — drift on main turning PRs red that touched none
# of it — that --check-routing was narrowed to avoid. The pins properties are
# claimed for --check, and --check is a human's whole-repo view, not a gate.

PINS="$(fixture pins alpha)"
PINS_YML="${PINS}/workflows/alpha/pins.yml"

# fixture()'s workflows carry no `uses:` at all, so a fresh one is also THE EMPTY
# CASE: a workflow with nothing to bump still gets a file, so the package
# directory's shape never depends on today's action inventory. `steps: []` and
# not the jobs:/runs-on: shape — that one makes Renovate manufacture an `ubuntu`
# runner dependency out of a workflow that has no dependencies at all (DEV-1310).
pins_match "a workflow with no actions still gets a pins file, as steps: []" have \
  "$PINS_YML" '^  steps: \[\]$'
pins_match "the empty case emits no entries" lack "$PINS_YML" '^[[:space:]]*-[[:space:]]+uses:'

# Now the populated case. This workflow carries one of every `uses:` form that
# matters, plus three that must NOT be mirrored.
cat >"${PINS}/.github/workflows/alpha.yml" <<'YAML'
name: alpha
on:
  workflow_call:
jobs:
  run:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v7
      - uses: astral-sh/setup-uv@ae62891fec2bb8e7d6c99fc78c9fec3a63790f8d # v10.0.0
      - uses: github/codeql-action/upload-sarif@v4
      - uses: docker://alpine:3.22
      - uses: ./.github/actions/local-thing
      - uses: actions/checkout@v7
      - name: a shell body that merely talks about uses
        run: |
          echo "  uses: owner/repo@0000000000000000000000000000000000000000  # v1.2.3"
          grep -nE '^[[:space:]]*-?[[:space:]]*uses:' something.yml
uses: actions/never-extracted@v9
YAML
(cd "$PINS" && scripts/sync-workflow-checksums.sh >/dev/null)

# THE completeness rule. The routing gate says a workflow YAML in the diff needs
# a file under workflows/<name>/ in the same diff, so a Renovate bump routes only
# if the ref it bumped is ALSO in pins.yml. Omit a bumpable form and that bump
# fails the gate on a bot PR — the exact failure this epic exists to remove. So
# every form Renovate has a datasource for is mirrored, not just the SHA-pinned
# third-party ones.
pins_match "a first-party major tag is mirrored (Renovate bumps v7 to v8 too)" have \
  "$PINS_YML" '^[[:space:]]+- uses: actions/checkout@v7$'
pins_match "a subpath action is mirrored" have \
  "$PINS_YML" '^[[:space:]]+- uses: github/codeql-action/upload-sarif@v4$'
pins_match "a docker:// ref is mirrored" have \
  "$PINS_YML" '^[[:space:]]+- uses: docker://alpine:3\.22$'

# The SHA and its trailing version comment are copied byte for byte. Renovate
# rewrites that whole remainder in both files, so any reformatting here would
# show up as permanent drift the moment a bump lands.
pins_match "the SHA and its # vX.Y.Z comment are preserved verbatim" have \
  "$PINS_YML" '^[[:space:]]+- uses: astral-sh/setup-uv@ae62891fec2bb8e7d6c99fc78c9fec3a63790f8d # v10\.0\.0$'

# A local ref names a path in this repo: no version, no datasource, so Renovate
# can never open a bump PR for it and there is nothing for one to route.
pins_match "a local ./ ref is not mirrored" lack "$PINS_YML" 'local-thing'

# Extraction is a LINE regex, like Renovate's. A shell body or comment that
# merely contains the text "uses:" is not a dependency — actions-audit.yml is
# full of them, and mirroring one would put a bogus dep in front of Renovate.
pins_match "a shell string that merely contains uses: is not mirrored" lack \
  "$PINS_YML" 'owner/repo'

# Renovate requires leading whitespace, so a `uses:` in column 0 is invisible to
# it. Mirroring it would put a ref in pins.yml that Renovate will never bump in
# the workflow — the two must see the same set.
pins_match "a column-0 uses: in the workflow is not mirrored, matching Renovate" lack \
  "$PINS_YML" 'never-extracted'

# The header is the entire answer to "what is this file and why is it here?" for
# whoever finds one and wonders. Pin the four things it has to say, because a
# generated file with no explanation is how a future maintainer talks themselves
# into deleting it.
for needle in 'GENERATED FILE' 'scripts/sync-workflow-checksums\.sh' 'Renovate' \
  'never executes this file'; do
  pins_match "the generated header says '${needle}'" have "$PINS_YML" "$needle"
done

# Deduplicated: alpha.yml uses actions/checkout twice.
dupes="$(grep -cE '^[[:space:]]+- uses: actions/checkout@v7$' "$PINS_YML" || true)"
if [ "$dupes" = 1 ]; then
  echo "PASS: a ref used twice in the workflow becomes one entry"
else
  echo "FAIL: a ref used twice in the workflow becomes one entry"
  echo "  expected 1 actions/checkout@v7 entry, found ${dupes}"
  fails=$((fails + 1))
fi

# THE column-0 trap, on the OUTPUT side and stated as a property of the whole
# file rather than of one line: every `uses:` the generator emits must carry
# leading whitespace, or Renovate reads the file and extracts nothing from it
# while everything still looks right.
col0="$(grep -vE '^[[:space:]]*#' "$PINS_YML" | grep -nE 'uses[[:space:]]*:' |
  grep -vE '^[0-9]+:[[:space:]]' || true)"
if [ -z "$col0" ]; then
  echo "PASS: every generated uses: line carries leading whitespace"
else
  echo "FAIL: every generated uses: line carries leading whitespace"
  echo "  these would be silently invisible to Renovate:"
  indent "${col0}"
  fails=$((fails + 1))
fi

# Idempotent: the second run is a no-op. Sorting and dedup are what make this
# true, and a generator that churns its own output would make every workflow
# edit produce a spurious diff.
cp "$PINS_YML" "${TMP}/pins-first-run.yml"
(cd "$PINS" && scripts/sync-workflow-checksums.sh >/dev/null)
if cmp -s "${TMP}/pins-first-run.yml" "$PINS_YML"; then
  echo "PASS: running the generator twice changes nothing the second time"
else
  echo "FAIL: running the generator twice changes nothing the second time"
  indent "$(diff "${TMP}/pins-first-run.yml" "$PINS_YML" || true)"
  fails=$((fails + 1))
fi

# pins.yml must NOT be hashed into workflow.sha256. It is generated FROM the
# workflow, so including it would be circular — and worse, every Renovate bump
# would rewrite pins.yml and leave the checksum instantly stale for a change the
# bot had already routed correctly.
pins_match "pins.yml is not hashed into workflow.sha256" lack \
  "${PINS}/workflows/alpha/workflow.sha256" 'pins\.yml'

# --- who enforces pins staleness --------------------------------------------
# A pins.yml that disagrees with its workflow is the dangerous state: it still
# ROUTES (any file in the package dir does), so the PR gate goes green while
# Renovate is bumping refs the workflow no longer has — or silently missing ones
# it does. Something has to notice, and that something is --check.
HAND="$(fixture pins-hand-edited alpha beta)"
printf '    - uses: actions/checkout@v99\n' >>"${HAND}/workflows/alpha/pins.yml"

check_repo "a hand-edited pins.yml is caught by --check" 1 "$HAND" \
  "workflows/alpha/pins.yml disagrees with" "workflows/beta/pins.yml"

# ...and NOT by the PR gate. --check-routing was confined to routing on purpose
# (DEV-1311); a stale pins.yml is whole-repo drift like any other, and letting
# whole-repo drift fail unrelated PRs is DEV-726.
check "a stale pins.yml does not fail an unrelated PR" 0 "$HAND" "" "" \
  README.md
check "a stale pins.yml does not fail its own workflow's PR either" 0 "$HAND" "" "" \
  .github/workflows/alpha.yml workflows/alpha/workflow.sha256

# A MISSING pins.yml is a WARNING, not an error. This is the DEV-1313 -> DEV-1314
# interim made safe: this PR ships the generator, DEV-1314 commits the twelve
# files, and in between `--check` on main must not hard-fail for everyone. It
# also stands on its own merits — no pins.yml just means Renovate manages that
# workflow's actions in one place instead of two, i.e. the pre-DEV-1313 world,
# where the consequence surfaces loudly as a red --check-routing on the bot PR
# rather than slipping through.
MISSING="$(fixture pins-missing alpha beta)"
rm -f "${MISSING}/workflows/alpha/pins.yml"

check_repo "a missing pins.yml warns but does not fail --check" 0 "$MISSING" \
  "workflows/alpha/pins.yml is missing" "workflows/beta/pins.yml is missing"

# --- config:recommended's ignorePaths ---------------------------------------
# config:recommended (inherited through default.json) sets ignorePaths including
# **/test/**, **/tests/**, **/examples/** and **/vendor/**. A workflow named any
# of those puts its pins.yml on a path Renovate silently never reads: bumps stop
# routing, with no error anywhere. Nothing collides today. It is checked because
# the failure would be invisible, and checking costs nothing.
IGNORED="$(fixture pins-renovate-ignored test 2>/dev/null)"

check_repo "a workflow name Renovate's ignorePaths swallow is an error under --check" 1 \
  "$IGNORED" "matches an ignorePaths entry" ""

set +e
out="$("${IGNORED}/scripts/sync-workflow-checksums.sh" 2>&1 >/dev/null)"
set -e
if grep -qF -- "ignorePaths" <<<"$out"; then
  echo "PASS: the generator warns while writing an ignorePaths-swallowed pins file"
else
  echo "FAIL: the generator warns while writing an ignorePaths-swallowed pins file"
  indent "${out}"
  fails=$((fails + 1))
fi

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
