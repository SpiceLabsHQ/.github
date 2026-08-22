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
#   Completeness is the whole point, and it is the ONLY thing standing between a
#   bot bump and a silently uncut release. `Versioning integrity` is not a
#   REQUIRED status check on this repo — PRs have merged with it red — so an
#   unmirrored dependency does not block anything. The bump merges, the release
#   is never cut, and the only trace is a red X on a merged PR nobody is paged
#   about. Nothing downstream catches an omission here. Get it right at source.
#
#   "Every ref Renovate can bump" is therefore broader than "the SHA-pinned
#   third-party actions", and broader than "the `uses:` lines". Renovate's
#   github-actions manager runs TWO extraction passes over every file:
#
#     extractPackageFile() = extractWithRegex() + extractWithYAMLParser()
#     (renovate/dist/modules/manager/github-actions/extract.js, 44.39.1)
#
#     * extractWithRegex is the line regex documented on workflow_steps(). Plain
#       `uses:` action refs — depType "action" — come ONLY from this pass.
#     * extractWithYAMLParser really does parse the YAML, and it is where
#       jobs.*.runs-on ("github-runner"), jobs.*.container, jobs.*.services and
#       `uses-with` deps come from. An earlier version of this comment claimed
#       Renovate "never parses the YAML"; that was false, and it is exactly the
#       sentence a future maintainer would have used to dismiss a real bump as
#       impossible. It cost us one: actions/setup-python@v7 with
#       `python-version: "3.14"` in sast.yml is a fully-formed managed dep
#       (github-releases / actions/python-versions), and it was not mirrored.
#
#   So the mirror carries `uses:` refs AND the `with:` values Renovate reads —
#   see workflow_steps() and workflow_with_pairs() for the two rules.
#
#   ONE KNOWN LIMITATION, stated rather than hidden. A pins.yml cannot mirror a
#   `runs-on:`, `container:` or `services:` dep, because those exist only under
#   a `jobs:` key and giving this file a `jobs:` key would manufacture a runner
#   dependency out of nothing (see render_pins). Today no reusable workflow has
#   one that Renovate would act on: `runs-on: ubuntu-latest` extracts as
#   github-runner:ubuntu@latest and is skipped as `invalid-version`. The moment
#   someone writes `runs-on: ubuntu-24.04`, or adds a container/services block,
#   that becomes a live bumpable dep with no mirror and its bump will not route.
#   unmirrorable_deps() warns on exactly that, in both sync and --check, because
#   the alternative is silence.
#
#   Enforcement is DIFF-SCOPED and lives in its own mode: --check-pins
#   (DEV-1314). It reads the same changed-path list --check-routing does, and
#   asks one question per workflow THIS PR actually touched — does
#   workflows/<name>/pins.yml still say what the generator would write from
#   .github/workflows/<name>.yml? The PR that edits a workflow is the one PR
#   that can fix its mirror, and the only PR that should be asked to.
#
#   Why a separate mode and not part of --check-routing: --check-routing is the
#   routing gate. It never hashes and never renders, it answers exactly one
#   question ("does this diff reach the package directory?"), and it has to keep
#   working on a machine with nothing installed — no yq, no pins file. Folding a
#   content comparison into it would blur the diagnosis and take that property
#   away. Two gates, two vocabularies, two verdicts.
#
#   Why not whole-repo: a whole-repo pins comparison would let one package's
#   drift fail every unrelated open PR, which is precisely the DEV-726 blast
#   radius DEV-1311 removed from this script. Do not reintroduce it. `--check`
#   keeps the whole-repo pins view for a human who asks for it, and is
#   deliberately run by no workflow.
#
#   In both modes a MISSING pins.yml is only a WARNING. It degrades to the
#   pre-DEV-1313 world, where the consequence is caught loudly by
#   --check-routing on the bot PR itself; and it is the interim state between
#   the generator landing and the twelve files being committed, where a hard
#   error would turn CI red for everyone in between. A pins.yml that DISAGREES
#   is the dangerous state and is an ERROR: it routes — any file in the package
#   dir does — so the routing gate goes green while Renovate bumps refs the
#   workflow no longer has, or silently misses ones it does.
#
# Usage:
#   scripts/sync-workflow-checksums.sh          # rewrite checksum + pins files in place
#   scripts/sync-workflow-checksums.sh --check  # whole-repo hash/pins view; exit 1 on drift
#   git diff --name-only "origin/$base...HEAD" |
#     scripts/sync-workflow-checksums.sh --check-routing   # the PR routing gate
#   git diff --name-only "origin/$base...HEAD" |
#     scripts/sync-workflow-checksums.sh --check-pins      # the PR pins-agreement gate
#
# Requirements: sha256sum or shasum. The script never invokes git — the diff
# arrives as data on stdin, which is what lets the fixture tests drive every
# case with plain path lists. `--check` and `--check-routing` additionally need
# jq to validate release-please-config.json / .release-please-manifest.json
# coverage. Sync, `--check` and `--check-pins` also need yq (mikefarah v4) —
# all three write or verify pins.yml, and the `with:` half of that mirror has to
# come from a real YAML parser because that is where Renovate reads it from.
# Both tools are preinstalled on ubuntu-latest, an assumption
# scripts/check-bot-allowlists.sh and scripts/org-repo-settings-reconcile.sh
# already make. `--check-routing`, the routing gate, still needs neither yq nor
# a pins file; `--check-pins` needs yq but not jq, since it makes no
# whole-repo inventory claim.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

