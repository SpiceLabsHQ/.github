#!/usr/bin/env bash
# Fixture test for org-ci-audit-mise.jq — the mise toolchain-compliance decision
# behind the org CI audit's `mise` column.
#
# WHY THIS EXISTS: the audit runs on a weekly schedule against the live org, so
# a defect in this judgment surfaces as a wrong dashboard nobody trusts rather
# than a red PR. And the failure mode that kills a guidance dashboard is the
# FALSE POSITIVE: most SpiceLabs repos are docs, PowerShell, or markdown with no
# language runtime at all. If those read as violations, the gap list is noise on
# week one and unread by week two. So the `na` cases below are load-bearing —
# they are the reason the column can be trusted when it does say `missing`.
#
# The other load-bearing group is `partial`: a repo that adopted mise but left a
# runtime unpinned (the "node modules that are unmanaged" case) is the actual
# thing this column was built to surface, and it is invisible to a naive
# "does mise.toml exist?" check.
#
# Run locally:  scripts/test/org-ci-audit-mise_test.sh
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DECIDE="${HERE}/../org-ci-audit-mise.jq"
AUDIT="${HERE}/../org-ci-audit.sh"

command -v jq >/dev/null || { echo "jq not found" >&2; exit 2; }

fails=0
cases=0

# decide <input-json> -> compact decision JSON
decide() { printf '%s' "$1" | jq -c -f "${DECIDE}"; }

# expect_field <name> <input-json> <jq-filter> <expected>
expect_field() {
  local name="$1" input="$2" filter="$3" want="$4" got
  cases=$((cases + 1))
  got="$(decide "${input}" | jq -c "${filter}")"
  if [ "${got}" = "${want}" ]; then
    echo "PASS  ${name}"
  else
    echo "FAIL  ${name}"
    echo "        filter:   ${filter}"
    echo "        expected: ${want}"
    echo "        actual:   ${got}"
    fails=$((fails + 1))
  fi
}

# expect_state <name> <input-json> <expected-state>
expect_state() { expect_field "$1" "$2" '.state' "\"$3\""; }

echo "== na: nothing for mise to manage (the false-positive guard) =="

expect_state "pure docs repo" \
  '{"repo":"KG-IT-Runbook","paths":["README.md","docs/onboarding.md","LICENSE"],"mise_tools":[]}' \
  na

expect_state "markdown + GitHub Actions only" \
  '{"repo":"Eng-Cookbook","paths":["README.md",".github/workflows/ci.yml","standards/testing.md"],"mise_tools":[]}' \
  na

expect_state "PowerShell repo has no mise-managed runtime" \
  '{"repo":"KG-Intune-Deployment","paths":["Deploy.ps1","modules/Intune.psm1","README.md"],"mise_tools":[]}' \
  na

expect_state "shell scripts alone are not an ecosystem" \
  '{"repo":".github","paths":["scripts/org-ci-audit.sh","scripts/apply-ci-floor-rulesets.sh"],"mise_tools":[]}' \
  na

echo "== missing: a real runtime with nothing pinning it =="

expect_state "node app, no mise config" \
  '{"repo":"KG-Web","paths":["package.json","package-lock.json","src/index.ts"],"mise_tools":[]}' \
  missing

expect_state "go module, no mise config" \
  '{"repo":"Foundation","paths":["go.mod","go.sum","main.go"],"mise_tools":[]}' \
  missing

expect_state "terraform detected by extension" \
  '{"repo":"Shared-Cloud-Infra","paths":["main.tf","variables.tf","README.md"],"mise_tools":[]}' \
  missing

expect_field "missing names the unmanaged runtime and its evidence" \
  '{"repo":"KG-Web","paths":["package.json","src/index.ts"],"mise_tools":[]}' \
  '{u: .unmanaged, e: [.detected[].evidence]}' \
  '{"u":["node"],"e":["package.json"]}'

echo "== ok: every detected runtime is pinned =="

