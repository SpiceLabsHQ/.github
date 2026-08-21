#!/usr/bin/env bash
# Fixture test for org-ci-audit-mise.jq — the development-environment compliance
# decision behind the org CI audit's `mise` column.
#
# WHY THIS EXISTS: the audit only ever runs on a weekly schedule against the live
# org, so a defect here does not surface as a red PR — it surfaces as a dashboard
# that quietly says the wrong thing. And the expensive failure is the FALSE
# POSITIVE: most SpiceLabs repos are docs, PowerShell, or markdown with no
# language runtime at all. If those start reading as violations, the gap list is
# noise on week one and unread by week two. So the `na` cases below are
# load-bearing — they are the reason the column can be trusted when it does
# report a violation.
#
# The rules under test come from `standards/development-environment.md`
# (ADR-0024), whose Enforcement section marks them "audited, not blocked":
#   rule 1 — toolchain pinned in a committed root `mise.toml`, covering every
#            runtime the repo has
#   rule 2 — no `.devcontainer/` (unconditional)
#   rule 4 — a `setup` task where a checkout needs a dependency install
#
# Run locally:  scripts/test/org-ci-audit-mise_test.sh
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DECIDE="${HERE}/../org-ci-audit-mise.jq"
AUDIT="${HERE}/../org-ci-audit.sh"

command -v jq >/dev/null || { echo "jq not found" >&2; exit 2; }

fails=0
cases=0

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

expect_state() { expect_field "$1" "$2" '.state' "\"$3\""; }

# The rule numbers a decision reports, in severity order.
expect_rules() { expect_field "$1" "$2" '[.violations[].rule]' "$3"; }

echo "== na: nothing to assess (the false-positive guard) =="

expect_state "pure docs repo" \
  '{"repo":"KG-IT-Runbook","paths":["README.md","docs/onboarding.md","LICENSE"]}' na

expect_state "markdown + GitHub Actions only" \
  '{"repo":"Eng-Cookbook","paths":["README.md",".github/workflows/ci.yml","standards/testing.md"]}' na

expect_state "PowerShell repo has no mise-managed runtime" \
  '{"repo":"KG-Intune-Deployment","paths":["Deploy.ps1","modules/Intune.psm1","README.md"]}' na

expect_state "shell scripts alone are not an ecosystem" \
  '{"repo":".github","paths":["scripts/org-ci-audit.sh","scripts/apply-ci-floor-rulesets.sh"]}' na

expect_rules "an na repo reports no violations at all" \
  '{"repo":"Docs","paths":["README.md"]}' '[]'

echo "== rule 1: a real runtime with nothing pinning it =="

expect_state "node app, no mise config" \
  '{"repo":"KG-Web","paths":["package.json","package-lock.json","src/index.ts"]}' missing

expect_state "go module, no mise config" \
  '{"repo":"Foundation","paths":["go.mod","go.sum","main.go"]}' missing

expect_state "terraform detected by extension" \
  '{"repo":"Shared-Cloud-Infra","paths":["main.tf","variables.tf","README.md"]}' missing

expect_rules "missing config is a rule 1 violation" \
  '{"repo":"KG-Web","paths":["package.json"]}' '[1]'

expect_field "missing names the unmanaged runtime and its evidence" \
  '{"repo":"KG-Web","paths":["package.json","src/index.ts"]}' \
  '{u: .unmanaged, e: [.detected[].evidence]}' \
  '{"u":["node"],"e":["package.json"]}'

echo "== rule 1: config exists and covers every runtime =="

expect_state "node pinned, with a setup task" \
  '{"repo":"Lumen-BI","paths":["mise.toml","package.json"],"mise_tools":["node"],"mise_tasks":["setup"]}' ok

expect_state "php + node both pinned" \
  '{"repo":"BQE-Collector","paths":["mise.toml","composer.json","package.json"],"mise_tools":["php","node","awscli"],"mise_tasks":["setup","test"]}' ok

expect_state "extra pinned tools beyond the detected runtimes are fine" \
  '{"repo":"BQE-Collector","paths":["mise.toml","package.json"],"mise_tools":["node","awscli","aws-sam-cli"],"mise_tasks":["setup"]}' ok

