#!/usr/bin/env bash
# Sync a Linear label group with a set of GitHub objects.
#
# Two sources are supported (see the `source` input):
#   repos   — every repository of a GitHub org/user
#   actions — every reusable workflow (`on: workflow_call`) hosted in one or
#             more repositories
#
# Renames are tracked via a STABLE KEY stashed in the label's description.
# Reconciliation keys on that key, never on the name, so when the underlying
# object is renamed we UPDATE the existing label (preserving every issue tagged
# with it) instead of creating a fresh one and orphaning the old.
#
# Label description format (single line, human-readable + machine tag). The tag
# is always LAST so the parser can capture it as a single non-space run:
#   repos:   Auto-managed by linear-github-labels • gh-repo-id:123456
#   actions: Auto-managed by linear-github-labels • gh-action:123456:.github/workflows/sast.yml
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=detect.sh
. "${SCRIPT_DIR}/detect.sh"

LINEAR_API="https://api.linear.app/graphql"
TAG_PREFIX="Auto-managed by linear-github-labels"

SOURCE="${INPUT_SOURCE:-repos}"
OWNER="${INPUT_OWNER:?owner is required}"
GROUP_NAME="${INPUT_GROUP_NAME:-repo}"
TEAM="${INPUT_TEAM:-}"
LOWER="${INPUT_LOWERCASE:-true}"
INC_FORKS="${INPUT_INCLUDE_FORKS:-true}"
INC_ARCH="${INPUT_INCLUDE_ARCHIVED:-false}"
ACTION_REPOS="${INPUT_ACTION_REPOS:-}"
SEPARATOR="${INPUT_NAME_SEPARATOR:-/}"
COLOR="${INPUT_COLOR:-}"
PRUNE="${INPUT_PRUNE:-report}"
DRY_RUN="${INPUT_DRY_RUN:-false}"

: "${LINEAR_API_KEY:?linear-api-key is required}"
: "${GH_TOKEN:?github-token is required}"

case "$SOURCE" in
  repos|actions) ;;
  *) echo "::error::source must be one of: repos | actions (got '$SOURCE')"; exit 1 ;;
esac

case "$PRUNE" in
  report|archive|delete) ;;
  *) echo "::error::prune must be one of: report | archive | delete (got '$PRUNE')"; exit 1 ;;
esac

# --- Linear GraphQL helper ---------------------------------------------------
# linear_gql <query> [variables-json] -> prints the full JSON response.
# Fails (non-zero) and logs if the response contains a GraphQL error.
linear_gql() {
  local query="$1" vars="${2:-}" resp
  [ -z "$vars" ] && vars='{}'
  resp="$(curl -sS -X POST "$LINEAR_API" \
    -H "Authorization: ${LINEAR_API_KEY}" \
    -H "Content-Type: application/json" \
    --data "$(jq -n --arg q "$query" --argjson v "$vars" '{query:$q, variables:$v}')")"
  if jq -e 'has("errors")' >/dev/null 2>&1 <<<"$resp"; then
    echo "::error::Linear API error: $(jq -c '.errors' <<<"$resp")" >&2
    return 1
  fi
  printf '%s' "$resp"
}

# --- 1. Enumerate items ------------------------------------------------------
# Each source produces $items_json: [ {id, name} ] where `id` is the stable key
# written into the label description, and `name` is the label text. Progress
# chatter goes to stderr so it can't contaminate the captured JSON.

