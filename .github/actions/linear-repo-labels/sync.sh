#!/usr/bin/env bash
# Sync a Linear label group with a GitHub org/user's repositories.
#
# Renames are tracked via each repo's IMMUTABLE numeric GitHub ID, which is
# stashed in the label's description as "gh-repo-id:<id>". Reconciliation keys
# on that ID, never on the name, so when a repo is renamed we UPDATE the
# existing label (preserving every issue tagged with it) instead of creating a
# fresh one and orphaning the old.
#
# Label description format (single line, human-readable + machine tag):
#   Auto-managed by linear-repo-labels • gh-repo-id:123456
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LINEAR_API="https://api.linear.app/graphql"
TAG_PREFIX="Auto-managed by linear-repo-labels"

OWNER="${INPUT_OWNER:?owner is required}"
GROUP_NAME="${INPUT_GROUP_NAME:-repo}"
TEAM="${INPUT_TEAM:-}"
LOWER="${INPUT_LOWERCASE:-true}"
INC_FORKS="${INPUT_INCLUDE_FORKS:-true}"
INC_ARCH="${INPUT_INCLUDE_ARCHIVED:-false}"
PRUNE="${INPUT_PRUNE:-report}"
DRY_RUN="${INPUT_DRY_RUN:-false}"

: "${LINEAR_API_KEY:?linear-api-key is required}"
: "${GH_TOKEN:?github-token is required}"

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

# --- 1. Enumerate the owner's repositories -----------------------------------
echo "Resolving account type for '${OWNER}'…"
OWNER_TYPE="$(gh api "/users/${OWNER}" --jq '.type')"
if [ "$OWNER_TYPE" = "Organization" ]; then
  REPO_PATH="/orgs/${OWNER}/repos"; LIST_TYPE="all"
else
  REPO_PATH="/users/${OWNER}/repos"; LIST_TYPE="owner"
fi
echo "  ${OWNER} is a ${OWNER_TYPE}; listing via ${REPO_PATH}?type=${LIST_TYPE}"

repos_ndjson="$(gh api --paginate "${REPO_PATH}?per_page=100&type=${LIST_TYPE}" \
  --jq '.[] | {id, name, fork, archived}')"

repos_json="$(jq -s \
  --argjson lower "$LOWER" \
  --argjson incforks "$INC_FORKS" \
  --argjson incarch "$INC_ARCH" '
  [ .[]
    | select($incforks or (.fork | not))
    | select($incarch or (.archived | not))
    | {id, name: (if $lower then (.name | ascii_downcase) else .name end)} ]' \
  <<<"$repos_ndjson")"

REPO_COUNT="$(jq 'length' <<<"$repos_json")"
echo "  ${REPO_COUNT} repositories after filters (forks=${INC_FORKS}, archived=${INC_ARCH})."
if [ "$REPO_COUNT" -eq 0 ]; then
  echo "::warning::No repositories found for '${OWNER}'. Check the github-token scope. Skipping to avoid pruning the whole group by mistake."
  exit 0
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

# Annotate each child with the managed repo ID parsed from its description.
children_json="$(jq '[ .[] | . + {
    managedId: ((.description // "") as $d
      | if ($d | test("gh-repo-id:[0-9]+"))
        then ($d | capture("gh-repo-id:(?<i>[0-9]+)").i)
        else null end) } ]' <<<"$children_json")"

echo "Group currently has $(jq 'length' <<<"$children_json") child label(s)."

