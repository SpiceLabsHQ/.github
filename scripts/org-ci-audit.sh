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
#     is not compliance — see renovate_state()
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

command -v gh >/dev/null || { echo "gh not found" >&2; exit 2; }
command -v jq >/dev/null || { echo "jq not found" >&2; exit 2; }

# Static/docs language signals — a repo tagged `docs` whose primary language is
# outside this set is worth a second look (it may have grown code).
is_static_lang() {
  case "${1:-}" in
    HTML|CSS|SCSS|Less|Markdown|Shell|""|null|None|-) return 0 ;;
    *) return 1 ;;
  esac
}

# --- 1. Repo inventory (name, visibility, language, archived) --------------
repos_json="$(gh api "orgs/${ORG}/repos?per_page=100&type=all" --paginate \
  --jq '[.[] | select(.archived==false) | {name, visibility, language}]' | jq -s 'add')"

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

# True when a Renovate config's `extends` pulls in this org's shared preset.
# Matches the documented shorthands and tolerates a `#branch` / `:preset` suffix.
extends_has_preset() {
  local content="$1" entries
  # Parse `extends` properly where we can. A bare substring match would also hit
  # `matchPackageNames: ["SpiceLabsHQ/.github**"]` — a package selector, not a
  # preset reference — and default.json itself contains exactly that.
  entries="$(printf '%s' "$content" | jq -r '(.extends // []) | .[]' 2>/dev/null || true)"
  if [ -n "$entries" ]; then
    printf '%s\n' "$entries" | grep -qiE '^(github|local)>SpiceLabsHQ/\.github([#:].*)?$'
    return
  fi
  # json5 or commented configs jq can't parse: match the preset reference inside
  # an extends array, still avoiding the matchPackageNames form.
  printf '%s' "$content" | tr -d ' \n' \
    | grep -qiE '"extends":\[[^]]*"(github|local)>SpiceLabsHQ/\.github'
}

# Echoes the repo's Renovate state: `none`, `off-preset`, or `on-preset`.
#
# Presence alone is not compliance (DEV-1153). The shared preset (default.json in
# this repo) is where org dependency policy lives — Pepper-gated auto-merge, the
# 7-day minimumReleaseAge soak, and the vulnerabilityAlerts carve-out that lets a
# CVE fix skip that soak. A config that omits the `extends` line inherits none of
# it. This audit previously checked only that a file existed, so nine repos on a
# preset-less seed scored identically to compliant ones for six weeks (DEV-1150).
#
# Renovate accepts several filenames/locations; check the documented set so a
# repo using e.g. renovate.json5 isn't false-flagged as missing.
renovate_state() {
  local repo="$1" p content nested
  for p in renovate.json renovate.json5 .renovaterc .renovaterc.json .renovaterc.json5 \
           .github/renovate.json .github/renovate.json5 .gitlab/renovate.json; do
    content="$(gh api "repos/${ORG}/${repo}/contents/${p}" --jq '.content' 2>/dev/null \
      | base64 -d 2>/dev/null || true)"
    [ -z "$content" ] && continue
    if extends_has_preset "$content"; then echo "on-preset"; else echo "off-preset"; fi
    return
  done
  # Also honor a `renovate` key inside package.json.
  content="$(gh api "repos/${ORG}/${repo}/contents/package.json" --jq '.content' 2>/dev/null \
    | base64 -d 2>/dev/null || true)"
  if printf '%s' "$content" | grep -q '"renovate"'; then
    nested="$(printf '%s' "$content" | jq -c '.renovate // empty' 2>/dev/null || true)"
    if [ -n "$nested" ] && extends_has_preset "$nested"; then echo "on-preset"; else echo "off-preset"; fi
    return
  fi
  echo "none"
}

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
printf '_Auto-generated by [`scripts/org-ci-audit.sh`](../blob/main/scripts/org-ci-audit.sh) (DEV-499). Floor is enforced by org rulesets; this dashboard tracks coverage, Renovate, and the Silver/Gold ladder._\n\n'
printf '_Renovate column (DEV-1153): **✅** = config extends the shared preset `github>SpiceLabsHQ/.github`; **⚠️** = a config exists but does not, so the repo inherits no org dependency policy (no auto-merge, no release-age soak, and no `vulnerabilityAlerts` carve-out to fast-path a CVE fix); **❌** = no config at all. Presence alone is not compliance._\n\n'
printf '_Gold column = release automation (both `release-please` **and** `release-artifacts` installed); the ladder'"'"'s SHA-pinning criterion is not auto-checked here._\n\n'
printf '_Auto-merge coverage (DEV-505): **Auto-merge** = repo `allow_auto_merge` is enabled; **AM-fires** = the mechanism that actually merges — code-tier `floor-automerge`, or Renovate `platformAutomerge` via the shared preset (`preset`); **Req-test** = a `spice-required-tests` ruleset gates the default branch on a real test check. Docs-tier repos have no `floor-automerge`/`floor-pepper` injected, so `preset` auto-merge there still needs an approver._\n\n'
printf '| Repo | Vis | Tier | Renovate | Auto-merge | AM-fires | Req-test | Silver (scorecard) | Gold (release) | Next rung |\n'
printf '|---|---|---|---|---|---|---|---|---|---|\n'

honesty_flags=""
next_actions=""

# Iterate repos alphabetically for stable output.
while IFS= read -r repo; do
  [ -z "$repo" ] && continue
  vis="$(printf '%s' "$repos_json" | jq -r --arg r "$repo" '.[] | select(.name==$r) | .visibility')"
  lang="$(printf '%s' "$repos_json" | jq -r --arg r "$repo" '.[] | select(.name==$r) | (.language // "-")')"
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

  # Next rung: Renovate (floor) > Silver > Gold.
  next="—"
  if [ "$renov" = "❌" ]; then next="add renovate.json (floor)";
  elif [ "$renov" = "⚠️" ]; then next="extend the org preset (\`github>SpiceLabsHQ/.github\`)";
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

  printf '| %s | %s | %s | %s | %s | %s | %s | %s | %s | %s |\n' \
    "$repo" "$vis" "$tier" "$renov" "$am" "$amfires" "$reqtest" "$silver" "$gold" "$next"
done < <(printf '%s' "$repos_json" | jq -r '.[].name' | sort)

printf '\n## Next-rung actions\n\n'
if [ -n "$next_actions" ]; then printf '%b' "$next_actions"; else printf '_Everything is at or above its floor._\n'; fi

printf '\n## Exception-list honesty\n\n'
if [ -n "$honesty_flags" ]; then printf '%b' "$honesty_flags"; else printf '_No `docs`-tagged repo shows code indicators._\n'; fi