enumerate_repos() {
  echo "Resolving account type for '${OWNER}'…" >&2
  OWNER_TYPE="$(gh api "/users/${OWNER}" --jq '.type')"
  if [ "$OWNER_TYPE" = "Organization" ]; then
    REPO_PATH="/orgs/${OWNER}/repos"; LIST_TYPE="all"
  else
    REPO_PATH="/users/${OWNER}/repos"; LIST_TYPE="owner"
  fi
  echo "  ${OWNER} is a ${OWNER_TYPE}; listing via ${REPO_PATH}?type=${LIST_TYPE}" >&2

  local ndjson
  ndjson="$(gh api --paginate "${REPO_PATH}?per_page=100&type=${LIST_TYPE}" \
    --jq '.[] | {id, name, fork, archived}')"

  jq -s \
    --argjson lower "$LOWER" \
    --argjson incforks "$INC_FORKS" \
    --argjson incarch "$INC_ARCH" '
    [ .[]
      | select($incforks or (.fork | not))
      | select($incarch or (.archived | not))
      | {id: (.id | tostring), name: (if $lower then (.name | ascii_downcase) else .name end)} ]' \
    <<<"$ndjson"
}

enumerate_actions() {
  local repos_csv="${ACTION_REPOS:-${OWNER}/.github}"
  local out='[]'
  local repo repo_id repo_label paths path body label
  local -a repo_list=()

  IFS=',' read -ra repo_list <<<"$repos_csv"
  for repo in "${repo_list[@]}"; do
    repo="$(printf '%s' "$repo" | tr -d '[:space:]')"
    [ -z "$repo" ] && continue
    # Bare names are interpreted as belonging to `owner`.
    [[ "$repo" == */* ]] || repo="${OWNER}/${repo}"

    echo "Scanning ${repo} for reusable workflows…" >&2
    repo_id="$(gh api "/repos/${repo}" --jq '.id')"
    repo_label="${repo#*/}"
    [ "$LOWER" = "true" ] && repo_label="$(tr '[:upper:]' '[:lower:]' <<<"$repo_label")"

    # A repo with no .github/workflows directory is not an error — skip it.
    paths="$(gh api "/repos/${repo}/contents/.github/workflows" \
      --jq '.[] | select(.type == "file") | select(.name | test("\\.ya?ml$")) | .path' 2>/dev/null || true)"
    if [ -z "$paths" ]; then
      echo "  no .github/workflows directory — skipping" >&2
      continue
    fi

    while IFS= read -r path; do
      [ -z "$path" ] && continue
      body="$(gh api "/repos/${repo}/contents/${path}" --jq '.content' | base64 -d)"
      is_reusable_workflow "$body" || continue

      label="$(basename "$path")"; label="${label%.yml}"; label="${label%.yaml}"
      [ "$LOWER" = "true" ] && label="$(tr '[:upper:]' '[:lower:]' <<<"$label")"

      out="$(jq \
        --arg id "gh-action:${repo_id}:${path}" \
        --arg name "${repo_label}${SEPARATOR}${label}" \
        '. + [{id:$id, name:$name}]' <<<"$out")"
      echo "  ✓ ${repo_label}${SEPARATOR}${label}" >&2
    done <<<"$paths"
  done

  printf '%s' "$out"
}

OWNER_TYPE=""
case "$SOURCE" in
  repos)   items_json="$(enumerate_repos)";   ID_PATTERN='gh-repo-id:(?<i>[0-9]+)' ;;
  actions) items_json="$(enumerate_actions)"; ID_PATTERN='(?<i>gh-action:\S+)' ;;
esac

ITEM_COUNT="$(jq 'length' <<<"$items_json")"
echo "  ${ITEM_COUNT} item(s) from source '${SOURCE}'."
if [ "$ITEM_COUNT" -eq 0 ]; then
  echo "::warning::No items found for source '${SOURCE}'. Check the github-token scope. Skipping to avoid pruning the whole group by mistake."
  exit 0
fi

# Two items resolving to the same label name would make the plan ambiguous (the
# second shows up as a conflict against the first). Surface it as a warning.
dupes="$(jq -r 'group_by(.name) | map(select(length > 1) | .[0].name) | .[]' <<<"$items_json")"
if [ -n "$dupes" ]; then
  echo "::warning::Duplicate label names in the item set — later items will be reported as conflicts: $(tr '\n' ' ' <<<"$dupes")"
