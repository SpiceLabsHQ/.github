# Reconciliation plan for the Linear repo-label sync.
#
# Inputs (via --argjson):
#   $repos    : [ {id, name} ]           GitHub repos (name already normalized)
#   $children : [ {id, name, managedId} ] current labels in the group,
#                                          managedId = repo ID parsed from the
#                                          label description (null if unmanaged)
#
# Output: an array of ops, each one of:
#   {op:"rename",   id, name, from, repoId}  repo renamed -> update label in place
#   {op:"adopt",    id, name, repoId}        stamp an existing unmanaged label
#   {op:"conflict", name, otherRepoId, repoId} target name already owned by another repo
#   {op:"create",   name, repoId}            new repo -> new label
#   {op:"prune",    id, name, repoId}        managed label whose repo is gone
# (noop entries are dropped.)
#
# Reconciliation keys on the immutable GitHub repo ID, never the name, so a repo
# rename becomes an in-place label update and no issue associations are lost.
($children | map(select(.managedId != null)) | INDEX(.managedId)) as $byId
| ($children | INDEX(.name)) as $byName
| ($repos | map(.id | tostring)) as $repoIds
| ( [ $repos[]
      | (.id | tostring) as $rid
      | .name as $tname
      | if $byId[$rid] then
          (if $byId[$rid].name != $tname
           then {op:"rename", id:$byId[$rid].id, name:$tname, from:$byId[$rid].name, repoId:$rid}
           else {op:"noop"} end)
        elif ($byName[$tname] != null and $byName[$tname].managedId == null) then
          {op:"adopt", id:$byName[$tname].id, name:$tname, repoId:$rid}
        elif ($byName[$tname] != null and $byName[$tname].managedId != $rid) then
          {op:"conflict", name:$tname, otherRepoId:$byName[$tname].managedId, repoId:$rid}
        else
          {op:"create", name:$tname, repoId:$rid}
        end
    ] ) as $repoPlan
| ( [ $children[]
      | select(.managedId != null)
      | select( (.managedId | IN($repoIds[])) | not )
      | {op:"prune", id:.id, name:.name, repoId:.managedId} ] ) as $prunePlan
| ($repoPlan + $prunePlan) | map(select(.op != "noop"))