expect_state "config with no detected runtime is compliant, not na" \
  '{"repo":"Shared-Cloud-Infra","paths":["mise.toml","README.md"],"mise_tools":["awscli"]}' ok

expect_state "backend prefix normalizes (core:node)" \
  '{"repo":"Prefixed","paths":["mise.toml","package.json"],"mise_tools":["core:node"],"mise_tasks":["setup"]}' ok

expect_state "alias normalizes (nodejs)" \
  '{"repo":"Aliased","paths":["mise.toml","package.json"],"mise_tools":["asdf:nodejs"],"mise_tasks":["setup"]}' ok

expect_state "opentofu satisfies a terraform detection" \
  '{"repo":"Tofu","paths":["mise.toml","main.tf"],"mise_tools":["opentofu"]}' ok

echo "== rule 1: config exists but leaves a runtime unpinned =="

expect_state "php pinned, node left unmanaged" \
  '{"repo":"BQE-Collector","paths":["mise.toml","composer.json","package.json"],"mise_tools":["php"],"mise_tasks":["setup"]}' partial

expect_field "reports exactly which runtime is unmanaged" \
  '{"repo":"BQE-Collector","paths":["mise.toml","composer.json","package.json"],"mise_tools":["php"],"mise_tasks":["setup"]}' \
  '.unmanaged' '["node"]'

expect_field "can report several unmanaged runtimes, sorted" \
  '{"repo":"Wide","paths":["mise.toml","package.json","go.mod","main.tf"],"mise_tools":["node"],"mise_tasks":["setup"]}' \
  '.unmanaged' '["go","terraform"]'

echo "== rule 1: the config is not the root mise.toml the standard names =="
#
# These locations ARE loaded by mise, so the repo has genuinely pinned its
# toolchain — the finding is a location problem, not a missing toolchain, and
# conflating the two would misreport it as far worse than it is.

expect_state ".tool-versions pins the toolchain but violates rule 1" \
  '{"repo":"Legacy","paths":[".tool-versions","go.mod"],"mise_tools":["golang"]}' partial

expect_rules ".tool-versions is a rule 1 location violation only" \
  '{"repo":"Legacy","paths":[".tool-versions","go.mod"],"mise_tools":["golang"]}' '[1]'

expect_field "the location violation says what is wrong" \
  '{"repo":"Legacy","paths":[".tool-versions","go.mod"],"mise_tools":["golang"]}' \
  '.violations[0].label' '"config location"'

expect_state ".config/mise/config.toml is also non-canonical" \
  '{"repo":"Tidy","paths":[".config/mise/config.toml","main.tf"],"mise_tools":["terraform"]}' partial

expect_field "canonical is true only for a root mise.toml" \
  '{"repo":"Root","paths":["mise.toml","main.tf"],"mise_tools":["terraform"]}' '.canonical' 'true'

expect_field "canonical is false for .mise.toml" \
  '{"repo":"Dot","paths":[".mise.toml","main.tf"],"mise_tools":["terraform"]}' '.canonical' 'false'

echo "== rule 2: no .devcontainer/ — unconditional =="
#
# The unconditional part is the whole point: rule 2 has no runtime precondition,
# so a docs repo carrying a devcontainer is in violation even though it has no
# toolchain to pin. A check that only looked at repos with runtimes would miss it.

expect_state "devcontainer in a repo with no runtime is still a violation" \
  '{"repo":"Docsite","paths":["README.md",".devcontainer/devcontainer.json"]}' partial

expect_rules "that violation is rule 2, alone" \
  '{"repo":"Docsite","paths":["README.md",".devcontainer/devcontainer.json"]}' '[2]'

expect_state "devcontainer alongside a compliant mise config" \
  '{"repo":"BQE-Collector","paths":["mise.toml","package.json",".devcontainer/devcontainer.json"],"mise_tools":["node"],"mise_tasks":["setup"]}' partial

expect_rules "a repo with no config AND a devcontainer reports both rules" \
  '{"repo":"Atelier","paths":["package.json",".devcontainer/devcontainer.json"]}' '[1,2]'

expect_state "no config plus devcontainer is still missing, not partial" \
  '{"repo":"Atelier","paths":["package.json",".devcontainer/devcontainer.json"]}' missing

