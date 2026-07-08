#!/usr/bin/env bash
# Fixture tests for the pr-hygiene size-check logic (DEV-550). The size logic
# lives inline in the `run:` block of pr-hygiene.yml's `size` job (the job has
# no checkout, so the logic can't be a separate script the workflow calls at
# runtime). To test the EXACT code that ships without duplicating it, this
# harness extracts that step's `run:` script AND the real `size_exclude_pattern`
# default straight from the YAML, then drives it with a stubbed `gh` that emits
# fixture file lists. Any drift in thresholds, the exclusion, variant selection,
# or the no-comment path fails CI.
#
# The seam is the post-`--jq` TSV (`<file>\t<add>\t<del>`): the stub stands in
# for `gh api ... --jq`, so the trivial jq field-projection isn't exercised, but
# the awk/grep/variant logic that carries the risk is.
#
# Run locally:  .github/workflows/test/pr-hygiene-size-test.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
YAML="${HERE}/../pr-hygiene.yml"
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1" >&2; fails=$((fails + 1)); }
assert_eq()           { if [ "$1" = "$2" ]; then pass "$3"; else fail "$3 — got [$1] want [$2]"; fi; }
assert_contains()     { case "$1" in *"$2"*) pass "$3" ;; *) fail "$3 — expected to contain: $2";; esac; }
assert_not_contains() { case "$1" in *"$2"*) fail "$3 — expected NOT to contain: $2";; *) pass "$3" ;; esac; }

# --- pull the shipping script + real exclude default out of the workflow ------
python3 - "${YAML}" "${WORK}" <<'PY'
import sys, yaml
doc = yaml.safe_load(open(sys.argv[1]))
work = sys.argv[2]
on = doc.get("on") or doc.get(True)  # YAML parses bare `on:` as the bool True
size = doc["jobs"]["size"]
step = next(s for s in size["steps"] if s.get("id") == "size")
open(f"{work}/size.sh", "w").write(step["run"])
excl = on["workflow_call"]["inputs"]["size_exclude_pattern"]["default"]
open(f"{work}/exclude.txt", "w").write(excl)
PY
[ -s "${WORK}/size.sh" ] || { echo "FAIL: could not extract size step run script" >&2; exit 1; }
EXCLUDE="$(cat "${WORK}/exclude.txt")"

# --- stub gh: prints the fixture TSV named by $FIXTURE (ignores all args) ------
mkdir -p "${WORK}/bin"
cat > "${WORK}/bin/gh" <<'SH'
#!/usr/bin/env bash
cat "${FIXTURE}"
SH
chmod +x "${WORK}/bin/gh"

# run_size <fixture-tsv-file> <loc-threshold> <file-threshold>
#   Executes the extracted script and echoes the resulting GITHUB_OUTPUT.
run_size() {
  local out="${WORK}/gh_output.txt"
  : > "${out}"
  PATH="${WORK}/bin:${PATH}" \
  RUNNER_TEMP="${WORK}" GITHUB_OUTPUT="${out}" \
  REPO="x/y" PR_NUMBER=1 \
  LOC_THRESHOLD="$2" FILE_THRESHOLD="$3" EXCLUDE="${EXCLUDE}" \
  FIXTURE="$1" \
    bash "${WORK}/size.sh" >/dev/null 2>&1
  cat "${out}"
}
kv()  { printf '%s\n' "$1" | sed -n "s/^$2=//p" | head -1; }         # output var
# message body sits between the heredoc delimiters GitHub Actions uses
msg() { printf '%s\n' "$1" | awk '/^message<<PR_SIZE_MSG_EOF$/{f=1;next} /^PR_SIZE_MSG_EOF$/{f=0} f'; }