fi

# --- 2. Resolve the Linear team (optional) -----------------------------------
TEAM_ID=""
if [ -n "$TEAM" ]; then
  teams_json="$(linear_gql 'query{ teams(first:250){ nodes{ id key name } } }')"
  TEAM_ID="$(jq -r --arg q "$TEAM" '
    [ .data.teams.nodes[]
      | select((.key | ascii_downcase) == ($q | ascii_downcase)
            or (.name | ascii_downcase) == ($q | ascii_downcase)) ]
    | .[0].id // empty' <<<"$teams_json")"
  [ -z "$TEAM_ID" ] && { echo "::error::Linear team not found: ${TEAM}"; exit 1; }
  echo "Scoping label group to team '${TEAM}' (${TEAM_ID})."
else
  echo "Label group is workspace-level (no team scope)."
fi

# --- 3. Find or create the label group ---------------------------------------
grp_json="$(linear_gql \
  'query($n:String!){ issueLabels(filter:{name:{eq:$n}}, first:250){ nodes{ id name isGroup team{id} } } }' \
  "$(jq -n --arg n "$GROUP_NAME" '{n:$n}')")"

GROUP_ID="$(jq -r --arg tid "$TEAM_ID" '
  [ .data.issueLabels.nodes[]
    | select(.isGroup == true)
    | select( ($tid == "" and .team == null) or (.team != null and .team.id == $tid) ) ]
  | .[0].id // empty' <<<"$grp_json")"

if [ -z "$GROUP_ID" ]; then
  # Guard: a non-group label with the same name in the same scope would collide.
  clash="$(jq -r --arg tid "$TEAM_ID" '
    [ .data.issueLabels.nodes[]
      | select(.isGroup != true)
      | select( ($tid == "" and .team == null) or (.team != null and .team.id == $tid) ) ]
    | .[0].id // empty' <<<"$grp_json")"
  if [ -n "$clash" ]; then
    echo "::error::A non-group label named '${GROUP_NAME}' already exists in this scope. Rename or delete it, or choose a different group-name."
    exit 1
  fi
  echo "Creating label group '${GROUP_NAME}'…"
  if [ "$DRY_RUN" = "true" ]; then
    echo "  [dry-run] would create group '${GROUP_NAME}'"
    GROUP_ID="DRYRUN_GROUP"
  else
    create_input="$(jq -n --arg n "$GROUP_NAME" --arg tid "$TEAM_ID" \
      '{name:$n, isGroup:true} + (if $tid == "" then {} else {teamId:$tid} end)')"
    res="$(linear_gql \
      'mutation($i:IssueLabelCreateInput!){ issueLabelCreate(input:$i){ success issueLabel{ id } } }' \
      "$(jq -n --argjson i "$create_input" '{i:$i}')")"
    GROUP_ID="$(jq -r '.data.issueLabelCreate.issueLabel.id' <<<"$res")"
    echo "  created group ${GROUP_ID}"
  fi
else
  echo "Found label group '${GROUP_NAME}' (${GROUP_ID})."
fi

# --- 4. Fetch the group's current children (paginated) -----------------------
children_json='[]'
if [ "$GROUP_ID" != "DRYRUN_GROUP" ]; then
  after="null"
  while :; do
    page="$(linear_gql \
      'query($pid:ID!,$after:String){ issueLabels(filter:{parent:{id:{eq:$pid}}}, first:250, after:$after){ nodes{ id name description } pageInfo{ hasNextPage endCursor } } }' \
      "$(jq -n --arg pid "$GROUP_ID" --argjson after "$after" '{pid:$pid, after:$after}')")"
    children_json="$(jq -s '.[0] + .[1]' \
      <(printf '%s' "$children_json") \
      <(jq '.data.issueLabels.nodes' <<<"$page"))"
    if [ "$(jq -r '.data.issueLabels.pageInfo.hasNextPage' <<<"$page")" = "true" ]; then
      after="$(jq -c '.data.issueLabels.pageInfo.endCursor' <<<"$page")"
    else
      break
    fi
  done
