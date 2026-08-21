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
#   - mise toolchain coverage: whether every language runtime the repo actually
#     has is pinned by a mise config. Deliberately three-state — a repo with no
#     runtime at all reads `—`, not a violation (see org-ci-audit-mise.jq)
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

# Tool names declared by a mise config. Handles the two `[tools]` spellings
# (`node = "20"` and a `[tools.node]` sub-table) plus asdf's `.tool-versions`.
# TOML by awk is only safe because these tables are flat key/value; anything
# richer belongs in a real parser.
mise_tools_from_config() {
  local body="$1" path="$2"
  if [ "$path" = ".tool-versions" ]; then
    printf '%s\n' "$body" | awk '!/^[[:space:]]*#/ && NF { print $1 }'
    return
  fi
  printf '%s\n' "$body" | awk '
    /^[[:space:]]*#/ { next }
    /^[[:space:]]*\[/ {
      s = $0
      sub(/^[[:space:]]*\[+/, "", s); sub(/\]+.*$/, "", s)
      gsub(/[[:space:]]/, "", s); gsub(/"/, "", s); gsub(/\047/, "", s)
      sect = s
      if (sect ~ /^tools\./ && length(sect) > 6) print substr(sect, 7)
      next
    }
    sect == "tools" && /=/ {
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
  local tree_file="$1" repo="$2" tools="$3"
  jq -c --arg repo "$repo" --argjson tools "$tools" '{
    repo: $repo,
    truncated: (if .truncated then true else false end),
    paths: [.tree[] | select(.type == "blob") | .path],
    mise_tools: $tools
  }' <"$tree_file"
}

# Emit the decision JSON for one repo. Any API failure (empty repo, no default
# branch, revoked read) degrades to `unknown` rather than a false `missing`.
mise_decision() {
  local repo="$1" branch="$2" tree_file="${MISE_TREE_TMP}" decision config body tools_json

  gh api "repos/${ORG}/${repo}/git/trees/${branch}?recursive=1" >"$tree_file" 2>/dev/null || true
  if ! jq -e '.tree' <"$tree_file" >/dev/null 2>&1; then
    jq -nc --arg repo "$repo" \
      '{repo:$repo, config:null, detected:[], unmanaged:[], state:"unknown"}'
    return
  fi

  # Two passes so the config-path list stays owned solely by the jq module: the
  # first tells us WHICH config file exists (if any), the second judges coverage
  # once its [tools] are known. No extra API call — the tree is already in hand,
  # and a repo with no config never reads a file at all.
  decision="$(mise_facts "$tree_file" "$repo" '[]' | jq -c -f "${MISE_DECIDE}")"
  config="$(printf '%s' "$decision" | jq -r '.config // ""')"
  if [ -z "$config" ]; then printf '%s\n' "$decision"; return; fi

  body="$(gh api "repos/${ORG}/${repo}/contents/${config}" --jq '.content' 2>/dev/null \
          | base64 -d 2>/dev/null || true)"
  tools_json="$(mise_tools_from_config "$body" "$config" | jq -R . | jq -sc 'map(select(length>0))')"
  mise_facts "$tree_file" "$repo" "$tools_json" | jq -c -f "${MISE_DECIDE}"
}

# Debug/test entry point: read a mise config on stdin, print the tool names the
# audit would credit it with. Exists so scripts/test/org-ci-audit-mise_test.sh
# can exercise the REAL parser rather than a copy that drifts from it.
#   scripts/org-ci-audit.sh --mise-tools mise.toml < mise.toml
if [ "${1:-}" = "--mise-tools" ]; then
  mise_tools_from_config "$(cat)" "${2:-mise.toml}"
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
# A required *test* check is enforced via a repo-level `spice-required-tests`
# ruleset (per-repo because check-run names differ per repo — see DEV-505). The
# rulesets list includes org-inherited rulesets, so match by our exact name.
has_required_tests() {
  gh api "repos/${ORG}/$1/rulesets" --jq 'any(.name=="spice-required-tests")' 2>/dev/null | grep -q true
}


# --- 4. Build dashboard -----------------------------------------------------
printf '# CI Floor & Maturity Dashboard\n\n'
printf '_Auto-generated by [`scripts/org-ci-audit.sh`](../blob/main/scripts/org-ci-audit.sh) (DEV-499). Floor is enforced by org rulesets; this dashboard tracks coverage, Renovate, mise toolchain pinning, and the Silver/Gold ladder._\n\n'
printf '_Renovate column (DEV-1153): **✅** = config extends the shared preset `github>SpiceLabsHQ/.github`; **⚠️** = a config exists but does not, so the repo inherits no org dependency policy (no auto-merge, no release-age soak, and no `vulnerabilityAlerts` carve-out to fast-path a CVE fix); **❌** = no config at all. Presence alone is not compliance._\n\n'
printf '_Gold column = release automation (both `release-please` **and** `release-artifacts` installed); the ladder'"'"'s SHA-pinning criterion is not auto-checked here._\n\n'
printf '_Auto-merge coverage (DEV-505): **Auto-merge** = repo `allow_auto_merge` is enabled; **AM-fires** = the mechanism that actually merges — code-tier `floor-automerge`, or Renovate `platformAutomerge` via the shared preset (`preset`); **Req-test** = a `spice-required-tests` ruleset gates the default branch on a real test check. Docs-tier repos have no `floor-automerge`/`floor-pepper` injected, so `preset` auto-merge there still needs an approver._\n\n'
printf '_**mise** = toolchain pinning. Three-state on purpose: `—` means the repo has no language runtime for mise to manage (docs, PowerShell, markdown) and is **not** a violation; `✅` every detected runtime is pinned by a mise config; `⚠️` a mise config exists but leaves a runtime unpinned; `❌` the repo has a runtime and no mise config; `?` the file listing was truncated, so no judgment was made. Detection reads manifests (`package.json`, `composer.json`, `go.mod`, `*.tf`, …) up to two directories deep, ignoring vendored and fixture paths. See [Toolchain (mise) gaps](#toolchain-mise-gaps) for which runtime is unpinned where._\n\n'
printf '| Repo | Vis | Tier | Renovate | mise | Auto-merge | AM-fires | Req-test | Silver (scorecard) | Gold (release) | Next rung |\n'
printf '|---|---|---|---|---|---|---|---|---|---|---|\n'

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

  # mise toolchain coverage. `mstate` drives both the cell and the next-rung
  # guidance; `munmanaged` names the runtimes nothing is pinning.
  mdec="$(mise_decision "$repo" "$branch")"
  mstate="$(printf '%s' "$mdec" | jq -r '.state')"
  munmanaged="$(printf '%s' "$mdec" | jq -r '.unmanaged | join(", ")')"
  # Evidence for the unmanaged runtimes only — the file that proves the gap is
  # real, so a maintainer can check the call rather than trust the checkmark.
  mevidence="$(printf '%s' "$mdec" | jq -r '
    . as $d | [$d.detected[] | select(.tool as $t | $d.unmanaged | index($t)) | "`\(.evidence)`"] | join(", ")')"
  case "$mstate" in
    ok)      mise_cell="✅" ;;
    partial) mise_cell="⚠️ ${munmanaged}" ;;
    missing) mise_cell="❌ ${munmanaged}" ;;
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

  # Next rung: Renovate (floor) > mise > Silver > Gold. mise sits above the
  # guidance rungs because an unpinned runtime makes every rung above it
  # irreproducible — but only where a runtime actually exists, so `na` repos
  # never generate an action.
  next="—"
  if [ "$renov" = "❌" ]; then next="add renovate.json (floor)";
  elif [ "$renov" = "⚠️" ]; then next="extend the org preset (\`github>SpiceLabsHQ/.github\`)";
  elif [ "$mstate" = "missing" ]; then next="adopt mise (pin ${munmanaged})";
  elif [ "$mstate" = "partial" ]; then next="mise: pin ${munmanaged}";
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

  # mise gap detail — only for repos that demonstrably have a runtime. A `na`
  # repo is silent here by design; that silence is what keeps the list credible.
  case "$mstate" in
    missing)
      mise_gaps="${mise_gaps}- **${repo}** — no mise config; unpinned: \`${munmanaged}\` (seen in ${mevidence}).\n" ;;
    partial)
      mise_gaps="${mise_gaps}- **${repo}** — has \`$(printf '%s' "$mdec" | jq -r '.config')\` but leaves \`${munmanaged}\` unpinned (seen in ${mevidence}).\n" ;;
    unknown)
      mise_gaps="${mise_gaps}- **${repo}** — file listing unavailable or truncated; toolchain not assessed.\n" ;;
  esac

  printf '| %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s |\n' \
    "$repo" "$vis" "$tier" "$renov" "$mise_cell" "$am" "$amfires" "$reqtest" "$silver" "$gold" "$next"
done < <(printf '%s' "$repos_json" | jq -r '.[].name' | sort)

printf '\n## Next-rung actions\n\n'
if [ -n "$next_actions" ]; then printf '%b' "$next_actions"; else printf '_Everything is at or above its floor._\n'; fi

printf '\n## Toolchain (mise) gaps\n\n'
if [ -n "$mise_gaps" ]; then
  printf '%b' "$mise_gaps"
  printf '\n_Only repos with a detected language runtime appear here. Repos with nothing for mise to manage are omitted, not passed._\n'
else
  printf '_Every repo with a detected language runtime pins it with mise._\n'
fi

printf '\n## Exception-list honesty\n\n'
if [ -n "$honesty_flags" ]; then printf '%b' "$honesty_flags"; else printf '_No `docs`-tagged repo shows code indicators._\n'; fi
