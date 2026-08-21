#!/usr/bin/env bash
# Org CI floor & maturity audit (DEV-499).
#
# Inventories every non-archived repo in the org against its enforced tier and
# the maturity ladder, then emits a Markdown dashboard on stdout. The scheduled
# workflow (org-ci-audit.yml) upserts that dashboard into a pinned issue.
#
# What it reports per repo:
#   - tier: `docs` (tagged ci-exception=docs) or `code` (untagged, fail-safe),
#     plus `+public` overlay for public repos
#   - floor: enforced centrally by org rulesets — NOT by per-repo files — so the
#     dashboard reports floor *coverage* (is the repo targeted by its ruleset?)
#     rather than installed floor callers
#   - renovate: whether the repo has a Renovate config AND whether that config
#     extends the shared org preset (floor; a ruleset can't require a file, so
#     the audit is its enforcement point). Three states, because presence alone
#     is not compliance — see renovate_state() in scripts/lib/renovate-preset.sh
#   - dep-alerts: whether Dependabot alerts are enabled (floor; DEV-1142). The
#     preset's `vulnerabilityAlerts` carve-out is what lets a CVE fix skip the
#     7-day minimumReleaseAge soak, and it is sourced from Dependabot alerts —
#     so on a repo with alerts off it matches nothing and fails silently. For
#     GitHub Actions it is the only CVE path there is, OSV having no
#     `github-tags` ecosystem. Preset adoption alone therefore overstates the
#     security guarantee, which is why this is scored beside Renovate rather
#     than assumed
#   - development environment: the auditable rules of the Eng-Cookbook standard
#     `standards/development-environment.md` (ADR-0024) — rule 1 (root mise.toml
#     pinning every runtime), rule 2 (no .devcontainer/), rule 4 (a `setup`
#     task). A repo with nothing to assess reads `—`, not a violation, which is
#     what keeps the gap list credible (see org-ci-audit-mise.jq)
#   - Silver/Gold rungs: installed callers for scorecard (Silver),
#     release-please + release-artifacts (Gold)
#   - next missing rung (the guidance action)
#   - exception honesty: a repo tagged `docs` that shows code indicators
#
# Requires: gh (authenticated with an ORG-SCOPED token: repo read across the org
# + org custom-property read), jq. Set GH_TOKEN in the environment.
#
# Usage: scripts/org-ci-audit.sh [--org SpiceLabsHQ] > dashboard.md

set -euo pipefail

ORG="SpiceLabsHQ"
if [ "${1:-}" = "--org" ]; then ORG="${2:?--org needs a value}"; fi

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MISE_DECIDE="${HERE}/org-ci-audit-mise.jq"

command -v jq >/dev/null || { echo "jq not found" >&2; exit 2; }
[ -f "${MISE_DECIDE}" ] || { echo "missing ${MISE_DECIDE}" >&2; exit 2; }

# Scratch file for the per-repo git tree, reused across repos. One file with one
# EXIT trap, rather than a temp file per repo: a large repo's recursive tree is
# megabytes and must not travel through argv (ARG_MAX), but it also doesn't need
# to outlive the repo it describes.
MISE_TREE_TMP="$(mktemp)"
trap 'rm -f "${MISE_TREE_TMP}"' EXIT

# Renovate preset detection is shared with scripts/sweep-renovate-preset.sh via
# this library (DEV-1167). It is NOT duplicated here on purpose: two copies of
# org Renovate policy drifting apart is precisely the DEV-1150 bug.
# shellcheck source=scripts/lib/renovate-preset.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/renovate-preset.sh"

# Static/docs language signals — a repo tagged `docs` whose primary language is
# outside this set is worth a second look (it may have grown code).
is_static_lang() {
  case "${1:-}" in
    HTML|CSS|SCSS|Less|Markdown|Shell|""|null|None|-) return 0 ;;
    *) return 1 ;;
  esac
}

