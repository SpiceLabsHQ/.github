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
# The pins.yml section (DEV-1313) covers the BOT-side half of the same
# affordance. Its cases are hermetic on purpose — this suite runs in CI on every
# PR, so asserting anything about this repo's whole-tree pins or checksum state
# would recreate the very DEV-726 shape described above. The two exceptions read
# the real sast.yml and copy it INTO a fixture, which gets the anti-rot benefit
# without the whole-repo coupling.
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

# Abort loudly when a case's subject no longer exists. A case that names a real
# file and quietly stops covering anything is worse than no case at all.
premise_gone() {
  echo "FAIL: test premise gone — $1" >&2
  exit 2
}

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

# Now the populated case. This workflow carries one of every form that matters,
# plus four that must NOT be mirrored.
cat >"${PINS}/.github/workflows/alpha.yml" <<'YAML'
name: alpha
on:
  workflow_call:
jobs:
  run:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v7
        with:
          fetch-depth: 0
          persist-credentials: false
      - uses: astral-sh/setup-uv@ae62891fec2bb8e7d6c99fc78c9fec3a63790f8d # v10.0.0
        with:
          version: "0.9.7"
      - uses: actions/setup-python@v7
        with:
          python-version: "3.14"
      - uses: actions/setup-node@v6
        with:
          node-version: 24
          cache: npm
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

# --- the `with:` half of the mirror -----------------------------------------
# The dep set is NOT just the `uses:` lines. Renovate's github-actions manager
# runs two passes — a line regex for action refs, and a real YAML parse — and
# the second turns `with.<lang>-version` on actions/setup-{go,node,python}, and
# the version key of each of its 25 known community actions, into a fully-formed
# managed dep with no skipReason. sast.yml's `python-version: "3.14"` is one:
# when 3.15 lands, Renovate opens a PR touching only the workflow, and without
# this half of the mirror that PR routes nowhere and cuts no release.
pins_match "a built-in <lang>-version input is mirrored (actions/setup-python)" have \
  "$PINS_YML" '^[[:space:]]+python-version: "3\.14"$'
pins_match "a built-in <lang>-version input is mirrored (actions/setup-node)" have \
  "$PINS_YML" '^[[:space:]]+node-version: "24"$'
pins_match "a community action's version: input is mirrored (astral-sh/setup-uv)" have \
  "$PINS_YML" '^[[:space:]]+version: "0\.9\.7"$'

# ...and only those keys. Everything else in a `with:` block is configuration
# Renovate never reads, and copying it would drag secrets, tokens and multi-line
# prompts into a committed file for nothing.
pins_match "a with: key Renovate does not read is not mirrored (fetch-depth)" lack \
  "$PINS_YML" 'fetch-depth'
pins_match "a with: key Renovate does not read is not mirrored (cache)" lack \
  "$PINS_YML" '^[[:space:]]+cache:'

# A step whose `with:` holds nothing Renovate reads gets no `with:` block at all.
# That is not cosmetic: Renovate's UsesStep schema REQUIRES a `with` key, so a
# step without one is invisible to the YAML pass, which is exactly where it
# should stay.
withless="$(awk '/^ +- uses: actions\/checkout@v7$/ { getline nxt; print nxt }' "$PINS_YML")"
if [[ "$withless" == *"- uses: "* ]]; then
  echo "PASS: a step with no Renovate-readable with: key gets no with: block"
else
  echo "FAIL: a step with no Renovate-readable with: key gets no with: block"
  echo "  expected another step to follow actions/checkout@v7, got: ${withless}"
  fails=$((fails + 1))
fi