expect_state "node pinned by mise.toml" \
  '{"repo":"Lumen-BI","paths":["mise.toml","package.json"],"mise_tools":["node"]}' \
  ok

expect_state "php + node both pinned" \
  '{"repo":"BQE-Collector","paths":["mise.toml","composer.json","package.json"],"mise_tools":["php","node","awscli"]}' \
  ok

expect_state "extra pinned tools beyond the detected runtimes are fine" \
  '{"repo":"BQE-Collector","paths":["mise.toml","package.json"],"mise_tools":["node","awscli","aws-sam-cli"]}' \
  ok

expect_state "mise config with nothing detected is not a violation" \
  '{"repo":"Ops-CLI","paths":["mise.toml","README.md"],"mise_tools":["awscli"]}' \
  ok

echo "== ok: alternate config locations and tool spellings =="

expect_state ".tool-versions counts — mise reads asdf's format natively" \
  '{"repo":"Legacy","paths":[".tool-versions","go.mod"],"mise_tools":["golang"]}' \
  ok

expect_state ".config/mise/config.toml is a real mise config path" \
  '{"repo":"Tidy","paths":[".config/mise/config.toml","package.json"],"mise_tools":["node"]}' \
  ok

expect_state "backend prefix normalizes (core:node)" \
  '{"repo":"Prefixed","paths":["mise.toml","package.json"],"mise_tools":["core:node"]}' \
  ok

expect_state "alias normalizes (nodejs)" \
  '{"repo":"Aliased","paths":["mise.toml","package.json"],"mise_tools":["asdf:nodejs"]}' \
  ok

expect_state "opentofu satisfies a terraform detection" \
  '{"repo":"Tofu","paths":["mise.toml","main.tf"],"mise_tools":["opentofu"]}' \
  ok

echo "== partial: adopted mise but left a runtime unmanaged =="

expect_state "php pinned, node left unmanaged" \
  '{"repo":"BQE-Collector","paths":["mise.toml","composer.json","package.json"],"mise_tools":["php"]}' \
  partial

expect_field "partial reports exactly which runtime is unmanaged" \
  '{"repo":"BQE-Collector","paths":["mise.toml","composer.json","package.json"],"mise_tools":["php"]}' \
  '.unmanaged' '["node"]'

expect_field "partial can report several unmanaged runtimes, sorted" \
  '{"repo":"Wide","paths":["mise.toml","package.json","go.mod","main.tf"],"mise_tools":["node"]}' \
  '.unmanaged' '["go","terraform"]'

echo "== detection scope: vendored and fixture paths are not evidence =="

expect_state "checked-in node_modules does not invent a node ecosystem" \
  '{"repo":"Docsite","paths":["README.md","node_modules/left-pad/package.json"],"mise_tools":[]}' \
  na

expect_state "test fixtures do not invent an ecosystem" \
  '{"repo":".github","paths":["README.md","scripts/test/fixtures/package.json"],"mise_tools":[]}' \
  na

expect_state "vendor/ does not invent an ecosystem" \
  '{"repo":"PHPish","paths":["README.md","vendor/acme/lib/composer.json"],"mise_tools":[]}' \
  na

expect_state "examples/ does not invent an ecosystem" \
  '{"repo":"Guide","paths":["README.md","examples/quickstart/package.json"],"mise_tools":[]}' \
  na

expect_state "deeply nested manifests are out of scope" \
  '{"repo":"Deep","paths":["README.md","a/b/c/d/package.json"],"mise_tools":[]}' \
  na

expect_state "monorepo package one level down still counts" \
  '{"repo":"Mono","paths":["packages/api/package.json","README.md"],"mise_tools":[]}' \
  missing

echo "== unknown: the git tree came back truncated, so facts are unusable =="

expect_state "truncated tree is reported, never guessed" \
  '{"repo":"Huge","truncated":true,"paths":["README.md"],"mise_tools":[]}' \
  unknown