# --- 5. Compute the reconciliation plan (declarative, in jq) -----------------
# The plan program lives in plan.jq so the fixture test exercises the exact
# same logic that runs in production (see test/plan_test.sh).
plan_json="$(jq -n \
  --argjson repos "$repos_json" \
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
  repoId="$(jq -r '.repoId // ""' <<<"$item")"
  desc="${TAG_PREFIX} • gh-repo-id:${repoId}"

  case "$op" in
    create)
      echo "＋ create  '${name}' (gh-repo-id:${repoId})"
      input="$(jq -n --arg name "$name" --arg pid "$GROUP_ID" --arg tid "$TEAM_ID" --arg d "$desc" \
        '{name:$name, parentId:$pid, description:$d} + (if $tid == "" then {} else {teamId:$tid} end)')"
      if run_mut 'mutation($i:IssueLabelCreateInput!){ issueLabelCreate(input:$i){ success } }' \
           "$(jq -n --argjson i "$input" '{i:$i}')"; then
        created=$((created+1)); summary_lines+=("| ➕ created | \`${name}\` | ${repoId} |")
      else failures=$((failures+1)); fi
      ;;
    rename)
      from="$(jq -r '.from' <<<"$item")"
      echo "✎ rename  '${from}' → '${name}' (gh-repo-id:${repoId}, preserves issues)"
      input="$(jq -n --arg name "$name" '{name:$name}')"
      if run_mut 'mutation($id:String!,$i:IssueLabelUpdateInput!){ issueLabelUpdate(id:$id, input:$i){ success } }' \
           "$(jq -n --arg id "$id" --argjson i "$input" '{id:$id, i:$i}')"; then
        renamed=$((renamed+1)); summary_lines+=("| ✏️ renamed | \`${from}\` → \`${name}\` | ${repoId} |")
      else failures=$((failures+1)); fi
      ;;
    adopt)
      echo "⇲ adopt   existing '${name}' (stamp gh-repo-id:${repoId})"
      input="$(jq -n --arg d "$desc" '{description:$d}')"
      if run_mut 'mutation($id:String!,$i:IssueLabelUpdateInput!){ issueLabelUpdate(id:$id, input:$i){ success } }' \
           "$(jq -n --arg id "$id" --argjson i "$input" '{id:$id, i:$i}')"; then
        adopted=$((adopted+1)); summary_lines+=("| 🔗 adopted | \`${name}\` | ${repoId} |")
      else failures=$((failures+1)); fi
      ;;
    prune)
      case "$PRUNE" in
        report)
          echo "⚠ stale   '${name}' (gh-repo-id:${repoId}) — repo gone; reporting only"
          summary_lines+=("| ⚠️ stale (kept) | \`${name}\` | ${repoId} |")
          ;;
        archive)
          echo "🗄 archive '${name}' (gh-repo-id:${repoId}) — repo gone"
          if run_mut 'mutation($id:String!){ issueLabelArchive(id:$id){ success } }' \
               "$(jq -n --arg id "$id" '{id:$id}')"; then
            pruned=$((pruned+1)); summary_lines+=("| 🗄️ archived | \`${name}\` | ${repoId} |")
          else failures=$((failures+1)); fi
          ;;
        delete)
          echo "🗑 delete  '${name}' (gh-repo-id:${repoId}) — repo gone (permanent)"
          if run_mut 'mutation($id:String!){ issueLabelDelete(id:$id){ success } }' \
               "$(jq -n --arg id "$id" '{id:$id}')"; then
            pruned=$((pruned+1)); summary_lines+=("| 🗑️ deleted | \`${name}\` | ${repoId} |")
          else failures=$((failures+1)); fi
          ;;
      esac
      ;;
    conflict)
      other="$(jq -r '.otherRepoId' <<<"$item")"
      echo "::warning::Label name '${name}' is already managed by repo id ${other}; repo id ${repoId} wants the same name. Skipping to avoid a duplicate. (Two repos map to the same lowercased name?)"
      conflicts=$((conflicts+1)); summary_lines+=("| ❌ conflict | \`${name}\` | ${repoId} vs ${other} |")
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
    echo "## Linear \`${GROUP_NAME}\` label sync"
    echo ""
    echo "Owner **${OWNER}** (${OWNER_TYPE}) • ${REPO_COUNT} repos • prune=\`${PRUNE}\`${DRY_RUN:+ • dry-run=\`${DRY_RUN}\`}"
    echo ""
    echo "created **${created}** · renamed **${renamed}** · adopted **${adopted}** · pruned **${pruned}** · conflicts **${conflicts}**"
    if [ "${#summary_lines[@]}" -gt 0 ]; then
      echo ""
      echo "| action | label | repo id |"
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
