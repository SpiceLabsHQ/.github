#!/usr/bin/env bash
# Pepper review audit record: the acting half (DEV-653).
#
# Assembles ONE schema-v1 JSON record describing a completed review — its
# configuration, its outcome, and what it cost — then (a) appends it to the
# CloudWatch log group `/pepper/pr-review/audit` and (b) renders it into
# `$GITHUB_STEP_SUMMARY` so a single run is self-explaining without AWS access.
#
# WHY A RECORD AT ALL. The question this exists to answer is "did that change
# make Pepper better or just different" — DEV-884 gates lowering `effort` on
# being able to compare before/after. AWS telemetry cannot answer it: `AWS/Bedrock`
# metrics are dimensioned by model/profile only (no effort), CloudTrail carries
# no request body, and Bedrock model-invocation logging would persist full
# prompts and responses to capture one config field. The workflow already HOLDS
# every dimension at run time, so emitting them here is both cheaper and the only
# practical source.
#
# HARD REQUIREMENT — THIS MUST NEVER FAIL A PR. pepper-pr-review is a required
# check org-wide (DEV-502/DEV-504), so no failure in assembling or writing the
# record — IAM denial, CloudWatch outage, missing execution file, malformed JSON
# — may fail, block, or delay the review. Nothing here exits non-zero, every
# parse has a fallback, and every missing value becomes `null` rather than an
# abort. A lost record is one lost row; the infrastructure/pepper-audit.cfn.yml
# alarm is what makes that loss visible, NOT a red check.
#
# WHY THE LOGIC IS A SCRIPT AND NOT INLINE YAML. Same reason as the DEV-674
# collapse programs: it runs on the CALLER's runner (where this repo's scripts/
# does not exist), it is fetched with the workflow at `job.workflow_sha` via the
# `.pepper-pr-review-tpl` sparse checkout so a consumer pinned to a release tag
# gets the version that shipped with their workflow, and living in a file is what
# lets scripts/test/pepper-audit-record_test.sh exercise the EXACT program
# production runs.
#
# Requires: jq. Uses `aws` and `gh` when present; degrades to nulls without them.
#
# Environment — workflow-supplied config (all optional; empty becomes null):
#   REPO PR_NUMBER RUN_ID RUN_ATTEMPT EVENT_NAME HEAD_SHA PR_AUTHOR FLAVOR
#   WORKFLOW_SHA STANDARDS_PATH COOKBOOK_REF MODEL EFFORT MAX_TURNS
#   REVIEW_TIMEOUT_MINUTES
#   NO_VERDICT       — "true" when the DEV-235 no-verdict escalation fired
#   COLLAPSE_FIRED   — "true" when the DEV-674 collapse rewrote the verdict
#   GH_TOKEN         — App token, for reading the PR's final outcome labels
#
# Environment — telemetry sources and destination:
#   PEPPER_AUDIT_EXECUTION_FILE  — claude-code-action's `execution_file` output
#   PEPPER_AUDIT_TRANSCRIPT      — explicit transcript JSONL (tests); else discovered
#   PEPPER_AUDIT_TRANSCRIPT_DIR  — default ${HOME}/.claude/projects
#   PEPPER_AUDIT_LOG_GROUP       — default /pepper/pr-review/audit
#   PEPPER_AUDIT_REGION          — default $AWS_REGION / $AWS_DEFAULT_REGION
#   PEPPER_AUDIT_DRY_RUN         — "true" prints the record instead of writing it
#
# Prints a single `audit-record=<compact json>` line last, which is what the
# fixture test asserts on (mirrors pepper-bot-outcome-collapse.sh's
# `collapse-result=` contract). The record carries no prompt or diff content, so
# logging it is safe on a public repo.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COLLECT_JQ="${HERE}/pepper-audit-collect.jq"
BUILD_JQ="${HERE}/pepper-audit-record.jq"