# --- A: exclusion + LOC-only variant -----------------------------------------
# app.ts 1050 + api.ts 160 = 1210 real LOC / 2 files; lockfile (3800) and
# minified dist file (510) must be dropped from BOTH counts.
printf 'src/app.ts\t900\t150\nsrc/api.ts\t120\t40\npnpm-lock.yaml\t2000\t1800\ndist/b.min.js\t500\t10\n' > "${WORK}/fa.tsv"
out="$(run_size "${WORK}/fa.tsv" 1000 25)"; m="$(msg "$out")"
assert_eq "$(kv "$out" loc)" "1210" "A: generated/vendored excluded from line count (1210, not 5520)"
assert_eq "$(kv "$out" files)" "2" "A: generated/vendored excluded from file count (2, not 4)"
assert_eq "$(kv "$out" over_threshold)" "true" "A: over threshold"
assert_contains "$m" "1000 lines changed" "A: LOC-variant lead names the line threshold"
assert_contains "$m" "lot of changed code in one PR" "A: LOC-variant diagnosis"
assert_not_contains "$m" "a lot of files across the project" "A: not the files variant"
assert_not_contains "$m" "both large and spread across" "A: not the both variant"

# --- B: files-only variant ----------------------------------------------------
# 30 tiny files, 300 LOC: under the line threshold, over the file threshold.
: > "${WORK}/fb.tsv"; for i in $(seq 1 30); do printf 'pkg/f%s.go\t5\t5\n' "$i" >> "${WORK}/fb.tsv"; done
out="$(run_size "${WORK}/fb.tsv" 1000 25)"; m="$(msg "$out")"
assert_eq "$(kv "$out" loc)" "300" "B: line count 300"
assert_eq "$(kv "$out" files)" "30" "B: file count 30"
assert_eq "$(kv "$out" over_threshold)" "true" "B: over threshold (files only)"
assert_contains "$m" "touches more files than the org flags" "B: files-variant lead"
assert_contains "$m" "a lot of files across the project" "B: files-variant diagnosis"
assert_not_contains "$m" "lot of changed code in one PR" "B: not the LOC variant"

# --- C: both variant ----------------------------------------------------------
: > "${WORK}/fc.tsv"; for i in $(seq 1 30); do printf 'pkg/f%s.go\t50\t50\n' "$i" >> "${WORK}/fc.tsv"; done
out="$(run_size "${WORK}/fc.tsv" 1000 25)"; m="$(msg "$out")"
assert_eq "$(kv "$out" over_threshold)" "true" "C: over threshold (both)"
assert_contains "$m" "both large and spread across" "C: both-variant diagnosis"
assert_contains "$m" "1000 lines and 25 files" "C: both-variant lead names both limits"

# --- D: under both thresholds -> no comment -----------------------------------
printf 'src/app.ts\t10\t5\n' > "${WORK}/fd.tsv"
out="$(run_size "${WORK}/fd.tsv" 1000 25)"
assert_eq "$(kv "$out" over_threshold)" "false" "D: under threshold reports false"
assert_not_contains "$out" "message<<" "D: no sticky-comment message emitted when under"

# --- E: a pure lockfile bump excludes to nothing ------------------------------
printf 'pnpm-lock.yaml\t3000\t3000\n' > "${WORK}/fe.tsv"
out="$(run_size "${WORK}/fe.tsv" 1000 25)"
assert_eq "$(kv "$out" loc)" "0" "E: all-generated PR counts 0 lines"
assert_eq "$(kv "$out" files)" "0" "E: all-generated PR counts 0 files"
assert_eq "$(kv "$out" over_threshold)" "false" "E: pure lockfile bump does not trip the warning"

# --- F: rendered markdown is clean (no accidental code-block indentation) ------
out="$(run_size "${WORK}/fa.tsv" 1000 25)"; m="$(msg "$out")"
assert_eq "$(printf '%s\n' "$m" | head -1)" "### Large PR — size check (non-blocking)" "F: header is the first line, at column 0"
indented="$(printf '%s\n' "$m" | grep -cE '^[[:space:]]+(#|\*|-|This PR|More on)' || true)"
assert_eq "$indented" "0" "F: no message line is indented (would become a code block)"

if [ "${fails}" -gt 0 ]; then
  echo "" >&2; echo "${fails} assertion(s) failed." >&2; exit 1
fi
echo "All pr-hygiene size fixture assertions passed."