# --- mise toolchain coverage -----------------------------------------------
# The decision itself lives in org-ci-audit-mise.jq (pure, fixture-tested). The
# two functions here only gather facts.
#
# One recursive git-tree call per repo gives every path at once, which is what
# makes the "does this repo even HAVE a runtime?" question answerable — probing
# for a dozen manifest filenames individually would cost a dozen API calls per
# repo and still miss monorepo sub-packages.

# Keys declared under one top-level table of a mise config — `tools` for rule 1,
# `tasks` for rule 4. Handles both spellings: a flat `node = "20"` under
# `[tools]`, and a `[tools.node]` / `[tasks."test:fast"]` sub-table.
#
# TOML by awk is only safe because these two tables are flat key/value; anything
# richer belongs in a real parser. The section filter is what makes it safe at
# all: BQE-Collector's real mise.toml carries an `[env]` block and seven
# `[tasks.*]` tables, and a parser that grabbed every `key =` line would credit
# `_.path` and `PHP_EXTRA_CONFIGURE_OPTIONS` as pinned tools, then report every
# runtime as pinned — a silent false pass, the worst outcome this audit has.
mise_section_keys() {
  local body="$1" path="$2" section="$3"
  if [ "$path" = ".tool-versions" ]; then
    # asdf's format pins tools and has no notion of tasks.
    [ "$section" = "tools" ] || return 0
    printf '%s\n' "$body" | awk '!/^[[:space:]]*#/ && NF { print $1 }'
    return
  fi
  printf '%s\n' "$body" | awk -v want="$section" '
    BEGIN { plen = length(want) + 1 }
    /^[[:space:]]*#/ { next }
    /^[[:space:]]*\[/ {
      s = $0
      sub(/^[[:space:]]*\[+/, "", s); sub(/\]+.*$/, "", s)
      gsub(/[[:space:]]/, "", s); gsub(/"/, "", s); gsub(/\047/, "", s)
      sect = s
      if (index(sect, want ".") == 1 && length(sect) > plen) print substr(sect, plen + 1)
      next
    }
    sect == want && /=/ {
      k = $0; sub(/=.*$/, "", k)
      gsub(/[[:space:]]/, "", k); gsub(/"/, "", k); gsub(/\047/, "", k)
      if (k != "") print k
    }
  '
}

# Reshape a cached git-tree response into the decision module's input document.
# The tree is read from a FILE, not a shell variable: a large repo's recursive
# tree runs to megabytes, and passing that through argv (`jq --argjson`) would
# hit ARG_MAX and fail the repo — reported as `unknown` rather than judged.
mise_facts() {
  local tree_file="$1" repo="$2" tools="$3" tasks="$4"
  jq -c --arg repo "$repo" --argjson tools "$tools" --argjson tasks "$tasks" '{
    repo: $repo,
    truncated: (if .truncated then true else false end),
    paths: [.tree[] | select(.type == "blob") | .path],
    mise_tools: $tools,
    mise_tasks: $tasks
  }' <"$tree_file"
}

# Emit the decision JSON for one repo. Any API failure (empty repo, no default
# branch, revoked read) degrades to `unknown` rather than a false `missing`.
mise_decision() {
  local repo="$1" branch="$2" tree_file="${MISE_TREE_TMP}" decision config body tools_json tasks_json

  gh api "repos/${ORG}/${repo}/git/trees/${branch}?recursive=1" >"$tree_file" 2>/dev/null || true
  if ! jq -e '.tree' <"$tree_file" >/dev/null 2>&1; then
    jq -nc --arg repo "$repo" '{
      repo: $repo, config: null, canonical: false, detected: [], unmanaged: [],
      devcontainer: null, violations: [], headline: null, state: "unknown"
    }'
    return
  fi

  # Two passes so the config-path list stays owned solely by the jq module: the
  # first tells us WHICH config file exists (if any), the second judges the rules
  # once its [tools] and [tasks] are known. No extra API call — the tree is
  # already in hand, and a repo with no config never reads a file at all. The
  # first pass already decides rule 2 (`.devcontainer/`), which needs no config.
  decision="$(mise_facts "$tree_file" "$repo" '[]' '[]' | jq -c -f "${MISE_DECIDE}")"
  config="$(printf '%s' "$decision" | jq -r '.config // ""')"
  if [ -z "$config" ]; then printf '%s\n' "$decision"; return; fi

  body="$(gh api "repos/${ORG}/${repo}/contents/${config}" --jq '.content' 2>/dev/null \
          | base64 -d 2>/dev/null || true)"
  tools_json="$(mise_section_keys "$body" "$config" tools | jq -R . | jq -sc 'map(select(length>0))')"
  tasks_json="$(mise_section_keys "$body" "$config" tasks | jq -R . | jq -sc 'map(select(length>0))')"
  mise_facts "$tree_file" "$repo" "$tools_json" "$tasks_json" | jq -c -f "${MISE_DECIDE}"
}

# Debug/test entry point: read a mise config on stdin, print the keys the audit
# would credit it with under `[tools]` (rule 1) or `[tasks]` (rule 4). Exists so
# scripts/test/org-ci-audit-mise_test.sh can exercise the REAL parser rather
# than a copy that drifts from it.
#   scripts/org-ci-audit.sh --mise-tools mise.toml < mise.toml
#   scripts/org-ci-audit.sh --mise-tasks mise.toml < mise.toml
if [ "${1:-}" = "--mise-tools" ]; then
  mise_section_keys "$(cat)" "${2:-mise.toml}" tools
  exit 0
fi
if [ "${1:-}" = "--mise-tasks" ]; then
  mise_section_keys "$(cat)" "${2:-mise.toml}" tasks
  exit 0
fi

command -v gh >/dev/null || { echo "gh not found" >&2; exit 2; }

# Debug entry point: print the mise decision for a single repo. The dashboard
# takes minutes to regenerate, so this is how you check one repo's cell — or
# confirm a reported gap is real — without a full org sweep.
#   scripts/org-ci-audit.sh --mise-repo BQE-Collector [branch]
if [ "${1:-}" = "--mise-repo" ]; then
  mise_decision "${2:?--mise-repo needs a repo name}" \
    "${3:-$(gh api "repos/${ORG}/${2}" --jq '.default_branch' 2>/dev/null || echo main)}" | jq .
  exit 0
fi

# --- 1. Repo inventory (name, visibility, language, archived) --------------
repos_json="$(gh api "orgs/${ORG}/repos?per_page=100&type=all" --paginate \
  --jq '[.[] | select(.archived==false) | {name, visibility, language, default_branch}]' | jq -s 'add')"

# --- 2. ci-exception property values (one call for the whole org) ----------
# Map: repo -> ci-exception value ("docs" or empty).
props_json="$(gh api "orgs/${ORG}/properties/values?per_page=100" --paginate \
  --jq '[.[] | {name: .repository_name, exc: ((.properties[]? | select(.property_name=="ci-exception") | .value) // "")}]' \
  | jq -s 'add // []')"

# --- 3. Per-repo caller detection ------------------------------------------
# Returns the set of SpiceLabsHQ reusable workflow names referenced by the
# repo's .github/workflows/*.yml (space-separated), or empty.
installed_callers() {
  local repo="$1" files f content names=""
  files="$(gh api "repos/${ORG}/${repo}/contents/.github/workflows" --jq '.[].path' 2>/dev/null || true)"
  [ -z "$files" ] && { echo ""; return; }
  while IFS= read -r f; do
    [ -z "$f" ] && continue
    content="$(gh api "repos/${ORG}/${repo}/contents/${f}" --jq '.content' 2>/dev/null | base64 -d 2>/dev/null || true)"
    # Extract referenced reusable names: SpiceLabsHQ/.github/.github/workflows/<name>.yml
    while IFS= read -r n; do
      [ -z "$n" ] && continue
      case " $names " in *" $n "*) : ;; *) names="$names $n" ;; esac
    done < <(printf '%s\n' "$content" | grep -oE 'SpiceLabsHQ/\.github/\.github/workflows/[a-z-]+\.yml' | sed -E 's#.*/##; s#\.yml$##' | sort -u)
  done < <(printf '%s\n' "$files" | grep -E '\.ya?ml$')
  echo "${names# }"
}