REPO="${REPO:-}"
PR_NUMBER="${PR_NUMBER:-}"
RUN_ID="${RUN_ID:-}"
RUN_ATTEMPT="${RUN_ATTEMPT:-}"
EVENT_NAME="${EVENT_NAME:-}"
HEAD_SHA="${HEAD_SHA:-}"
PR_AUTHOR="${PR_AUTHOR:-}"
FLAVOR="${FLAVOR:-}"
WORKFLOW_SHA="${WORKFLOW_SHA:-}"
STANDARDS_PATH="${STANDARDS_PATH:-}"
COOKBOOK_REF="${COOKBOOK_REF:-}"
MODEL="${MODEL:-}"
EFFORT="${EFFORT:-}"
MAX_TURNS="${MAX_TURNS:-}"
REVIEW_TIMEOUT_MINUTES="${REVIEW_TIMEOUT_MINUTES:-}"
NO_VERDICT="${NO_VERDICT:-}"
COLLAPSE_FIRED="${COLLAPSE_FIRED:-}"

LOG_GROUP="${PEPPER_AUDIT_LOG_GROUP:-/pepper/pr-review/audit}"
REGION="${PEPPER_AUDIT_REGION:-${AWS_REGION:-${AWS_DEFAULT_REGION:-}}}"
DRY_RUN="${PEPPER_AUDIT_DRY_RUN:-false}"

# jq is the whole assembly engine; without it there is no record to emit and no
# partial state to clean up. Preinstalled on GitHub-hosted runners.
if ! command -v jq >/dev/null 2>&1; then
  echo "::warning::jq is unavailable — no Pepper audit record was emitted for this run (DEV-653)."
  exit 0
fi
for prog in "${COLLECT_JQ}" "${BUILD_JQ}"; do
  if [ ! -f "${prog}" ]; then
    echo "::warning::Audit program not found at ${prog} — no Pepper audit record was emitted for this run (DEV-653)."
    exit 0
  fi
done

# --- 1. Timestamps ----------------------------------------------------------
# `ts` is the record's own clock, not the run's start: the record is written
# after the verdict, so it dates the OUTCOME. Second precision is deliberate —
# nothing here is ordered more finely than a review.
TS="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)" || TS=""
TS_EPOCH="$(date -u +%s 2>/dev/null)" || TS_EPOCH=""
case "${TS_EPOCH}" in
  ''|*[!0-9]*) TS_MS=0 ;;
  *) TS_MS=$(( TS_EPOCH * 1000 )) ;;
esac

# --- 2. standards_sha256 ----------------------------------------------------
# The per-repo prompt-customization identity. It is what lets a cost-by-repo
# query separate "this repo's PRs are big" from "this repo's custom standards
# drive longer reviews", and it changes the moment a repo edits its standards
# mid-series. Absent file (the common case) is a legitimate null, not an error.
STANDARDS_SHA256=""
if [ -n "${STANDARDS_PATH}" ] && [ -f "${STANDARDS_PATH}" ]; then
  if command -v sha256sum >/dev/null 2>&1; then
    STANDARDS_SHA256="$(sha256sum "${STANDARDS_PATH}" 2>/dev/null | awk '{print $1}')" || STANDARDS_SHA256=""
  elif command -v shasum >/dev/null 2>&1; then
    STANDARDS_SHA256="$(shasum -a 256 "${STANDARDS_PATH}" 2>/dev/null | awk '{print $1}')" || STANDARDS_SHA256=""
  fi
fi

# --- 3. Telemetry sources ---------------------------------------------------
# Preference is execution file, then session transcript (DEV-653). The execution
# file's final `result` record is the SDK's own accounting; the transcript is a
# sum we compute over per-message `usage`, which is why it is second.
collect() { # <file> -> collect-json, or the literal "null"
  local file="$1" out
  [ -n "${file}" ] && [ -f "${file}" ] || { printf 'null'; return 0; }
  out="$(jq -cn -f "${COLLECT_JQ}" "${file}" 2>/dev/null)" || out=""
  [ -n "${out}" ] || out="null"
  printf '%s' "${out}"
}

# The transcript's path contains a slug of the CLI's working directory and the
# session id, neither of which the workflow knows. Newest .jsonl under the
# projects tree is the run's own session: the runner is single-use and Pepper is
# the only CLI session on it. GNU `find -printf` (present on ubuntu runners)
# gives a true mtime sort; the fallback just takes the first match, which is
# correct whenever there is exactly one session — the normal case.
find_transcript() {
  local dir found
  if [ -n "${PEPPER_AUDIT_TRANSCRIPT:-}" ]; then
    printf '%s' "${PEPPER_AUDIT_TRANSCRIPT}"
    return 0
  fi
  dir="${PEPPER_AUDIT_TRANSCRIPT_DIR:-${HOME:-}/.claude/projects}"
  [ -n "${dir}" ] && [ -d "${dir}" ] || return 0
  found="$(find "${dir}" -type f -name '*.jsonl' -printf '%T@ %p\n' 2>/dev/null \
    | sort -rn | head -n1 | cut -d' ' -f2-)" || found=""
  if [ -z "${found}" ]; then
    found="$(find "${dir}" -type f -name '*.jsonl' 2>/dev/null | head -n1)" || found=""
  fi
  printf '%s' "${found}"
}