# --- the scaffold itself ----------------------------------------------------
# The three scaffold lines are load-bearing and nothing else here pins them.
# Renovate's YAML pass parses this file against a union that tries `{jobs: ...}`
# FIRST and `{runs: {using, steps}}` second. Under the composite shape it
# matches the second, which has no runs-on / container / services concept, so
# the pass can produce nothing but the uses-with deps above. Swap in a `jobs:`
# scaffold with a `runs-on:` and every generated file silently acquires
# `github-runner:ubuntu@24.04` — a live dep with no twin in any workflow, back
# again on every Ubuntu release.
pins_match "the scaffold opens with runs:" have "$PINS_YML" '^runs:$'
pins_match "the scaffold declares using: composite" have "$PINS_YML" '^  using: composite$'
pins_match "the populated case declares steps:" have "$PINS_YML" '^  steps:$'
pins_match "the scaffold has no jobs: key" lack "$PINS_YML" '^jobs:'
# Anchored to a YAML key, because the file's own header prose mentions runs-on
# while explaining why it must not have one.
pins_match "the scaffold names no runner" lack "$PINS_YML" '^[[:space:]]*runs-on:'

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

# --- the central promise: a bot bump lands and the script agrees with it -----
# Everything else here tests the generator against a static workflow. THIS tests
# the thing the design actually promises: Renovate edits the same ref in both
# files, and afterwards the script has nothing left to say. If it disagreed —
# different ordering, a reformatted comment, a requoted value — the bot's PR
# would arrive already "stale" and the next human sync would produce a
# gratuitous diff, on every single bump.
#
# Simulated exactly as Renovate's auto-replace behaves: the same substitution
# applied to the workflow AND to pins.yml, covering a major tag, a SHA with its
# trailing version comment, and a subpath ref.
BUMP="${PINS}/.github/workflows/alpha.yml"
BUMPED_PINS="${PINS}/workflows/alpha/pins.yml"
order_before="$(grep -oE '\- uses: [^ ]+' "$BUMPED_PINS" | sed 's/@.*//')"
for target in "$BUMP" "$BUMPED_PINS"; do
  sed -i.bak \
    -e 's|actions/checkout@v7|actions/checkout@v8|g' \
    -e 's|astral-sh/setup-uv@ae62891fec2bb8e7d6c99fc78c9fec3a63790f8d # v10.0.0|astral-sh/setup-uv@1111111111111111111111111111111111111111 # v10.1.0|g' \
    -e 's|github/codeql-action/upload-sarif@v4|github/codeql-action/upload-sarif@v5|g' \
    "$target"
  rm -f "${target}.bak"
done
cp "$BUMPED_PINS" "${TMP}/pins-as-renovate-left-it.yml"
(cd "$PINS" && scripts/sync-workflow-checksums.sh >/dev/null)

if cmp -s "${TMP}/pins-as-renovate-left-it.yml" "$BUMPED_PINS"; then
  echo "PASS: after a simulated Renovate bump of both files, the script rewrites nothing"
else
  echo "FAIL: after a simulated Renovate bump of both files, the script rewrites nothing"
  indent "$(diff "${TMP}/pins-as-renovate-left-it.yml" "$BUMPED_PINS" || true)"
  fails=$((fails + 1))
fi

# And the entry ORDER is unchanged by the bump, which is what makes the diff of
# a bump PR one line per bumped ref instead of a whole-file reshuffle.
order_after="$(grep -oE '\- uses: [^ ]+' "$BUMPED_PINS" | sed 's/@.*//')"
if [ "$order_before" = "$order_after" ]; then
  echo "PASS: a bump does not reorder the mirrored entries"
else
  echo "FAIL: a bump does not reorder the mirrored entries"
  indent "$(diff <(echo "$order_before") <(echo "$order_after") || true)"
  fails=$((fails + 1))
fi

# --- driven from the real sast.yml ------------------------------------------
# The `with:` half of the mirror exists because of one concrete dep in this
# repo, and a synthetic fixture alone would let that dep be renamed or removed
# without anyone noticing the coverage went with it. So assert it against the
# REAL workflow, copied into a fixture so nothing here depends on whether
# DEV-1314 has landed the committed pins files yet.
if ! grep -qE '^[[:space:]]+uses: actions/setup-python@' "${ROOT}/.github/workflows/sast.yml"; then
  premise_gone "sast.yml no longer uses actions/setup-python — move this case to whichever workflow now carries a uses-with dep"
fi
real_pyver="$(yq -r '.jobs[].steps[]? | select(.uses // "" | test("^actions/setup-python@")) | .with."python-version"' \
  "${ROOT}/.github/workflows/sast.yml" | head -1)"
