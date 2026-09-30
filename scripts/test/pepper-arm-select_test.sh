#!/usr/bin/env bash
# Test for Pepper's arm selection (DEV-2455): the `Select arm and resolve model`
# step of .github/workflows/pepper-pr-review.yml.
#
# The selection logic lives inline in the workflow (a separate script would have
# to be registered as a pepper-pr-review asset in sync-workflow-checksums.sh).
# So this test does not keep a copy: it pulls the step's `run:` block and its
# arm table out of the workflow with yq and runs them, which means it always
# exercises exactly what ships.
#
# What it pins:
#   - the same PR always lands in the same arm;
#   - the shipped 50/50 table splits PRs 1..1000 of one repo roughly evenly;
#   - a weight of 0 takes an arm out entirely (the canary rollback);
#   - `model` > non-default `review_model` > arm, and `effort` > arm effort;
#   - any selection failure falls back to the default model, never fails;
#   - DEFAULT_REVIEW_MODEL in the step equals the `review_model` input default.
#
# Requires: bash, jq, yq (mikefarah v4), sha256sum or shasum.
# Run locally:  scripts/test/pepper-arm-select_test.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WF="${HERE}/../../.github/workflows/pepper-pr-review.yml"

fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; shift; for l in "$@"; do echo "  $l"; done; fails=$((fails + 1)); }

for tool in jq yq; do
  command -v "${tool}" >/dev/null 2>&1 || { echo "FAIL: ${tool} is required"; exit 1; }
done

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

STEP='.jobs.review.steps[] | select(.id == "model")'
yq "${STEP} | .run" "${WF}" > "${WORK}/step.sh"
ARMS_SHIPPED="$(yq "${STEP} | .env.ARMS" "${WF}")"
DEFAULT_MODEL="$(yq "${STEP} | .env.DEFAULT_REVIEW_MODEL" "${WF}")"
INPUT_DEFAULT="$(yq '.on.workflow_call.inputs.review_model.default' "${WF}")"
PR_EXPR="$(yq "${STEP} | .env.PR_NUMBER" "${WF}")"

if [ -s "${WORK}/step.sh" ] && [ -n "${ARMS_SHIPPED}" ]; then
  pass "the step and its arm table are found in the workflow"
else
  fail "the step and its arm table are found in the workflow"
  exit 1
fi

# Run the step. Args: key=value env overrides. Prints "arm|model|effort".
select_arm() {
  local out="${WORK}/output"
  : > "${out}"
  env -i PATH="${PATH}" GITHUB_OUTPUT="${out}" \
    ARMS="${ARMS_SHIPPED}" DEFAULT_REVIEW_MODEL="${DEFAULT_MODEL}" \
    OVERRIDE="" REVIEW_MODEL="${INPUT_DEFAULT}" EFFORT_INPUT="" \
    REPO="SpiceLabsHQ/example" PR_NUMBER=1 \
    "$@" bash "${WORK}/step.sh" >/dev/null 2>&1
  local rc=$?
  [ "${rc}" -eq 0 ] || { echo "rc=${rc}"; return; }
  printf '%s|%s|%s\n' \
    "$(sed -n 's/^arm=//p' "${out}")" \
    "$(sed -n 's/^model=//p' "${out}")" \
    "$(sed -n 's/^effort=//p' "${out}")"
}

check() { # <label> <want> <got>
  if [ "$3" = "$2" ]; then pass "$1"; else fail "$1" "want: $2" "got:  $3"; fi
}

S5="$(jq -r '.[] | select(.name == "s5-high") | .model' <<<"${ARMS_SHIPPED}")"
S55="$(jq -r '.[] | select(.name == "s55-high") | .model' <<<"${ARMS_SHIPPED}")"

# --- The shipped table -------------------------------------------------------
check "DEFAULT_REVIEW_MODEL matches the review_model input default" "${INPUT_DEFAULT}" "${DEFAULT_MODEL}"
check "shipped weights sum to 100" "100" "$(jq '[.[].weight] | add' <<<"${ARMS_SHIPPED}")"
check "s5-high runs the default profile" "${INPUT_DEFAULT}" "${S5}"
case "${PR_EXPR}" in
  *github.event.pull_request.number*github.event.issue.number*)
    pass "PR number is read from both pull_request and issue_comment events" ;;
  *) fail "PR number is read from both pull_request and issue_comment events" "got: ${PR_EXPR}" ;;
esac