EXECUTION_FILE="${PEPPER_AUDIT_EXECUTION_FILE:-}"
TRANSCRIPT_FILE="$(find_transcript)"
EXEC_OBS="$(collect "${EXECUTION_FILE}")"
TX_OBS="$(collect "${TRANSCRIPT_FILE}")"

echo "Audit telemetry sources — execution file: ${EXECUTION_FILE:-<none>}; transcript: ${TRANSCRIPT_FILE:-<none>}"
echo "  execution file observations: ${EXEC_OBS}"
echo "  transcript observations:     ${TX_OBS}"

# --- 4. Outcome labels ------------------------------------------------------
# The verdict is read from the PR's FINAL labels rather than from Pepper's exit
# code: a graceful `--max-turns` stop exits SUCCESS with no verdict, and the
# DEV-674 collapse rewrites the verdict after Pepper is done. Unreadable labels
# become an empty list, which the builder maps to `outcome: null` — an honest
# hole, not a guessed outcome.
LABELS=""
if [ -n "${PR_NUMBER}" ] && command -v gh >/dev/null 2>&1; then
  GH_ARGS=(pr view "${PR_NUMBER}" --json labels --jq '[.labels[].name] | join(",")')
  [ -n "${REPO}" ] && GH_ARGS+=(--repo "${REPO}")
  LABELS="$(gh "${GH_ARGS[@]}" 2>/dev/null)" || LABELS=""
fi

# --- 5. Assemble ------------------------------------------------------------
RECORD="$(jq -cn \
  --arg exec_obs "${EXEC_OBS}" \
  --arg tx_obs "${TX_OBS}" \
  --arg ts "${TS}" \
  --arg repo "${REPO}" \
  --arg pr_number "${PR_NUMBER}" \
  --arg run_id "${RUN_ID}" \
  --arg run_attempt "${RUN_ATTEMPT}" \
  --arg event "${EVENT_NAME}" \
  --arg head_sha "${HEAD_SHA}" \
  --arg pr_author "${PR_AUTHOR}" \
  --arg flavor "${FLAVOR}" \
  --arg workflow_sha "${WORKFLOW_SHA}" \
  --arg standards_sha256 "${STANDARDS_SHA256}" \
  --arg cookbook_ref "${COOKBOOK_REF}" \
  --arg model "${MODEL}" \
  --arg effort "${EFFORT}" \
  --arg max_turns "${MAX_TURNS}" \
  --arg review_timeout_minutes "${REVIEW_TIMEOUT_MINUTES}" \
  --arg labels "${LABELS}" \
  --arg no_verdict "${NO_VERDICT}" \
  --arg collapse_fired "${COLLAPSE_FIRED}" \
  -f "${BUILD_JQ}")" || RECORD=""

if [ -z "${RECORD}" ]; then
  echo "::warning::Could not assemble the Pepper audit record for this run — nothing was written (DEV-653)."
  exit 0
fi

# --- 6. Job summary ---------------------------------------------------------
# The same record, readable. A run is then self-explaining to anyone with Actions
# access, with no AWS credentials and no Logs Insights query — which matters most
# on the runs someone is actively debugging.
if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  {
    echo "### Pepper review audit"
    echo
    echo "| Field | Value |"
    echo "|---|---|"
    printf '%s' "${RECORD}" | jq -r '
      def show: if . == null then "_null_" elif type == "boolean" then tostring else tostring end;
      [
        ["outcome", (.outcome | show)],
        ["collapse fired", (.collapse_fired | show)],
        ["model", (.model | show)],
        ["effort", (.effort | show)],
        ["cli version", (.cli_version | show)],
        ["flavor", (.flavor | show)],
        ["turns used / cap", ((.turns_used | show) + " / " + (.max_turns | show))],
        ["duration (ms)", (.duration_ms | show)],
        ["cost (USD)", (.cost_usd | show)],
        ["tokens in / out", ((.tokens.input | show) + " / " + (.tokens.output | show))],
        ["tokens cache read / creation", ((.tokens.cache_read | show) + " / " + (.tokens.cache_creation | show))],
        ["workflow sha", (.workflow_sha | show)],
        ["standards sha256", (.standards_sha256 | show)],
        ["cookbook ref", (.cookbook_ref | show)]
      ] | .[] | "| " + .[0] + " | " + .[1] + " |"' 2>/dev/null
    echo
    echo "<details><summary>Raw audit record (schema v1)</summary>"
    echo
    echo '```json'
    printf '%s' "${RECORD}" | jq . 2>/dev/null
    echo '```'
    echo
    echo "</details>"
  } >> "${GITHUB_STEP_SUMMARY}" 2>/dev/null || true