if [ -z "$real_pyver" ] || [ "$real_pyver" = "null" ]; then
  premise_gone "sast.yml's actions/setup-python step no longer passes python-version — the uses-with dep this case covers is gone"
fi

REALSAST="$(fixture real-sast sast)"
cp "${ROOT}/.github/workflows/sast.yml" "${REALSAST}/.github/workflows/sast.yml"
(cd "$REALSAST" && scripts/sync-workflow-checksums.sh >/dev/null)

pins_match "real sast.yml: its python-version reaches the mirror" have \
  "${REALSAST}/workflows/sast/pins.yml" "^[[:space:]]+python-version: \"${real_pyver}\"$"
pins_match "real sast.yml: the setup-python ref reaches the mirror" have \
  "${REALSAST}/workflows/sast/pins.yml" '^[[:space:]]+- uses: actions/setup-python@'

# --- deps a pins.yml structurally cannot mirror -----------------------------
# `runs-on: ubuntu-24.04`, `container:` and `services:` all become real deps in
# Renovate's YAML pass, and none of them can live in a composite-shaped file. So
# the generator says so out loud instead of leaving a hole nobody can see. A
# warning, not an error: there is no edit the author could make to fix it, and a
# hard failure with no fix is a dead end.
UNMIRRORABLE="$(fixture unmirrorable alpha 2>/dev/null)"
cat >"${UNMIRRORABLE}/.github/workflows/alpha.yml" <<'YAML'
name: alpha
on:
  workflow_call:
jobs:
  pinned-runner:
    runs-on: ubuntu-24.04
    container: node:24-bookworm
    steps:
      - uses: actions/checkout@v7
YAML
set +e
out="$("${UNMIRRORABLE}/scripts/sync-workflow-checksums.sh" 2>&1 >/dev/null)"
set -e
for needle in "runs-on: ubuntu-24.04" "container:"; do
  if grep -qF -- "$needle" <<<"$out"; then
    echo "PASS: the generator warns that '${needle}' cannot be mirrored"
  else
    echo "FAIL: the generator warns that '${needle}' cannot be mirrored"
    indent "${out}"
    fails=$((fails + 1))
  fi
done

# --check has to report it too. An author who runs the checker rather than the
# generator must see the same hole, and these are two separate call sites.
check_repo "the unmirrorable-dep warning also fires under --check" 0 "$UNMIRRORABLE" \
  "cannot mirror" ""

# The control: `runs-on: ubuntu-latest` extracts as github-runner:ubuntu@latest
# and Renovate skips it as invalid-version, so it is NOT a hole and must not
# warn. Without this, the warning above would fire on all twelve workflows and
# be tuned out within a day.
set +e
out="$("${PINS}/scripts/sync-workflow-checksums.sh" 2>&1 >/dev/null)"
set -e
if grep -qF -- "cannot mirror" <<<"$out"; then
  echo "FAIL: runs-on: ubuntu-latest does not warn"
  indent "${out}"
  fails=$((fails + 1))
else
  echo "PASS: runs-on: ubuntu-latest does not warn"
fi

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

# --- --check-pins: the diff-scoped pins-agreement gate (DEV-1314) -----------
# --check above is the whole-repo view and is invoked by no workflow, so until
# now nothing in CI asserted a pins.yml still matched the workflow it mirrors.
# That gap is not cosmetic: `Versioning integrity` is not a REQUIRED status
# check here (PRs have merged with it red), so there is no downstream net either.
# A mirror that quietly loses a ref means the next bump of that ref touches no
# package file, cuts no release, and strands every consumer — the original
# DEV-1313 bug, reintroduced silently.
#
# --check-pins closes it WITHOUT reintroducing DEV-726. It reads the same
# changed-path list --check-routing does and judges only the workflows in it.
# Three properties are load-bearing and each has a case below:
#   * drift on a workflow THIS PR touched fails, naming it;
#   * drift on a workflow it did NOT touch is invisible (the DEV-726 shape);
#   * a MISSING pins.yml never fails, because the twelve files do not exist yet.