expect_field "the root .devcontainer.json single-file form counts" \
  '{"repo":"Single","paths":["README.md",".devcontainer.json"]}' \
  '.devcontainer' '".devcontainer.json"'

expect_state "a devcontainer inside a test fixture is not the repo's own" \
  '{"repo":".github","paths":["README.md","scripts/test/fixtures/.devcontainer/devcontainer.json"]}' na

echo "== rule 4: a setup task where dependencies must be installed =="

expect_state "node repo pinned but with no setup task" \
  '{"repo":"Reaper","paths":["mise.toml","package.json"],"mise_tools":["node"],"mise_tasks":["test"]}' partial

expect_rules "that violation is rule 4" \
  '{"repo":"Reaper","paths":["mise.toml","package.json"],"mise_tools":["node"],"mise_tasks":["test"]}' '[4]'

expect_state "a setup task satisfies rule 4" \
  '{"repo":"Reaper","paths":["mise.toml","package.json"],"mise_tools":["node"],"mise_tasks":["setup","test"]}' ok

expect_rules "go needs no install step, so rule 4 does not fire" \
  '{"repo":"Mint","paths":["mise.toml","go.mod"],"mise_tools":["go"],"mise_tasks":["test"]}' '[]'

expect_rules "rust needs no install step either" \
  '{"repo":"Rusty","paths":["mise.toml","Cargo.toml"],"mise_tools":["rust"]}' '[]'

expect_rules "no config means rule 1 fires and rule 4 stays quiet" \
  '{"repo":"Bare","paths":["package.json"]}' '[1]'

expect_rules "no runtime means rule 4 has no precondition to attach to" \
  '{"repo":"Infra","paths":["mise.toml","README.md"],"mise_tools":["awscli"]}' '[]'

echo "== severity: the cell shows the most serious finding =="

expect_field "missing config outranks a devcontainer" \
  '{"repo":"Atelier","paths":["package.json",".devcontainer/devcontainer.json"]}' \
  '.headline' '"node"'

expect_field "a devcontainer outranks a missing setup task" \
  '{"repo":"Mixed","paths":["mise.toml","package.json",".devcontainer/devcontainer.json"],"mise_tools":["node"],"mise_tasks":[]}' \
  '.violations[0].rule' '2'

expect_field "an unpinned runtime outranks a config-location problem" \
  '{"repo":"Both","paths":[".mise.toml","package.json","composer.json"],"mise_tools":["node"],"mise_tasks":["setup"]}' \
  '.violations[0].label' '"php"'

echo "== detection scope: vendored and fixture paths are not evidence =="

expect_state "checked-in node_modules does not invent a node ecosystem" \
  '{"repo":"Docsite","paths":["README.md","node_modules/left-pad/package.json"]}' na

expect_state "test fixtures do not invent an ecosystem" \
  '{"repo":".github","paths":["README.md","scripts/test/fixtures/package.json"]}' na

expect_state "vendor/ does not invent an ecosystem" \
  '{"repo":"PHPish","paths":["README.md","vendor/acme/lib/composer.json"]}' na

expect_state "examples/ does not invent an ecosystem" \
  '{"repo":"Guide","paths":["README.md","examples/quickstart/package.json"]}' na

expect_state "deeply nested manifests are out of scope" \
  '{"repo":"Deep","paths":["README.md","a/b/c/d/package.json"]}' na

expect_state "monorepo package one level down still counts" \
  '{"repo":"Mono","paths":["packages/api/package.json","README.md"]}' missing

echo "== unknown: the git tree came back truncated, so facts are unusable =="

expect_state "truncated tree is reported, never guessed" \
  '{"repo":"Huge","truncated":true,"paths":["README.md"]}' unknown

expect_state "truncated wins even when a config is visible" \
  '{"repo":"Huge","truncated":true,"paths":["mise.toml","package.json"],"mise_tools":["node"]}' unknown

echo "== shape: one row per ecosystem, shallowest path as evidence =="

expect_field "duplicate node markers collapse to a single detection" \
  '{"repo":"Multi","paths":["package.json","package-lock.json",".nvmrc"]}' \
  '[.detected[].tool]' '["node"]'