MODE=sync
case "${1:-}" in
  --check) MODE=check ;;
  --check-routing) MODE=check-routing ;;
  --check-pins) MODE=check-pins ;;
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

# Sync, --check and --check-pins all render pins.yml, whose `with:` half needs a
# real YAML parser. Hard-error rather than degrade: silently skipping the `with:`
# pairs would reproduce the exact omission (a live setup-python dep left
# unmirrored) that this file's header exists to explain — and in --check-pins it
# would be worse than the omission, because the gate would then go green on a
# mirror missing exactly the dep it was added to catch. --check-routing renders
# nothing and is deliberately left alone — it is the routing gate and must keep
# working on a machine with nothing installed.
if [ "$MODE" != check-routing ]; then
  command -v yq >/dev/null 2>&1 || {
    echo "ERROR: yq (mikefarah v4) is required to write or verify workflows/*/pins.yml" >&2
    exit 2
  }
fi

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

# Pass 1 of the mirror: the `uses:` refs, deduplicated, in the order they appear
# after sorting.
#
# This is Renovate's own extractWithRegex(), reimplemented. That pass is a LINE
# regex and never looks at the YAML structure:
#
#   /^(?<prefix>\s+(?:-\s+)?uses\s*:\s*)(?<remainder>.+)$/     (parse.js)
#
# Three consequences are load-bearing:
#
#   * The leading whitespace is REQUIRED. A `uses:` in column 0 is silently NOT
#     extracted. That is why render_pins() indents its steps, and why matching
#     the same rule here keeps the mirror a mirror — the same set Renovate sees
#     in the workflow, no more and no less.
#   * A line whose remainder starts with `#` is not a ref, and a line that is
#     itself a comment cannot match at all (the `#` would be the first non-space
#     character). Shell strings and comments that merely CONTAIN "uses:" —
#     actions-audit.yml is full of them — do not match either, because the line
#     has to START with `uses:` after its indent.
#   * Local refs (`./...`, `../...`) parse as kind "local", which
#     extractWithRegex drops. They carry no version and no datasource, so
#     Renovate can never open a bump PR for one and there is no commit for it to
#     route. Everything else is kept: subpaths, first-party major tags, explicit
#     hostnames, `docker://` refs.
#
# The remainder is copied VERBATIM — SHA, trailing `# vX.Y.Z` comment, quoting
# and all — because Renovate rewrites that whole remainder in both files, and
# reformatting here would show up as permanent drift after the first bump.
#
# Emits one line per step: the verbatim remainder, a tab, then the step's
# Renovate-visible `with:` pairs (see workflow_with_pairs) if it has any.
workflow_steps() {
  local file="$1" pairs
  pairs="$(workflow_with_pairs "$file")"

  # Via the environment, not `awk -v`: BWK awk (the /usr/bin/awk every macOS
  # ships) rejects a -v value containing a newline with "newline in string",
  # and this value is a multi-line record set.
  PAIRS="$pairs" awk '
    # Renovate keys `with:` lookups by the parsed action reference, i.e. the
    # remainder minus its trailing comment and surrounding quotes. Mirror that,
    # or the join below misses every SHA-pinned step (all of which carry a
    # comment) and every quoted one.
    function refkey(r,   v, ci, f, l) {
      ci = index(r, " #")
      v = (ci > 0) ? substr(r, 1, ci - 1) : r
      gsub(/^[[:space:]]+/, "", v)
      gsub(/[[:space:]]+$/, "", v)
      f = substr(v, 1, 1)
      l = substr(v, length(v), 1)
      if (length(v) >= 2 && f == l && (f == "\"" || f == "'"'"'")) {
        v = substr(v, 2, length(v) - 2)
      }
      return v
    }
    BEGIN {
      n = split(ENVIRON["PAIRS"], lines, "\n")
      for (i = 1; i <= n; i++) {
        j = index(lines[i], "\t")
        if (j == 0) continue
        tail = substr(lines[i], j + 1)
        # A step with no Renovate-visible `with:` key is reported by yq with an
        # empty tail; it needs no `with:` block in the mirror, and giving it one
        # would make it visible to Renovate'"'"'s YAML pass for no reason.
        if (tail == "") continue
        withs[substr(lines[i], 1, j - 1), ++count[substr(lines[i], 1, j - 1)]] = tail
      }
    }
    match($0, /^[[:space:]]+(-[[:space:]]+)?uses[[:space:]]*:[[:space:]]*/) {
      ref = substr($0, RSTART + RLENGTH)
      sub(/[[:space:]]+$/, "", ref)
      if (ref == "" || substr(ref, 1, 1) == "#") next
      k = refkey(ref)
      if (k ~ /^\.\.?\//) next
      if (count[k] > 0) {
        for (i = 1; i <= count[k]; i++) print ref "\t" withs[k, i]
      } else {
        print ref
      }
    }
  ' "$file" | LC_ALL=C sort -u
}

# Pass 2 of the mirror: the `with:` values Renovate turns into "uses-with" deps.
#
# extractWithYAMLParser() -> extractSteps() gives every step two chances at a
# dep beyond its action ref:
#
#   * extractVersionedAction(), whose built-in table is
#     `versionedActions = { go, node, python }` — i.e. actions/setup-go,
#     actions/setup-node and actions/setup-python, read from
#     `with.<lang>-version`.
#   * CommunityActions, a table of 25 community actions in community.js, each
#     declaring which `with:` key carries its version.
#
# Rather than restate those 28 action names — a list that grows with every
# Renovate release and would rot silently the day it did — this matches on the
# KEY NAMES those tables read, which is a much smaller and far more stable set.
# The asymmetry is deliberate and is the safe one: mirroring a `with: version:`
# for an action Renovate does not know is inert (both tables key on the action
# name, so neither produces a dep from it, in the workflow or in the mirror),
# while FAILING to mirror one is the silent uncut release this whole file exists
# to prevent.
#
# The keys, read off renovate 44.39.1's community.js + extract.js:
#   version          the default for every community action
#   go/node/python-version                    extractVersionedAction
#   deno-version bun-version ruby-version pixi-version toolchain cosign-release
#                                             per-action withSchema overrides
#   repo tag         jaxxstorm/action-install-gh-release, sigoden/install-binary
#   version sha256   jdx/mise-action
#   version runtime  pnpm/setup
#
# Read with a real YAML parser, not a line regex, because that is how Renovate
# reads it: a `with:` block is associated with its step by YAML structure, and
# no amount of line matching gets that association reliably right.
RENOVATE_WITH_KEYS='^(version|go-version|node-version|python-version|deno-version|bun-version|ruby-version|pixi-version|toolchain|cosign-release|repo|tag|sha256|runtime)$'

# Emits `<uses value>\t<key>=<value>[\t<key>=<value>...]`, one line per step
# that has a `uses:`; the tail is empty for a step with no such key, and the
# caller drops those. Recursive descent rather than `.jobs[].steps[]` so a step
# nested in a `parallel:` block — which Renovate's ParallelStep schema also
# walks — is not missed. Pairs are sorted so the output is stable regardless of
# the order the keys appear in the workflow.
workflow_with_pairs() {
  yq -r "
    .. | select(tag == \"!!map\" and has(\"uses\")) |
    .uses as \$u |
    ([ (.with // {}) | to_entries | .[] |
       select(.key | test(\"${RENOVATE_WITH_KEYS}\")) |
       .key + \"=\" + (.value | tostring) ] | sort) as \$p |
    \$u + \"\t\" + (\$p | join(\"\t\"))
  " "$1"
}

# Deps in a workflow that a pins.yml structurally CANNOT mirror: they live under
# a `jobs:` key, and giving pins.yml a `jobs:` key would manufacture a runner
# dependency with no twin in the workflow — see render_pins. Warn rather than
# fail: unlike the ignorePaths collision below there is no fix the author can
# apply, so a hard error would be a dead end. What the warning buys is that the
# hole is visible on the PR that opens it instead of on some bot PR months later.
#
# `runs-on: ubuntu-latest` is not one of these: it extracts as
# github-runner:ubuntu@latest and Renovate skips it as `invalid-version`. The
# heuristic below — a digit immediately after the runner's dash — is a
# deliberately conservative stand-in for that versioning check, and its only
# failure mode is an extra warning.
unmirrorable_deps() {
  local file="$1"
  yq -r '
    [ .jobs[]? | ([."runs-on"] | flatten | .[] | select(. != null) | tostring) ] | .[]
  ' "$file" 2>/dev/null | grep -E '^[A-Za-z]+-[0-9]' | sed 's/^/runs-on: /' || true
  yq -r '
    .jobs[]? | to_entries | .[] | select(.key == "container" or .key == "services") | .key
  ' "$file" 2>/dev/null | sort -u | sed 's/$/:/' || true
}

# The exact intended content of workflows/<name>/pins.yml, on stdout. Sync
# writes it; --check compares against it. One producer, so the two can't drift.
#
# THE SHAPE IS LOAD-BEARING, and not for the reason you might guess. Renovate's
# YAML pass parses this file against a union that tries `{jobs: ...}` first and
# `{runs: {using, steps}}` second (schema.js). Under the composite shape it
# matches the second, which has no runs-on / container / services concept at
# all, so the YAML pass can produce nothing here but the `uses-with` deps below.
# Give the file a `jobs:` key instead and it matches the FIRST branch, and every
# generated file acquires a github-runner dep with no twin in any workflow,
# recurring on every Ubuntu release.
#
# Note also that the YAML pass sees a step only if it has a `with:` key
# (`UsesStep` requires one), so the bare `- uses:` steps below are invisible to
# it and are read purely by the line-regex pass. Adding `with:` is precisely
# what makes a step visible to the YAML pass — which is the point, since that is
# the only pass that produces `uses-with` deps.
render_pins() {
  local name="$1" steps
  steps="$(workflow_steps ".github/workflows/$name.yml")"

  cat <<EOF
# GENERATED FILE — do not edit by hand.
# Written by scripts/sync-workflow-checksums.sh from .github/workflows/$name.yml.
#
# GitHub Actions never executes this file, and nothing here affects what
# $name.yml does. It exists so Renovate has something to edit INSIDE
# workflows/$name/ when it bumps a dependency $name.yml uses. release-please
# routes commits to packages by directory path, so a bump touching only the
# workflow YAML would reach no package — no release, no tag, and every repo
# pinned to the moving $name-vN alias would keep the old version. Renovate is
# pointed here by managerFilePatterns in .github/renovate.json and manages each
# entry below independently of its twin in the workflow, which is why a single
# bump PR updates both files.
#
# The steps mirror $name.yml's \`uses:\` refs, plus the \`with:\` values Renovate
# reads as versions (\`python-version\` and friends). The composite-action shape
# is deliberate: it is the one shape whose schema has no runs-on / container /
# services concept, so this file cannot acquire a runner dependency that no
# workflow actually has. The indentation is required too — Renovate does not
# extract a \`uses:\` written in column 0.
runs:
  using: composite
EOF

  if [ -z "$steps" ]; then
    # A workflow with no bumpable dependency still gets a file, so the package
    # directory's shape never depends on today's action inventory. `steps: []`
    # rather than omitting the key: `runs.steps` is optional in the schema, but
    # an explicit empty list says "nothing to mirror" instead of "nobody has
    # looked at this yet".
    printf '  steps: []\n'
    return
  fi

  printf '  steps:\n'
  printf '%s\n' "$steps" | awk '
    function emit(v,   s) {
      s = v
      gsub(/\\/, "\\\\", s)
      gsub(/"/, "\\\"", s)
      return "\"" s "\""
    }
    {
      n = split($0, f, "\t")
      printf "    - uses: %s\n", f[1]
      if (n < 2) next
      printf "      with:\n"
      for (i = 2; i <= n; i++) {
        j = index(f[i], "=")
        if (j == 0) continue
        printf "        %s: %s\n", substr(f[i], 1, j - 1), emit(substr(f[i], j + 1))
      }
    }
  '
}

# Package directory names config:recommended's ignorePaths would make Renovate
# skip. workflows/<name>/pins.yml sits under <name>, so a workflow named any of
# these has a pins.yml Renovate silently never reads — its bumps stop routing
# with no error anywhere. Nothing collides today; this is here because the
# failure would be invisible and the check costs nothing. Unlike
# unmirrorable_deps() above this one IS a hard error under --check, because it
# has a fix: rename the workflow.
renovate_ignores_name() {
  case "$1" in
    node_modules|bower_components|vendor|examples|__tests__|test|tests|__fixtures__)
      return 0
      ;;
  esac
  return 1
}

# One warning per unmirrorable dep found in a workflow, naming it. Shared by
# sync and --check so the hole shows up whichever one the author runs.
warn_unmirrorable() {
  local name="$1" file="$2" dep
  while IFS= read -r dep; do
    [ -n "$dep" ] || continue
    warn "$file declares '$dep', which Renovate extracts as a bumpable dependency but workflows/$name/pins.yml structurally cannot mirror (it has no jobs: key, deliberately) — a bump to it will not route and will cut no $name release"
  done < <(unmirrorable_deps "$file")
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

# --- the diff (--check-routing and --check-pins) ----------------------------
# The changed paths arrive on stdin, one per line — exactly
# `git diff --name-only <merge-base>...HEAD`. The script deliberately does not
# shell out to git: the caller already knows the merge base, and taking the list
# as data keeps every case in scripts/test/sync-workflow-checksums_test.sh a
# handful of strings instead of a synthetic history.
#
# Both diff-scoped modes read it the same way, so the CI job computes the diff
# once and feeds the same file to both.
changed=()
if [ "$MODE" = check-routing ] || [ "$MODE" = check-pins ]; then
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    changed+=("$path")
  done
  # A pull request always changes something, so an empty list means the caller's
  # merge base was wrong or its checkout was too shallow. Refuse to pass
  # vacuously — a gate that is silently green is worse than no gate at all.
  if [ "${#changed[@]}" -eq 0 ]; then
    echo "ERROR: --$MODE read no changed paths on stdin; expected the output of 'git diff --name-only <merge-base>...HEAD'" >&2
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

# --check-pins scope: the workflows whose mirror THIS PR could have invalidated.
# Two paths put a workflow in scope, and only two:
#
#   * .github/workflows/<name>.yml — the file pins.yml is generated FROM. Edit it
#     and the mirror is stale until it is regenerated. (A shipped asset, e.g. one
#     of pepper-pr-review's prompts, is NOT in scope: render_pins reads only the
#     YAML, so no asset edit can change what the mirror should say.)
#   * workflows/<name>/pins.yml — the mirror itself. A hand-edit is drift the PR
#     making it introduced, and this is the PR that can undo it.
#
# Everything else is out of scope by construction. In particular a pins.yml that
# was already stale on main, for a workflow this PR never touched, is invisible
# here — that whole-repo shape is DEV-726 and stays in --check.
pins_in_scope() {
  local name="$1" path
  for path in ${changed[@]+"${changed[@]}"}; do
    case "$path" in
      ".github/workflows/$name.yml" | "workflows/$name/pins.yml") return 0 ;;
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

  if [ "$MODE" = check-pins ]; then
    # A workflow the PR DELETED never reaches here — reusable_workflows() reads
    # the PR head — which is right: there is no mirror left to disagree with
    # anything, and a stranded package dir is the orphan check's diagnosis under
    # --check-routing, not this one's.
    pins_in_scope "$name" || continue

    # Diff-scoped, so this is finally the place the unmirrorable-dep warning was
    # always meant to land: on the PR that opens the hole, not on a bot PR months
    # later. Still a warning — there is no edit the author can make to fix it.
    warn_unmirrorable "$name" "$file"

    if [ ! -f "$dir/pins.yml" ]; then
      # Missing is a WARNING, never a failure. See the header: this is the
      # interim state before the twelve files are committed, and it is also the
      # merely-degraded state (Renovate manages the refs in one place instead of
      # two) whose consequence --check-routing already catches loudly on the bot
      # PR. Failing here would turn CI red on every PR that touches a workflow.
      warn "$dir/pins.yml does not exist, so Renovate action bumps for $name will not route on their own — run scripts/sync-workflow-checksums.sh and commit $dir/pins.yml"
      continue
    fi

    expected_pins="$(render_pins "$name")"
    if [ "$(cat "$dir/pins.yml")" != "$expected_pins" ]; then
      # The diff is the actionable part: it names the ref or `with:` value that
      # is in one file and not the other, which is the thing that will fail to
      # route. `<` lines are what the mirror says now, `>` what it must say.
      fail "$dir/pins.yml disagrees with $file, which this PR changes — pins.yml is the generated mirror Renovate bumps so that a bump lands inside $dir/ and cuts a $name release; a ref or version key missing from it bumps only $file, routes nowhere, and strands every consumer pinned to the moving $name-vN alias. Fix: run scripts/sync-workflow-checksums.sh and commit $dir/pins.yml (it is generated, not hand-edited).
$(diff "$dir/pins.yml" <(printf '%s\n' "$expected_pins") | sed 's/^/  /' || true)"
    fi
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
    warn_unmirrorable "$name" "$file"
  else
    mkdir -p "$dir"
    printf '%s\n' "$expected" > "$dir/workflow.sha256"
    echo "synced $dir/workflow.sha256"
    render_pins "$name" > "$dir/pins.yml"
    echo "synced $dir/pins.yml"
    if renovate_ignores_name "$name"; then
      warn "workflows/$name/ matches an ignorePaths entry inherited from config:recommended — Renovate will never read $dir/pins.yml, so bumps to $file will not route"
    fi
    warn_unmirrorable "$name" "$file"
  fi
done < <(reusable_workflows)

# --check-pins stops here, before every whole-repo check below. That is the
# point of the mode: it makes exactly one claim, about exactly the workflows in
# this PR's diff. The orphan and release-please inventory checks below are
# whole-repo by necessity, they already run on every PR under --check-routing in
# the same job, and duplicating them here would only give the same repo-wide
# failure two chances to be attributed to a pins problem it has nothing to do
# with.
if [ "$MODE" = check-pins ]; then
  if [ "$errors" -gt 0 ]; then
    echo "" >&2
    echo "$errors pins-agreement error(s). Fix: run scripts/sync-workflow-checksums.sh and commit the regenerated workflows/*/pins.yml." >&2
    exit 1
  fi
  if [ "$warnings" -gt 0 ]; then
    echo "OK: every pins file for a workflow this PR touches agrees with it, but $warnings warning(s) above are worth reading."
  else
    echo "OK: every pins file for a workflow this PR touches agrees with it."
  fi
  exit 0
fi

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