# The routing gate takes its diff on stdin; so does this one. Same helper shape.
check_pins() {
  local label="$1" expected="$2" repo="$3" must="$4" must_not="$5"
  shift 5
  local out status
  set +e
  out="$(printf '%s\n' "$@" | "${repo}/scripts/sync-workflow-checksums.sh" --check-pins 2>&1)"
  status=$?
  set -e
  verdict "$label" "$expected" "$status" "$out" "$must" "$must_not"
}

# A fixture whose workflows carry real, mirrorable dependencies — one plain
# `uses:` ref and one `with:` version key, the two halves of the mirror — so a
# case can drift either one. alpha and beta are identical on purpose: whichever
# one a case drifts, the other is the control that must stay unmentioned.
# Both pins files start in agreement, written by the real generator.
gate_fixture() {
  local dir name
  dir="$(fixture "$1" alpha beta)"
  for name in alpha beta; do
    cat >"${dir}/.github/workflows/${name}.yml" <<YAML
name: ${name}
on:
  workflow_call:
jobs:
  run:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v7
      - uses: actions/setup-python@v7
        with:
          python-version: "3.14"
YAML
  done
  (cd "$dir" && scripts/sync-workflow-checksums.sh >/dev/null)
  printf '%s\n' "$dir"
}

# The baseline: a workflow in the diff whose mirror still agrees. Without this
# the failing cases below could all be passing for the wrong reason (a gate that
# fails on everything is not a gate).
AGREE="$(gate_fixture pins-gate-agree)"
check_pins "a workflow in the diff whose pins file agrees passes" 0 "$AGREE" "" "" \
  .github/workflows/alpha.yml workflows/alpha/pins.yml workflows/alpha/workflow.sha256

# THE failure this gate exists for: a ref reaches the workflow and not the
# mirror, so Renovate will only ever see it in one place and its bump will not
# route. This is what an author regenerating nothing after a hand edit leaves.
DRIFTED="$(gate_fixture pins-gate-drifted)"
printf '      - uses: actions/setup-node@v6\n' >>"${DRIFTED}/.github/workflows/alpha.yml"

check_pins "a ref added to the workflow but not the mirror fails, naming the workflow" 1 \
  "$DRIFTED" "workflows/alpha/pins.yml disagrees with .github/workflows/alpha.yml" \
  "workflows/beta/pins.yml" \
  .github/workflows/alpha.yml workflows/alpha/workflow.sha256

# Actionable means three things, and each is separately droppable: the report
# has to name the ref that is missing, and it has to name the command that fixes
# it. A verdict of "something disagrees" sends the reader back to this script.
check_pins "the drift report shows the ref missing from the mirror" 1 "$DRIFTED" \
  "actions/setup-node@v6" "" \
  .github/workflows/alpha.yml
# Matched against the workflow's OWN path, not the bare command: the closing
# summary line names the command too, so a looser needle here would go on
# passing after the per-workflow message stopped saying what to commit.
check_pins "the drift report names the fix command and the file to commit" 1 "$DRIFTED" \
  "run scripts/sync-workflow-checksums.sh and commit workflows/alpha/pins.yml" "" \
  .github/workflows/alpha.yml

# The `with:` half of the mirror drifts independently of the `uses:` half, and it
# is the half that was missed once already (sast.yml's python-version). Here the
# ref set is IDENTICAL in both files and only the version key moved, so nothing
# but a full content comparison catches it.
WITHDRIFT="$(gate_fixture pins-gate-with-drift)"
sed -i.bak 's/python-version: "3.14"/python-version: "3.15"/' \
  "${WITHDRIFT}/.github/workflows/alpha.yml"
rm -f "${WITHDRIFT}/.github/workflows/alpha.yml.bak"

# Premise guards. The edit has to have landed, and the `uses:` set has to be
# UNCHANGED — otherwise this case would also pass under a generator that mirrored
# nothing but the refs, and would be no evidence for the `with:` half at all.
if ! grep -qF 'python-version: "3.15"' "${WITHDRIFT}/.github/workflows/alpha.yml"; then
  premise_gone "the with-drift fixture's python-version was not actually changed"