fi

# Annotate each child with the managed key parsed from its description. The
# pattern is source-specific, so the `repo` and `org-actions` groups can never
# read each other's stamps.
children_json="$(jq --arg pat "$ID_PATTERN" '[ .[] | . + {
    managedId: ((.description // "") as $d
      | if ($d | test($pat))
        then ($d | capture($pat).i)
        else null end) } ]' <<<"$children_json")"

echo "Group currently has $(jq 'length' <<<"$children_json") child label(s)."

# --- 5. Compute the reconciliation plan (declarative, in jq) -----------------
# The plan program lives in plan.jq so the fixture test exercises the exact
# same logic that runs in production (see test/plan_test.sh).
plan_json="$(jq -n \
  --argjson items "$items_json" \
  --argjson children "$children_json" \
  -f "${SCRIPT_DIR}/plan.jq")"

# --- 6. Execute the plan -----------------------------------------------------
created=0; renamed=0; adopted=0; pruned=0; conflicts=0; failures=0
declare -a summary_lines=()

run_mut() { # run_mut <query> <vars-json>; returns non-zero on failure
  if [ "$DRY_RUN" = "true" ]; then return 0; fi
  local resp
  # linear_gql already fails on a top-level GraphQL `errors` array. But Linear's
  # label mutations also return `success: Boolean!` in the payload, and a
  # mutation can come back HTTP 200 with errors:null yet success:false — so we
  # must check that field too, or a real per-label failure slips past the
  # failures counter and the final exit-code gate.
  resp="$(linear_gql "$1" "$2")" || return 1
  if [ "$(jq -r '[.data[]?.success] | any(. == false)' <<<"$resp")" = "true" ]; then
    echo "::error::Linear mutation returned success=false: $(jq -c '.data' <<<"$resp")" >&2
    return 1
  fi
  return 0
}