expect_state "truncated wins even when a config is visible" \
  '{"repo":"Huge","truncated":true,"paths":["mise.toml","package.json"],"mise_tools":["node"]}' \
  unknown

echo "== shape: one row per ecosystem, shallowest path as evidence =="

expect_field "duplicate node markers collapse to a single detection" \
  '{"repo":"Multi","paths":["package.json","package-lock.json",".nvmrc"],"mise_tools":[]}' \
  '[.detected[].tool]' '["node"]'

expect_field "primary manifest beats a lockfile as evidence" \
  '{"repo":"Multi","paths":["package-lock.json","package.json"],"mise_tools":[]}' \
  '.detected[0].evidence' '"package.json"'

expect_field "root manifest beats a nested one as evidence" \
  '{"repo":"Multi","paths":["packages/api/package.json","package.json"],"mise_tools":[]}' \
  '.detected[0].evidence' '"package.json"'

expect_field "config path is reported for the guidance line" \
  '{"repo":"Tidy","paths":[".config/mise/config.toml","package.json"],"mise_tools":["node"]}' \
  '.config' '".config/mise/config.toml"'

expect_field "no config reports null, not an empty string" \
  '{"repo":"Bare","paths":["package.json"],"mise_tools":[]}' \
  '.config' 'null'

echo "== config parsing: which tools a mise config actually declares =="
#
# Exercised through the audit script's own `--mise-tools` flag, so the parser
# under test is the one production runs. The case that matters is a REAL
# mise.toml: BQE-Collector's carries `[env]`, seven `[tasks.*]` tables and keys
# like `_.path` and `PHP_EXTRA_CONFIGURE_OPTIONS`. A parser that grabs every
# `key =` line in the file credits the repo with a dozen imaginary tools and
# then reports every runtime as pinned — a silent false `✅`, the worst outcome
# this column can produce.

# expect_tools <name> <config-path> <config-body> <expected-newline-list>
expect_tools() {
  local name="$1" path="$2" body="$3" want="$4" got
  cases=$((cases + 1))
  got="$(printf '%s' "${body}" | "${AUDIT}" --mise-tools "${path}")"
  if [ "${got}" = "${want}" ]; then
    echo "PASS  ${name}"
  else
    echo "FAIL  ${name}"
    echo "        expected: $(printf '%s' "${want}" | tr '\n' ' ')"
    echo "        actual:   $(printf '%s' "${got}" | tr '\n' ' ')"
    fails=$((fails + 1))
  fi
}

expect_tools "flat [tools] table" mise.toml \
'[tools]
node = "20"
php = "8.4"
' \
'node
php'

expect_tools "[env] and [tasks.*] keys are not tools" mise.toml \
'[tools]
php = "8.4"
node = "18"
awscli = "2.36.28"

[env]
_.path = ["./vendor/bin"]
XDEBUG_MODE = "off"

[tasks.test]
description = "Run tests"
run = "php artisan test"

[tasks."test:fast"]
run = "phpunit"
' \
'php
node
awscli'

expect_tools "[tools.<name>] sub-table form" mise.toml \
'[tools.node]
version = "20"

[tools.python]
version = "3.12"
' \
'node
python'

expect_tools "comments and quoted keys" mise.toml \
'# pin the runtimes
[tools]
# node is the app runtime
"node" = "20"
  go   =   "1.22"
' \
'node
go'

expect_tools ".tool-versions takes the first field per line" .tool-versions \
'# asdf-style pins
nodejs 20.11.0
golang 1.22.0
' \
'nodejs
golang'

expect_tools "a config declaring no tools yields nothing" mise.toml \
'[env]
FOO = "bar"
' \
''

echo
if [ "${fails}" -eq 0 ]; then
  echo "All ${cases} mise-decision cases passed."
else
  echo "${fails} of ${cases} mise-decision cases FAILED." >&2
  exit 1
fi