# --- Deterministic -----------------------------------------------------------
A="$(select_arm PR_NUMBER=42)"; B="$(select_arm PR_NUMBER=42)"
if [ "${A}" = "${B}" ] && [ "${A%%|*}" != "default-fallback" ]; then
  pass "the same PR always gets the same arm (${A%%|*})"
else
  fail "the same PR always gets the same arm" "first: ${A}" "second: ${B}"
fi
C="$(select_arm REPO=SpiceLabsHQ/other PR_NUMBER=42)"
check "arm is a function of repo and PR only (rerun, other repo)" "${C}" "$(select_arm REPO=SpiceLabsHQ/other PR_NUMBER=42)"

# --- Split over PRs 1..1000 --------------------------------------------------
n5=0 n55=0 other=0
for pr in $(seq 1 1000); do
  case "$(select_arm PR_NUMBER="${pr}")" in
    "s5-high|${S5}|high") n5=$((n5 + 1)) ;;
    "s55-high|${S55}|high") n55=$((n55 + 1)) ;;
    *) other=$((other + 1)) ;;
  esac
done
echo "INFO: split over SpiceLabsHQ/example#1..1000: s5-high=${n5} s55-high=${n55} other=${other}"
if [ "${other}" -eq 0 ] && [ "${n5}" -ge 450 ] && [ "${n5}" -le 550 ]; then
  pass "50/50 table splits 1000 PRs within 45-55%"
else
  fail "50/50 table splits 1000 PRs within 45-55%" "s5-high=${n5} s55-high=${n55} other=${other}"
fi

# --- Weight 0 disables an arm ------------------------------------------------
ROLLBACK="$(jq -c 'map(if .name == "s55-high" then .weight = 0 else .weight = 100 end)' <<<"${ARMS_SHIPPED}")"
leaked=0
for pr in $(seq 1 300); do
  [ "$(select_arm ARMS="${ROLLBACK}" PR_NUMBER="${pr}")" = "s5-high|${S5}|high" ] || leaked=$((leaked + 1))
done
check "weight 0 takes s55-high out (300 PRs, none leak)" "0" "${leaked}"
ONLY55="$(jq -c 'map(if .name == "s55-high" then .weight = 100 else .weight = 0 end)' <<<"${ARMS_SHIPPED}")"
leaked=0
for pr in $(seq 1 300); do
  [ "$(select_arm ARMS="${ONLY55}" PR_NUMBER="${pr}")" = "s55-high|${S55}|high" ] || leaked=$((leaked + 1))
done
check "weight 0 takes s5-high out (300 PRs, none leak)" "0" "${leaked}"

# --- Precedence --------------------------------------------------------------
OTHER="arn:aws:bedrock:us-west-2:618640261060:application-inference-profile/zzzzzzzzzzzz"
check "model input wins over the arm" "override|${OTHER}|high" "$(select_arm OVERRIDE="${OTHER}")"
check "model input wins over review_model" "override|${OTHER}|high" "$(select_arm OVERRIDE="${OTHER}" REVIEW_MODEL=arn:x)"
check "non-default review_model wins over the arm" "override|${OTHER}|high" "$(select_arm REVIEW_MODEL="${OTHER}")"
GOT="$(select_arm EFFORT_INPUT=medium PR_NUMBER=42)"
check "effort input wins over the arm's effort" "${A%|*}|medium" "${GOT}"
check "effort input applies under a model override" "override|${OTHER}|xhigh" "$(select_arm OVERRIDE="${OTHER}" EFFORT_INPUT=xhigh)"
check "an invalid effort input is ignored" "${A}" "$(select_arm EFFORT_INPUT='high --dangerously' PR_NUMBER=42)"

# --- Fail safe ---------------------------------------------------------------
FB="default-fallback|${INPUT_DEFAULT}|high"
check "no PR number falls back" "${FB}" "$(select_arm PR_NUMBER=)"
check "malformed arm table falls back" "${FB}" "$(select_arm ARMS='[{"name":')"
check "weights not summing to 100 fall back" "${FB}" "$(select_arm ARMS="$(jq -c '.[0].weight = 40' <<<"${ARMS_SHIPPED}")")"
check "an arm with a bad effort falls back" "${FB}" "$(select_arm ARMS="$(jq -c '.[1].effort = "turbo"' <<<"${ARMS_SHIPPED}")")"
mkdir -p "${WORK}/bare" && ln -sf "$(command -v bash)" "${WORK}/bare/bash"
check "no hash tool and no jq falls back without failing" "${FB}" "$(select_arm PATH="${WORK}/bare")"

echo
if [ "${fails}" -eq 0 ]; then
  echo "All checks passed."
else
  echo "${fails} check(s) failed."
  exit 1
fi