fi
if ! diff -q \
  <(grep -E '^[[:space:]]+- uses:' "${WITHDRIFT}/workflows/alpha/pins.yml") \
  <(grep -E '^[[:space:]]+- uses:' "${WITHDRIFT}/workflows/beta/pins.yml") >/dev/null; then
  premise_gone "the with-drift fixture moved a uses: ref too — the case no longer isolates the with: half"
fi

check_pins "a with: version key drifting is caught, not just uses: lines" 1 "$WITHDRIFT" \
  "workflows/alpha/pins.yml disagrees with" "workflows/beta/pins.yml" \
  .github/workflows/alpha.yml
check_pins "the with: drift report shows the version the workflow now asks for" 1 \
  "$WITHDRIFT" "3.15" "" \
  .github/workflows/alpha.yml

# A MISSING pins.yml must NOT fail. The twelve files do not exist on main yet —
# they land in the migration that follows — so a gate that errored on absence
# would break CI for every PR touching a workflow in the interim. It also stands
# on its own merits: no mirror is the pre-DEV-1313 world, where the consequence
# is caught loudly by --check-routing on the bot PR rather than slipping through.
GATE_MISSING="$(gate_fixture pins-gate-missing)"
rm -f "${GATE_MISSING}/workflows/alpha/pins.yml"

check_pins "a workflow in the diff with NO pins file warns but does not fail" 0 \
  "$GATE_MISSING" "workflows/alpha/pins.yml does not exist" "workflows/beta/pins.yml" \
  .github/workflows/alpha.yml workflows/alpha/workflow.sha256