has_caller() { case " $1 " in *" $2 "*) return 0 ;; *) return 1 ;; esac; }

# Auto-merge coverage (DEV-505). Read via GraphQL `autoMergeAllowed`, which is
# exposed with plain repo read (Metadata). REST's `.allow_auto_merge` requires
# Administration:read — which the scheduled audit App token does NOT have, so
# REST would report every repo `false` even when auto-merge is enabled.
allow_auto_merge() {
  gh api graphql -f query="{ repository(owner: \"${ORG}\", name: \"$1\") { autoMergeAllowed } }" \
    --jq '.data.repository.autoMergeAllowed // false' 2>/dev/null | grep -q true
}
# Dependabot alerts coverage (DEV-1142). Read via GraphQL
# `hasVulnerabilityAlertsEnabled` for the same reason as `autoMergeAllowed`
# above: REST's GET /repos/{o}/{r}/vulnerability-alerts requires
# Administration:read, which the scheduled audit App token does NOT have — and
# REST signals "off" with a 404, which is indistinguishable from a permission
# failure. GraphQL answers the question with plain Metadata read, as an explicit
# boolean.
#
# THREE STATES, NOT TWO. A field the token could not read must report `unknown`,
# never `off`. This column is the enforcement point for a security guarantee, so
# a false `off` costs twice: someone spends the fix on a repo that was already
# fine, and every real gap loses credibility by association. Same reasoning that
# made a cross-repo 404 read as unverifiable rather than missing.
#
# Split from the network call so the decision can be fixture-tested without an
# org-scoped token — scripts/test/org-ci-audit-dependabot_test.sh sources this
# exact function. Echoes `on`, `off`, or `unknown`.
dependabot_state_from_response() {
  local response="$1" value
  # An `errors` block means we learned nothing, including the permission case:
  # GraphQL returns data.repository = null there, which would otherwise fall
  # through and read as a definite answer.
  if printf '%s' "$response" | jq -e 'has("errors")' >/dev/null 2>&1; then
    echo "unknown"; return
  fi
  # Decide on the field's TYPE, not on the text jq prints for it. `-r` renders
  # the JSON string "false" and the boolean false identically, so a text-only
  # match would read a malformed response as a definite "alerts are off" — the
  # one answer this function must never invent.
  value="$(printf '%s' "$response" | jq -r '
    .data.repository.hasVulnerabilityAlertsEnabled as $v
    | if ($v | type) == "boolean" then (if $v then "on" else "off" end) else "unknown" end
  ' 2>/dev/null || true)"
  case "$value" in
    on|off) echo "$value" ;;
    *)      echo "unknown" ;;   # null, absent, empty, unparseable, or non-boolean
  esac
}