fi

emit() { echo "audit-record=$1"; exit 0; }

# --- 7. Write to CloudWatch -------------------------------------------------
case "${DRY_RUN}" in
  true|TRUE|1|yes)
    echo "PEPPER_AUDIT_DRY_RUN is set — not writing to CloudWatch."
    emit "${RECORD}"
    ;;
esac

if ! command -v aws >/dev/null 2>&1; then
  echo "::warning::aws CLI unavailable — the Pepper audit record for this run was not written to CloudWatch (DEV-653)."
  emit "${RECORD}"
fi
if [ -z "${REGION}" ]; then
  echo "::warning::No AWS region resolved — the Pepper audit record for this run was not written to CloudWatch (DEV-653)."
  emit "${RECORD}"
fi

# One stream per run attempt. Re-running a workflow produces a new attempt and
# therefore a new stream, so a retried review never overwrites the record of the
# attempt it replaced — both are evidence.
STREAM="${RUN_ID:-unknown}-${RUN_ATTEMPT:-0}"

# The log group is created by the hand-deployed CloudFormation stack
# (infrastructure/pepper-audit.cfn.yml), NOT here: the role holds
# CreateLogStream + PutLogEvents and nothing else, deliberately. A
# ResourceAlreadyExistsException on re-run is the expected steady state, so
# failure here is not fatal — put-log-events below is what actually matters.
aws logs create-log-stream \
  --log-group-name "${LOG_GROUP}" \
  --log-stream-name "${STREAM}" \
  --region "${REGION}" >/dev/null 2>&1 || true

# `--log-events` via a file, never the `timestamp=,message=` shorthand: the
# record is JSON full of commas and quotes, which the shorthand parser splits on.
EVENTS_FILE="$(mktemp 2>/dev/null)" || EVENTS_FILE=""
if [ -z "${EVENTS_FILE}" ]; then
  echo "::warning::Could not create a temp file for the Pepper audit record — nothing was written to CloudWatch (DEV-653)."
  emit "${RECORD}"
fi

jq -n --arg msg "${RECORD}" --argjson ts "${TS_MS}" \
  '[{timestamp: $ts, message: $msg}]' > "${EVENTS_FILE}" 2>/dev/null || true

if [ ! -s "${EVENTS_FILE}" ]; then
  rm -f "${EVENTS_FILE}"
  echo "::warning::Could not serialise the Pepper audit record — nothing was written to CloudWatch (DEV-653)."
  emit "${RECORD}"
fi

# Keyed on the EXIT STATUS, not on stderr being non-empty: the AWS CLI writes
# ordinary notices to stderr, and a warning fired on a successful write would
# make the missing-records alarm look broken every run.
PUT_ERR=""
if PUT_ERR="$(aws logs put-log-events \
  --log-group-name "${LOG_GROUP}" \
  --log-stream-name "${STREAM}" \
  --region "${REGION}" \
  --log-events "file://${EVENTS_FILE}" 2>&1 >/dev/null)"; then
  echo "Wrote the Pepper audit record to ${LOG_GROUP}, stream ${STREAM}."
else
  # A warning, never a failure. Loss is detected account-side by the
  # missing-records alarm in infrastructure/pepper-audit.cfn.yml — a broken
  # pipeline becomes a ticket, not a red required check (DEV-502/DEV-504).
  echo "::warning::Could not write the Pepper audit record to ${LOG_GROUP} (${PUT_ERR:-put-log-events failed}). The review is unaffected; the missing-records alarm covers sustained loss (DEV-653)."
fi
rm -f "${EVENTS_FILE}"

emit "${RECORD}"
