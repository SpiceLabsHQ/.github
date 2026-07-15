# Reconciliation plan for ONE repo's settings (DEV-519, fixed in DEV-631).
#
# The single source of truth for what the reconciler changes: which policy groups
# are in force for the repo, which fields drifted, and the exact PATCH body. Kept
# as its own program — rather than inline in the shell — so that
# scripts/test/org-repo-settings-plan_test.sh exercises the code production runs
# instead of a retyped copy that can silently drift from it.
#
# Inputs:
#   $cur     live repo settings (GET /repos/{owner}/{repo})
#   $groups  desired policies: {group: {field: desired_value}}
#   $skips   newline-separated group names to skip (from the exception property)
#
# Output:
#   .active_fields  number of desired fields in force (0 => every group excepted)
#   .drifted        {field: desired} for fields whose live value differs. This is
#                   the human-facing report: only these actually change.
#   .patch          the PATCH body: EVERY field of every group that contains any
#                   drift — not just the drifted fields. Empty => make no call.
#
# WHY .patch IS WHOLE-GROUP: GitHub validates some fields as a set, against the
# request's defaults rather than the repo's stored values, so a minimal diff can
# be rejected even when the resulting state would be legal. Sending only
# {squash_merge_commit_message: PR_BODY} to a repo whose stored
# squash_merge_commit_title is PR_TITLE fails with 422
# invalid_squash_commit_setting_combo, because the omitted title defaults to
# COMMIT_OR_PR_TITLE, which cannot pair with PR_BODY. Sending the group whole
# keeps co-validated fields in the request. Re-sending fields already at their
# desired value is a no-op, so this stays idempotent.

($skips | split("\n") | map(select(length > 0))) as $skip
| ($groups | with_entries(select(.key as $g | ($skip | index($g)) | not))) as $active
| {
    active_fields: ([ $active[] | to_entries[] ] | length),

    drifted: ([ $active[] | to_entries[] | select($cur[.key] != .value) ] | from_entries),

    patch: ([ $active[]
              | select(any(to_entries[]; $cur[.key] != .value))
              | to_entries[] ] | from_entries)
  }