# Note the deliberate absence of a `// false` default on the jq read: unlike
# `allow_auto_merge` above, this must not collapse "could not read" into "off".
dependabot_state() {
  local response
  # A non-zero gh exit leaves $response empty, which the decision reads as
  # `unknown` — the correct answer, so the failure needs no separate branch.
  response="$(gh api graphql -f query="{ repository(owner: \"${ORG}\", name: \"$1\") { hasVulnerabilityAlertsEnabled } }" 2>/dev/null || true)"
  dependabot_state_from_response "$response"
}

# A required *test* check is enforced via a repo-level `spice-required-tests`
# ruleset (per-repo because check-run names differ per repo — see DEV-505). The
# rulesets list includes org-inherited rulesets, so match by our exact name.
has_required_tests() {
  gh api "repos/${ORG}/$1/rulesets" --jq 'any(.name=="spice-required-tests")' 2>/dev/null | grep -q true
}


# --- 4. Build dashboard -----------------------------------------------------
printf '# CI Floor & Maturity Dashboard\n\n'
printf '_Auto-generated by [`scripts/org-ci-audit.sh`](../blob/main/scripts/org-ci-audit.sh) (DEV-499). Floor is enforced by org rulesets; this dashboard tracks coverage, Renovate, Dependabot alerts, mise toolchain pinning, and the Silver/Gold ladder._\n\n'
printf '_Renovate column (DEV-1153): **✅** = config extends the shared preset `github>SpiceLabsHQ/.github`; **⚠️** = a config exists but does not; **❌** = no config at all. Presence alone is not compliance._\n\n'
printf '_Since DEV-1140 every repo also inherits [`SpiceLabsHQ/renovate-config`](https://github.com/SpiceLabsHQ/renovate-config) beneath its own config, which changes what these marks mean but not whether they are violations. **❌** no longer means unwatched — the org preset now reaches a repo with no config of its own. **⚠️** is narrower than it was: the inherited layer supplies auto-merge, the release-age soak and the `vulnerabilityAlerts` CVE carve-out (still subject to the Dep-alerts caveat below), so only the keys the repo sets for itself diverge from org policy. Rule 2 of `dependency-management.md` still requires the per-repo `extends`, so **⚠️** and **❌** both remain violations — the inherited config is a safety net, not the standard._\n\n'
printf '_Dep-alerts column (DEV-1142): **✅** = Dependabot alerts are enabled; **❌** = off, so the preset'"'"'s `vulnerabilityAlerts` carve-out matches nothing — a CVE fix waits out the full 7-day `minimumReleaseAge`, and GitHub Actions CVEs go uncovered entirely (OSV has no `github-tags` ecosystem); **?** = the audit token could not read the field, which is NOT the same as off and raises no action. Renovate ✅ with Dep-alerts ❌ is the trap this column exists to expose: dependency policy that reads as compliant while carrying no security fast-path._\n\n'
printf '_Gold column = release automation (both `release-please` **and** `release-artifacts` installed); the ladder'"'"'s SHA-pinning criterion is not auto-checked here._\n\n'
printf '_Auto-merge coverage (DEV-505): **Auto-merge** = repo `allow_auto_merge` is enabled; **AM-fires** = the mechanism that actually merges — code-tier `floor-automerge`, or Renovate `platformAutomerge` via the shared preset (`preset`); **Req-test** = a `spice-required-tests` ruleset gates the default branch on a real test check. Docs-tier repos have no `floor-automerge` injected, so Renovate `platformAutomerge` (`preset`) is what arms the merge there; `floor-pepper` **is** injected on the docs tier (ADR-0016), so the org-wide one-approval gate can be satisfied by Pepper rather than by a human._\n\n'
printf '_**mise** column = the auditable rules of [`standards/development-environment.md`](https://github.com/SpiceLabsHQ/Eng-Cookbook/blob/main/standards/development-environment.md) (ADR-0024), whose Enforcement section marks them "audited, not blocked". Checked here: **rule 1** (toolchain pinned in a committed root `mise.toml`, covering every runtime the repo has), **rule 2** (no `.devcontainer/` — unconditional, so it applies even to a repo with no runtime), **rule 4** (a `setup` task where a checkout needs a dependency install). Not checked: rules 5-6 need Dockerfile/workflow inspection, rule 3 is a SHOULD, rules 8-9 need judgment (DEV-1177)._\n\n'
printf '_Cell values: `—` nothing to assess — no language runtime and no devcontainer, which is **not** a violation; `✅` compliant on every checked rule; `⚠️` compliant enough to have a config but violating a rule; `❌` has a runtime and no mise config at all; `?` file listing truncated, so no judgment was made. Detection reads manifests (`package.json`, `composer.json`, `go.mod`, `*.tf`, …) up to two directories deep, ignoring vendored and fixture paths. See [Development-environment gaps](#development-environment-gaps) for the rule each repo violates._\n\n'
printf '| Repo | Vis | Tier | Renovate | Dep-alerts | mise | Auto-merge | AM-fires | Req-test | Silver (scorecard) | Gold (release) | Next rung |\n'
printf '|---|---|---|---|---|---|---|---|---|---|---|---|\n'

honesty_flags=""
next_actions=""
mise_gaps=""

# Iterate repos alphabetically for stable output.
while IFS= read -r repo; do
  [ -z "$repo" ] && continue
  vis="$(printf '%s' "$repos_json" | jq -r --arg r "$repo" '.[] | select(.name==$r) | .visibility')"
  lang="$(printf '%s' "$repos_json" | jq -r --arg r "$repo" '.[] | select(.name==$r) | (.language // "-")')"
  branch="$(printf '%s' "$repos_json" | jq -r --arg r "$repo" '.[] | select(.name==$r) | (.default_branch // "main")')"
  exc="$(printf '%s' "$props_json" | jq -r --arg r "$repo" '(.[] | select(.name==$r) | .exc) // ""')"

  if [ "$exc" = "docs" ]; then tier="docs"; else tier="code"; fi
  [ "$vis" = "public" ] && tier="${tier}+public"

  callers="$(installed_callers "$repo")"
  # Three states, not two: `⚠️` is a config that exists but inherits no org
  # policy, which is the condition this audit used to score as a clean pass.
  case "$(renovate_state "$repo")" in
    on-preset)  renov="✅" ;;
    off-preset) renov="⚠️" ;;
    *)          renov="❌" ;;
  esac

  # Dependabot alerts (DEV-1142) — floor, and scored beside Renovate because it
  # is the source the preset's `vulnerabilityAlerts` carve-out reads from.
  dep_state="$(dependabot_state "$repo")"
  case "$dep_state" in
    on)  dep_cell="✅" ;;
    off) dep_cell="❌" ;;
    *)   dep_cell="?" ;;
  esac

  # Development-environment compliance (DEV-1177). `mstate` drives the cell and
  # the next-rung guidance; `mhead` is the most severe violation's short label.
  mdec="$(mise_decision "$repo" "$branch")"
  mstate="$(printf '%s' "$mdec" | jq -r '.state')"
  mhead="$(printf '%s' "$mdec" | jq -r '.headline // ""')"
  munmanaged="$(printf '%s' "$mdec" | jq -r '.unmanaged | join(", ")')"
  case "$mstate" in
    ok)      mise_cell="✅" ;;
    partial) mise_cell="⚠️ ${mhead}" ;;
    missing) mise_cell="❌ ${mhead}" ;;
    unknown) mise_cell="?" ;;
    *)       mise_cell="—" ;;
  esac

  # Auto-merge coverage (DEV-505).
  if allow_auto_merge "$repo"; then am="✅"; else am="❌"; fi
  case "$tier" in
    # `✅` now means on-preset specifically, so this no longer claims
    # platformAutomerge for a docs repo whose config never inherited it.
    docs*) if [ "$renov" = "✅" ]; then amfires="✅ preset"; else amfires="—"; fi ;;
    *)     amfires="✅ floor" ;;
  esac
  if has_required_tests "$repo"; then reqtest="✅"; else reqtest="—"; fi
  if has_caller "$callers" "scorecard"; then silver="✅"; else silver="—"; fi
  # Gold (release automation) requires BOTH release-please and release-artifacts
  # per the ladder in README — a checkmark must not overstate what's installed.
  # (SHA-pinning of third-party actions is the other Gold criterion; it is not
  # auto-checked here — see the dashboard footnote.)
  gp=false; ga=false
  has_caller "$callers" "release-please" && gp=true
  has_caller "$callers" "release-artifacts" && ga=true
  if $gp && $ga; then gold="✅"; else gold="—"; fi

  # Next rung: Renovate (floor) > Dependabot alerts (floor) > development-
  # environment > Silver > Gold. Alerts sit inside the floor band with Renovate
  # rather than above it because the two compose: the carve-out needs a config
  # extending the preset AND alerts on, and a repo missing both should be told
  # about the config first — that one is a PR, while alerts are one API call. The
  # dev-environment rules sit above the guidance rungs because an unpinned
  # runtime makes every rung above it irreproducible — but they only fire on a
  # real violation, so a repo with nothing to assess never generates an action.
  next="—"
  if [ "$renov" = "❌" ]; then next="add renovate.json (floor)";
  elif [ "$renov" = "⚠️" ]; then next="extend the org preset (\`github>SpiceLabsHQ/.github\`)";
  # Only a definitive `off` is an action. `unknown` means the audit could not
  # read the field; guessing would send someone to re-enable a repo that is
  # already enabled, so it stays in the column and off this list.
  elif [ "$dep_state" = "off" ]; then next="enable Dependabot alerts (floor)";
  elif [ "$mstate" = "missing" ]; then next="adopt mise (pin ${munmanaged})";
  elif [ "$mstate" = "partial" ]; then
    next="dev-env rule $(printf '%s' "$mdec" | jq -r '.violations[0].rule'): ${mhead}";
  elif [ "$tier" != "docs" ] && [ "$silver" = "—" ]; then next="Silver: add scorecard caller";
  elif [ "$tier" != "docs" ] && [ "$gold" = "—" ]; then
    miss=""
    $gp || miss="release-please"
    $ga || miss="${miss:+${miss} + }release-artifacts"
    next="Gold: add ${miss}";
  fi
  [ "$next" != "—" ] && next_actions="${next_actions}- **${repo}** — ${next}\n"

  # Exception honesty: docs-tagged but non-static language or has real workflows.
  if [ "$exc" = "docs" ] && ! is_static_lang "$lang"; then
    honesty_flags="${honesty_flags}- **${repo}** tagged \`docs\` but primary language is \`${lang}\` — confirm it hasn't grown code.\n"
  fi

  # Gap detail — one line per violated rule, naming the rule number so a reader
  # can go check it. Only repos with an actual violation appear; a compliant or
  # runtime-free repo is silent here by design, and that silence is what keeps
  # the list worth reading.
  case "$mstate" in
    unknown)
      mise_gaps="${mise_gaps}- **${repo}** — file listing unavailable or truncated; not assessed.\n" ;;
    missing|partial)
      mise_gaps="${mise_gaps}- **${repo}**\n"
      while IFS= read -r vline; do
        [ -z "$vline" ] && continue
        mise_gaps="${mise_gaps}  - ${vline}\n"
      done < <(printf '%s' "$mdec" | jq -r '.violations[] | "rule \(.rule): \(.text)"')
      # Evidence for the unpinned runtimes — the file that proves the gap is
      # real, so a maintainer can check the call rather than trust the cell.
      mevidence="$(printf '%s' "$mdec" | jq -r '
        . as $d | [$d.detected[] | select(.tool as $t | $d.unmanaged | index($t)) | "`\(.evidence)`"] | join(", ")')"
      [ -n "$mevidence" ] && mise_gaps="${mise_gaps}  - evidence: ${mevidence}\n"
      ;;
  esac

  printf '| %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s |\n' \
    "$repo" "$vis" "$tier" "$renov" "$dep_cell" "$mise_cell" "$am" "$amfires" "$reqtest" "$silver" "$gold" "$next"
done < <(printf '%s' "$repos_json" | jq -r '.[].name' | sort)

printf '\n## Next-rung actions\n\n'
if [ -n "$next_actions" ]; then printf '%b' "$next_actions"; else printf '_Everything is at or above its floor._\n'; fi

printf '\n## Development-environment gaps\n\n'
if [ -n "$mise_gaps" ]; then
  printf '%b' "$mise_gaps"
  printf '\n_Rule numbers refer to [`standards/development-environment.md`](https://github.com/SpiceLabsHQ/Eng-Cookbook/blob/main/standards/development-environment.md). Only repos with an actual violation appear here — a repo with no language runtime and no devcontainer is omitted, not passed._\n'
else
  printf '_No repo violates a checked rule of `standards/development-environment.md`._\n'
fi

printf '\n## Exception-list honesty\n\n'
if [ -n "$honesty_flags" ]; then printf '%b' "$honesty_flags"; else printf '_No `docs`-tagged repo shows code indicators._\n'; fi