expect_field "primary manifest beats a lockfile as evidence" \
  '{"repo":"Multi","paths":["package-lock.json","package.json"]}' \
  '.detected[0].evidence' '"package.json"'

expect_field "root manifest beats a nested one as evidence" \
  '{"repo":"Multi","paths":["packages/api/package.json","package.json"]}' \
  '.detected[0].evidence' '"package.json"'

expect_field "config path is reported for the guidance line" \
  '{"repo":"Tidy","paths":[".config/mise/config.toml","package.json"],"mise_tools":["node"],"mise_tasks":["setup"]}' \
  '.config' '".config/mise/config.toml"'

expect_field "no config reports null, not an empty string" \
  '{"repo":"Bare","paths":["package.json"]}' '.config' 'null'

echo "== config parsing: which tools and tasks a config actually declares =="
#
# Exercised through the audit script's own flags, so the parser under test is the
# one production runs. The case that matters is a REAL mise.toml:
# BQE-Collector's carries `[env]`, seven `[tasks.*]` tables and keys like
# `_.path` and `PHP_EXTRA_CONFIGURE_OPTIONS`. A parser that grabs every `key =`
# line credits the repo with a dozen imaginary tools and then reports every
# runtime as pinned — a silent false `✅`, the worst outcome this column can
# produce.

# expect_keys <name> <flag> <config-path> <config-body> <expected-newline-list>
expect_keys() {
  local name="$1" flag="$2" path="$3" body="$4" want="$5" got
  cases=$((cases + 1))
  got="$(printf '%s' "${body}" | "${AUDIT}" "${flag}" "${path}")"
  if [ "${got}" = "${want}" ]; then
    echo "PASS  ${name}"
  else
    echo "FAIL  ${name}"
    echo "        expected: $(printf '%s' "${want}" | tr '\n' ' ')"
    echo "        actual:   $(printf '%s' "${got}" | tr '\n' ' ')"
    fails=$((fails + 1))
  fi
}

REAL_CONFIG='# mise toolchain definition (DEV-997).
[tools]
php = "8.4"
node = "18"
awscli = "2.36.28"

[env]
_.path = ["./vendor/bin", "./node_modules/.bin"]
PHP_EXTRA_CONFIGURE_OPTIONS = "--with-zip --enable-opcache"
XDEBUG_MODE = "off"

[tasks.setup]
description = "Install PHP and JS dependencies for a fresh checkout"
run = ["composer install", "npm ci"]

[tasks.test]
run = "php artisan test --no-coverage"

[tasks."test:fast"]
run = "phpunit --configuration phpunit-fast.xml"
'

expect_keys "real config: [env] and [tasks.*] keys are not tools" --mise-tools mise.toml \
  "${REAL_CONFIG}" 'php
node
awscli'

expect_keys "real config: task names, and no tool or env keys" --mise-tasks mise.toml \
  "${REAL_CONFIG}" 'setup
test
test:fast'

expect_keys "flat [tools] table" --mise-tools mise.toml \
'[tools]
node = "20"
php = "8.4"
' 'node
php'

expect_keys "[tools.<name>] sub-table form" --mise-tools mise.toml \
'[tools.node]
version = "20"

[tools.python]
version = "3.12"
' 'node
python'

expect_keys "flat [tasks] table" --mise-tasks mise.toml \
'[tasks]
setup = "npm ci"
test = "npm test"
' 'setup
test'

expect_keys "comments and quoted keys" --mise-tools mise.toml \
'# pin the runtimes
[tools]
# node is the app runtime
"node" = "20"
  go   =   "1.22"
' 'node
go'

expect_keys ".tool-versions takes the first field per line" --mise-tools .tool-versions \
'# asdf-style pins
nodejs 20.11.0
golang 1.22.0
' 'nodejs
golang'

expect_keys ".tool-versions declares no tasks" --mise-tasks .tool-versions \
'nodejs 20.11.0
' ''

expect_keys "a config declaring no tools yields nothing" --mise-tools mise.toml \
'[env]
FOO = "bar"
' ''

echo
if [ "${fails}" -eq 0 ]; then
  echo "All ${cases} development-environment cases passed."
else
  echo "${fails} of ${cases} development-environment cases FAILED." >&2
  exit 1
fi