# The whole-tree version of the same interim state: a repo with no pins files at
# all, which is exactly what main looks like today. Nothing may fail.
PINLESS="$(gate_fixture pins-gate-pinless)"
rm -f "${PINLESS}"/workflows/*/pins.yml
check_pins "a repo with no pins files anywhere cannot go red" 0 "$PINLESS" "" "" \
  .github/workflows/alpha.yml .github/workflows/beta.yml \
  workflows/alpha/workflow.sha256 workflows/beta/workflow.sha256

# --- DEV-726 again: drift elsewhere on main is not this PR's problem ---------
# beta's mirror goes stale on main. Under a whole-repo pins comparison — the
# obvious, wrong way to build this gate — every open PR would go red for it.
GATE_STALE="$(gate_fixture pins-gate-stale-on-main)"
printf '      - uses: actions/setup-node@v6\n' >>"${GATE_STALE}/.github/workflows/beta.yml"

# Premise guard: the drift has to be real, or every assertion below is vacuous.
if "${GATE_STALE}/scripts/sync-workflow-checksums.sh" --check >/dev/null 2>&1; then
  echo "FAIL: stale-pins fixture is not actually stale — --check should have failed" >&2
  exit 2
fi
echo "PASS: stale-pins fixture is genuinely stale (--check fails on it)"

# The positive control, and the reason the two cases after it are not vacuous:
# beta's OWN PR does fail. Delete the scope test and this still passes while the
# regression cases below go red — which is what makes them evidence.
check_pins "the drifted workflow's own PR does fail" 1 "$GATE_STALE" \
  "workflows/beta/pins.yml disagrees with" "" \
  .github/workflows/beta.yml workflows/beta/workflow.sha256

# THE regression test. A PR touching neither workflow passes, however stale
# beta's mirror is on main.
check_pins "an unrelated PR passes while another package's mirror is stale on main" 0 \
  "$GATE_STALE" "" "" \
  README.md

# ...and so does a PR on a DIFFERENT workflow, whose own mirror is fine.
check_pins "another workflow's PR passes while beta's mirror is stale on main" 0 \
  "$GATE_STALE" "" "" \
  .github/workflows/alpha.yml workflows/alpha/workflow.sha256

# A shipped asset is NOT in pins scope, even though it IS in routing scope. The
# two rules are different because their subjects are: routing asks what a commit
# must reach, and a prompt edit must reach the package; render_pins reads only
# the workflow YAML, so no prompt edit can change what the mirror should say.
# Scoping on assets would drag pre-existing drift into unrelated prompt PRs.
ASSET_DRIFT="$(fixture pins-gate-assets pepper-pr-review)"
mkdir -p "${ASSET_DRIFT}/prompts"
printf 'review prompt\n' >"${ASSET_DRIFT}/prompts/pr-review-default.md"
(cd "$ASSET_DRIFT" && scripts/sync-workflow-checksums.sh >/dev/null)
printf '    - uses: actions/checkout@v99\n' >>"${ASSET_DRIFT}/workflows/pepper-pr-review/pins.yml"

# Positive control first, or the case below passes for want of any drift at all.
check_pins "the drifted mirror fails when its own workflow YAML is in the diff" 1 \
  "$ASSET_DRIFT" "workflows/pepper-pr-review/pins.yml disagrees with" "" \
  .github/workflows/pepper-pr-review.yml workflows/pepper-pr-review/workflow.sha256

check_pins "a shipped-asset edit does not put a workflow in pins scope" 0 \
  "$ASSET_DRIFT" "" "" \
  prompts/pr-review-default.md workflows/pepper-pr-review/workflow.sha256

# ...while the SAME diff is very much in routing scope, which is the whole point
# of keeping the two gates apart.
check "the same shipped-asset edit is still in routing scope" 1 "$ASSET_DRIFT" \
  "no file under workflows/pepper-pr-review/ is" "" \
  prompts/pr-review-default.md

# The mirror itself, hand-edited, IS in scope on the PR that edits it — the one
# PR that can undo it. Note the workflow YAML is not in this diff at all.
GATE_HAND="$(gate_fixture pins-gate-hand-edited)"
printf '    - uses: actions/checkout@v99\n' >>"${GATE_HAND}/workflows/alpha/pins.yml"

check_pins "a hand-edited pins.yml is in scope on the PR that edits it" 1 "$GATE_HAND" \
  "workflows/alpha/pins.yml disagrees with" "workflows/beta/pins.yml" \
  workflows/alpha/pins.yml

# --check-pins stops before every whole-repo check in the script. An orphaned
# package dir is the ROUTING gate's diagnosis — that gate already runs in the
# same job — and repeating it here would give one repo-wide failure two chances
# to be misattributed to a pins problem, while making this mode depend on jq it
# has no use for.
GATE_ORPHAN="$(gate_fixture pins-gate-orphan)"
rm -f "${GATE_ORPHAN}/.github/workflows/beta.yml"

check "orphan control: --check-routing does report the stranded package dir" 1 \
  "$GATE_ORPHAN" "workflows/beta/ has no matching reusable workflow" "" \
  .github/workflows/beta.yml
check_pins "--check-pins makes no whole-repo inventory claim" 0 "$GATE_ORPHAN" "" "" \
  .github/workflows/alpha.yml workflows/alpha/pins.yml

# The unmirrorable-dep warning finally has a PR-scoped home. `runs-on:` and
# `container:` deps are real to Renovate and structurally cannot live in a
# composite-shaped mirror; the generator has always said so, but only to whoever
# ran it. Diff-scoped, the hole is now reported on the PR that opens it. Still a
# warning — there is no edit the author could make to fix it.
GATE_HOLE="$(gate_fixture pins-gate-unmirrorable)"
cat >"${GATE_HOLE}/.github/workflows/alpha.yml" <<'YAML'
name: alpha
on:
  workflow_call:
jobs:
  pinned-runner:
    runs-on: ubuntu-24.04
    steps:
      - uses: actions/checkout@v7
YAML
(cd "$GATE_HOLE" && scripts/sync-workflow-checksums.sh >/dev/null 2>&1)

check_pins "an unmirrorable dep is reported on the PR that opens it" 0 "$GATE_HOLE" \
  "cannot mirror" "" \
  .github/workflows/alpha.yml workflows/alpha/pins.yml

# ...and not on a PR that touches some other workflow, like every other claim
# this mode makes.
check_pins "an unmirrorable dep is not reported to an unrelated PR" 0 "$GATE_HOLE" \
  "" "cannot mirror" \
  .github/workflows/beta.yml workflows/beta/pins.yml

# Same vacuity guard as --check-routing has: a PR always changes something, so an
# empty list means the caller's merge base was wrong. Green-on-no-input is worse
# than no gate.
set +e
out="$("${AGREE}/scripts/sync-workflow-checksums.sh" --check-pins </dev/null 2>&1)"
status=$?
set -e
if [ "$status" -eq 2 ] && grep -qF -- "read no changed paths on stdin" <<<"$out"; then
  echo "PASS: --check-pins treats an empty diff as a hard error, not a pass"
else
  echo "FAIL: --check-pins treats an empty diff as a hard error, not a pass"
  echo "  expected exit 2, got ${status}"
  indent "${out}"
  fails=$((fails + 1))
fi

# --- the two gates stay separate --------------------------------------------
# --check-routing is the ROUTING gate and was narrowed to that on purpose
# (DEV-1311). Pins drift is a content problem; folding it in would blur the
# diagnosis and cost --check-routing its no-dependencies property below. Every
# fixture above that FAILS --check-pins must still PASS --check-routing when it
# routes, and vice versa.
check "pins drift does not fail the routing gate" 0 "$DRIFTED" "" "" \
  .github/workflows/alpha.yml workflows/alpha/workflow.sha256
check "with: drift does not fail the routing gate" 0 "$WITHDRIFT" "" "" \
  .github/workflows/alpha.yml workflows/alpha/workflow.sha256
check "a hand-edited pins.yml does not fail the routing gate" 0 "$GATE_HAND" "" "" \
  workflows/alpha/pins.yml
# The converse: a workflow edit that does not route fails the ROUTING gate, and
# the pins gate says nothing about it — its mirror is fine.
check "an unrouted workflow edit is the routing gate's diagnosis" 1 "$AGREE" \
  "no file under workflows/alpha/ is" "" \
  .github/workflows/alpha.yml
check_pins "...and the pins gate stays silent about it" 0 "$AGREE" "" "" \
  .github/workflows/alpha.yml

# --- --check-routing must stay free of yq -----------------------------------
# The routing gate has to keep working on a machine with nothing installed; only
# the pins modes render YAML. Assert it by actually removing yq from PATH rather
# than by reading the code, because that guard is one `if` away from being lost.
NOYQ_BIN="${TMP}/no-yq-bin"
mkdir -p "$NOYQ_BIN"
for tool in bash env grep sort basename dirname cat sed awk diff jq; do
  tool_path="$(command -v "$tool")" ||
    premise_gone "${tool} is not on PATH — the yq-free PATH case cannot be built"
  ln -sf "$tool_path" "${NOYQ_BIN}/${tool}"
done
if (PATH="$NOYQ_BIN"; command -v yq >/dev/null 2>&1); then
  premise_gone "the constructed yq-free PATH still resolves yq"
fi

set +e
out="$(printf 'README.md\n' |
  PATH="$NOYQ_BIN" "${PINLESS}/scripts/sync-workflow-checksums.sh" --check-routing 2>&1)"
status=$?
set -e
if [ "$status" -eq 0 ]; then
  echo "PASS: --check-routing passes with no yq on PATH and no pins files"
else
  echo "FAIL: --check-routing passes with no yq on PATH and no pins files"
  echo "  expected exit 0, got ${status}"
  indent "${out}"
  fails=$((fails + 1))
fi

# The other side of the same guard: --check-pins DOES need yq, and says so
# instead of silently skipping the `with:` half — which would make it green on a
# mirror missing exactly the dep it exists to catch.
set +e
out="$(printf '.github/workflows/alpha.yml\n' |
  PATH="$NOYQ_BIN" "${AGREE}/scripts/sync-workflow-checksums.sh" --check-pins 2>&1)"
status=$?
set -e
if [ "$status" -eq 2 ] && grep -qF -- "yq" <<<"$out"; then
  echo "PASS: --check-pins refuses to run without yq rather than half-checking"
else
  echo "FAIL: --check-pins refuses to run without yq rather than half-checking"
  echo "  expected exit 2 naming yq, got ${status}"
  indent "${out}"
  fails=$((fails + 1))
fi

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
