# Reconciliation plan for the Linear GitHub-label sync.
#
# Source-agnostic: an "item" is whatever the configured source enumerates (a
# repository, a reusable workflow, …). The only contract is that each item
# carries an OPAQUE, STABLE key — this program never interprets it, so adding a
# source needs no change here.
#
# Inputs (via --argjson):
#   $items    : [ {id, name} ]            id = the stable key, name = label name
#   $children : [ {id, name, managedId} ] current labels in the group,
#                                          managedId = key parsed from the
#                                          label description (null if unmanaged)
#
# Output: an array of ops, each one of:
#   {op:"rename",   id, name, from, itemId}    item renamed -> update in place
#   {op:"adopt",    id, name, itemId}          stamp an existing unmanaged label
#   {op:"conflict", name, otherItemId, itemId} target name already owned
#   {op:"create",   name, itemId}              new item -> new label
#   {op:"prune",    id, name, itemId}          managed label whose item is gone
# (noop entries are dropped.)
#
# Reconciliation keys on the stable item key, never the name, so a rename becomes
# an in-place label update and no issue associations are lost.
($children | map(select(.managedId != null)) | INDEX(.managedId)) as $byId
| ($children | INDEX(.name)) as $byName
| ($items | map(.id | tostring)) as $itemIds
| ( [ $items[]
      | (.id | tostring) as $iid
      | .name as $tname
      | if $byId[$iid] then
          (if $byId[$iid].name != $tname
           then {op:"rename", id:$byId[$iid].id, name:$tname, from:$byId[$iid].name, itemId:$iid}
           else {op:"noop"} end)
        elif ($byName[$tname] != null and $byName[$tname].managedId == null) then
          {op:"adopt", id:$byName[$tname].id, name:$tname, itemId:$iid}
        elif ($byName[$tname] != null and $byName[$tname].managedId != $iid) then
          {op:"conflict", name:$tname, otherItemId:$byName[$tname].managedId, itemId:$iid}
        else
          {op:"create", name:$tname, itemId:$iid}
        end
    ] ) as $itemPlan
| ( [ $children[]
      | select(.managedId != null)
      | select( (.managedId | IN($itemIds[])) | not )
      | {op:"prune", id:.id, name:.name, itemId:.managedId} ] ) as $prunePlan
| ($itemPlan + $prunePlan) | map(select(.op != "noop"))