while IFS= read -r item; do
  op="$(jq -r '.op' <<<"$item")"
  name="$(jq -r '.name // ""' <<<"$item")"
  id="$(jq -r '.id // ""' <<<"$item")"
  itemId="$(jq -r '.itemId // ""' <<<"$item")"
  # For `repos` the key is a bare numeric id that needs its tag prefix; for
  # `actions` the key already carries its own `gh-action:` prefix.
  if [ "$SOURCE" = "repos" ]; then
    desc="${TAG_PREFIX} • gh-repo-id:${itemId}"
  else
    desc="${TAG_PREFIX} • ${itemId}"
  fi

  case "$op" in
    create)
      echo "＋ create  '${name}' (${itemId})"
      input="$(jq -n --arg name "$name" --arg pid "$GROUP_ID" --arg tid "$TEAM_ID" --arg d "$desc" --arg c "$COLOR" \
        '{name:$name, parentId:$pid, description:$d}
         + (if $tid == "" then {} else {teamId:$tid} end)
         + (if $c == "" then {} else {color:$c} end)')"
      if run_mut 'mutation($i:IssueLabelCreateInput!){ issueLabelCreate(input:$i){ success } }' \
           "$(jq -n --argjson i "$input" '{i:$i}')"; then
        created=$((created+1)); summary_lines+=("| ➕ created | \`${name}\` | \`${itemId}\` |")
      else failures=$((failures+1)); fi
      ;;
    rename)
      from="$(jq -r '.from' <<<"$item")"
      echo "✎ rename  '${from}' → '${name}' (${itemId}, preserves issues)"
      input="$(jq -n --arg name "$name" '{name:$name}')"
      if run_mut 'mutation($id:String!,$i:IssueLabelUpdateInput!){ issueLabelUpdate(id:$id, input:$i){ success } }' \
           "$(jq -n --arg id "$id" --argjson i "$input" '{id:$id, i:$i}')"; then
        renamed=$((renamed+1)); summary_lines+=("| ✏️ renamed | \`${from}\` → \`${name}\` | \`${itemId}\` |")
      else failures=$((failures+1)); fi
      ;;
    adopt)
      echo "⇲ adopt   existing '${name}' (stamp ${itemId})"
      input="$(jq -n --arg d "$desc" '{description:$d}')"
      if run_mut 'mutation($id:String!,$i:IssueLabelUpdateInput!){ issueLabelUpdate(id:$id, input:$i){ success } }' \
           "$(jq -n --arg id "$id" --argjson i "$input" '{id:$id, i:$i}')"; then
        adopted=$((adopted+1)); summary_lines+=("| 🔗 adopted | \`${name}\` | \`${itemId}\` |")
      else failures=$((failures+1)); fi
      ;;
    prune)
      case "$PRUNE" in
        report)
          echo "⚠ stale   '${name}' (${itemId}) — gone; reporting only"
          summary_lines+=("| ⚠️ stale (kept) | \`${name}\` | \`${itemId}\` |")
          ;;
        archive)
          echo "🗄 archive '${name}' (${itemId}) — gone"
          if run_mut 'mutation($id:String!){ issueLabelArchive(id:$id){ success } }' \
               "$(jq -n --arg id "$id" '{id:$id}')"; then
            pruned=$((pruned+1)); summary_lines+=("| 🗄️ archived | \`${name}\` | \`${itemId}\` |")
          else failures=$((failures+1)); fi
          ;;
        delete)
          echo "🗑 delete  '${name}' (${itemId}) — gone (permanent)"
          if run_mut 'mutation($id:String!){ issueLabelDelete(id:$id){ success } }' \
               "$(jq -n --arg id "$id" '{id:$id}')"; then
            pruned=$((pruned+1)); summary_lines+=("| 🗑️ deleted | \`${name}\` | \`${itemId}\` |")
          else failures=$((failures+1)); fi
          ;;
      esac
      ;;
    conflict)
      other="$(jq -r '.otherItemId' <<<"$item")"
      echo "::warning::Label name '${name}' is already managed by ${other}; ${itemId} wants the same name. Skipping to avoid a duplicate."
      conflicts=$((conflicts+1)); summary_lines+=("| ❌ conflict | \`${name}\` | \`${itemId}\` vs \`${other}\` |")
      ;;
  esac
done < <(jq -c '.[]' <<<"$plan_json")

# --- 7. Report ---------------------------------------------------------------
echo ""
echo "Done. created=${created} renamed=${renamed} adopted=${adopted} pruned=${pruned} conflicts=${conflicts} failures=${failures}"

if [ -n "${GITHUB_OUTPUT:-}" ]; then
  {
    echo "created=${created}"
    echo "renamed=${renamed}"
    echo "adopted=${adopted}"
    echo "pruned=${pruned}"
  } >> "$GITHUB_OUTPUT"
fi

if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  {
    echo "## Linear \`${GROUP_NAME}\` label sync (source: \`${SOURCE}\`)"
    echo ""
    echo "Owner **${OWNER}**${OWNER_TYPE:+ (${OWNER_TYPE})} • ${ITEM_COUNT} items • prune=\`${PRUNE}\`${DRY_RUN:+ • dry-run=\`${DRY_RUN}\`}"
    echo ""
    echo "created **${created}** · renamed **${renamed}** · adopted **${adopted}** · pruned **${pruned}** · conflicts **${conflicts}**"
    if [ "${#summary_lines[@]}" -gt 0 ]; then
      echo ""
      echo "| action | label | key |"
      echo "|---|---|---|"
      printf '%s\n' "${summary_lines[@]}"
    else
      echo ""
      echo "_No changes — the group was already in sync._"
    fi
  } >> "$GITHUB_STEP_SUMMARY"
fi

# Loud red if any individual mutation failed, so a broken run is visible.
[ "$failures" -eq 0 ]
