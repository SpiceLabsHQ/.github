# Pepper review audit: the record-assembly half (DEV-653).
#
# Pure function from "everything the runner could observe" to the v1 audit
# record. No network, no filesystem — so scripts/test/pepper-audit-record_test.sh
# can pin every field against fixtures, the same split as
# pepper-bot-outcome-collapse-decide.jq and pepper-stranded-sweep-decide.jq.
#
# EVERY INPUT ARRIVES AS A STRING (`--arg`), never `--argjson`. A workflow step
# output that did not resolve is the empty string, which is not valid JSON, so
# `--argjson` would abort the whole program on exactly the degraded runs the
# audit most needs to record. Numbers and booleans are parsed here instead,
# where a malformed value becomes null rather than a crash.
#
# Inputs:
#   $exec_obs   — pepper-audit-collect.jq output over the execution file, or "null"
#   $tx_obs     — pepper-audit-collect.jq output over the session transcript, or "null"
#   $ts         — ISO-8601 UTC timestamp for the record
#   $repo $pr_number $run_id $run_attempt $event $head_sha $pr_author $flavor
#   $workflow_sha $standards_sha256
#   $cookbook_ref — the Eng-Cookbook release the prompt carried (DEV-1119); "" when none
#   $model $effort $max_turns $review_timeout_minutes   — as PASSED by the workflow
#   $arm       — the model/effort arm the workflow picked (DEV-2455); "" when unknown
#   $labels     — the PR's labels, comma-joined; "" when unreadable
#   $no_verdict — "true" when the DEV-235 no-verdict escalation fired
#   $collapse_fired — "true" when the DEV-674 collapse rewrote the verdict
#   $pepper_outcome — `steps.pepper.outcome`: success|failure|cancelled|skipped
#   $review_filed   — "true" when the escalation step found a Pepper review on
#                     the head SHA despite `pepper-cooking` still being on
#
# Output: the schema-v1 record, exactly the field set and field names in
# DEV-653 (plus the additive, nullable fields added since — `model_executed`,
# DEV-881; `cookbook_ref`, DEV-1119; `no_verdict_reason` and
# `refusal_category`, DEV-1335; `arm`, DEV-2455). Callers depend on the field names:
# renaming or removing one is a schema bump; adding a nullable one is not
# (docs/pepper-audit.md, "Schema changes").

def as_text: if type == "string" and length > 0 then . else null end;

# Strict numeric parse. Anything that is not unambiguously a number becomes
# null: an audit that guesses is worse than an audit with a hole in it.
def to_num:
  if type == "number" then .
  elif type == "string" and (test("^-?[0-9]+([.][0-9]+)?$")) then tonumber
  else null end;

def to_bool: . == "true";

def obs($raw): ($raw | fromjson? // null) | if type == "object" then . else null end;

(obs($exec_obs)) as $x |
(obs($tx_obs)) as $t |

# Numbers: execution file first (the SDK's own accounting), transcript second
# (our sum over per-message usage), null last. Never a computed price — if no
# source reports cost, `cost_usd` is null and the token split is the ground
# truth an analyst derives from (docs/pepper-audit.md).
(($x.result // null)) as $xr |
(($t.result // null)) as $tr |

# Config as EXECUTED beats config as passed (DEV-881). Both files carry it, so
# either will do; the execution file is tried first only to keep one preference
# order for the whole record.
#
# `model` is the exception, and it SPLITS rather than prefers: the as-passed
# value is the application-inference-profile ARN — the key IAM scoping and Cost
# Explorer attribution hang off (DEV-245/DEV-875) — while the stream reports the
# resolved model id (e.g. `us.anthropic.claude-sonnet-5`), a different
# vocabulary. Collapsing them into one field would destroy the cost join on
# every run where the stream reported. So `model` stays as passed and the
# as-executed value gets its own `model_executed` field, which keeps the DEV-881
# divergence not just visible but queryable: a row whose `model_executed` names
# something its `model` profile does not wrap is the CLI ignoring the workflow.
# `effort` does collapse to one as-executed-preferred field, because both
# sources speak the same vocabulary and as-executed is strictly the better
# observation.
(($x.cli_version // $t.cli_version) | as_text) as $cli_version |
(($x.effort // $t.effort) | as_text // ($effort | as_text)) as $effort_final |
(($x.model // $t.model) | as_text) as $model_executed |

# Outcome. `no_verdict` is a FAILURE, not a verdict, so it is decided by the
# escalation step's own output rather than re-derived from the label it just
# applied — otherwise it would be indistinguishable from an ordinary escalation.
# Below that, the label precedence is "most blocking wins": a jammed collapse
# leaves BOTH `pepper-changes-requested` and `pepper-needs-review` on the PR
# (see pepper-bot-outcome-collapse.sh), and changes-requested is the state that
# still blocks the merge.
(($labels | split(",") | map(select(length > 0)))) as $lbl |
(if ($no_verdict | to_bool) then "no_verdict"
 elif ($lbl | index("pepper-changes-requested")) then "changes_requested"
 elif ($lbl | index("pepper-needs-review")) then "escalated"
 elif ($lbl | index("pepper-approved")) then "approved"
 else null end) as $outcome |

# Why a no_verdict run ended (DEV-1335). `no_verdict` alone lumps a model that
# under-thought with a Bedrock error and a prompt that never built — opposite
# responses, one of them a false revert of a working change (DEV-884). First
# match wins, ordered so the most specific evidence decides:
#   prompt_build_failure — Run Pepper was skipped: a setup step before it
#                          (checkout, prompt build, model/tools/MCP, AWS creds)
#                          failed, so the model never ran.
#   verdict_unparseable  — Pepper filed a review on this head SHA but never
#                          swapped `pepper-cooking`, so the workflow could not
#                          read it as a verdict (the prompt's "filed, then ran
#                          out before the label swap" case).
#   refused              — the model stopped with `stop_reason: "refusal"`;
#                          `refusal_category` carries `stop_details.category`.
#   turn_cap             — turns_used reached max_turns, or the result says so.
#                          Checked before api_error: the CLI can emit a
#                          synthetic message when it stops on the cap.
#   api_error            — a harness-made error message (`<synthetic>` model or
#                          `isApiErrorMessage`, e.g. a Bedrock
#                          ValidationException, DEV-881), or an errored result
#                          other than the turn cap.
#   timeout              — Run Pepper failed or was cancelled with no result
#                          record, and the transcript spans >= 90% of the
#                          wall-clock budget (the kill leaves no other clock;
#                          the slack covers the last in-flight model call).
#   cancelled            — Run Pepper was cancelled for any other reason.
#   verdict_not_filed    — the run finished cleanly, under both caps, and the
#                          model simply never filed a verdict.
#   unknown              — none of the above could be established.
(($max_turns | to_num)) as $max_turns_n |
(($review_timeout_minutes | to_num)) as $timeout_n |
(($xr.turns_used) // ($tr.turns_used) // null) as $turns_used |
($xr // $tr) as $res |
(($x.refusal) // ($t.refusal)) as $refusal |
(($x.span_ms) // ($t.span_ms) // null) as $span_ms |
(if $outcome != "no_verdict" then null
 elif $pepper_outcome == "skipped" then "prompt_build_failure"
 elif ($review_filed | to_bool) then "verdict_unparseable"
 elif $refusal != null then "refused"
 elif ($res.subtype == "error_max_turns")
      or ($turns_used != null and $max_turns_n != null and $turns_used >= $max_turns_n)
   then "turn_cap"
 elif ($x.api_error == true) or ($t.api_error == true)
      or ($res != null and $res.is_error == true and $res.subtype != "error_max_turns")
   then "api_error"
 elif ($pepper_outcome == "failure" or $pepper_outcome == "cancelled")
      and $xr == null and $span_ms != null and $timeout_n != null
      and $span_ms >= ($timeout_n * 60000 * 0.9)
   then "timeout"
 elif $pepper_outcome == "cancelled" then "cancelled"
 elif $res != null and $res.is_error == false then "verdict_not_filed"
 else "unknown" end) as $no_verdict_reason |

{
  schema_version: 1,
  ts: ($ts | as_text),
  repo: ($repo | as_text),
  pr_number: ($pr_number | to_num),
  run_id: ($run_id | to_num),
  run_attempt: ($run_attempt | to_num),
  event: ($event | as_text),
  head_sha: ($head_sha | as_text),
  pr_author: ($pr_author | as_text),
  flavor: ($flavor | as_text),
  workflow_sha: ($workflow_sha | as_text),
  standards_sha256: ($standards_sha256 | as_text),
  cookbook_ref: ($cookbook_ref | as_text),
  arm: ($arm | as_text),
  model: ($model | as_text),
  model_executed: $model_executed,
  effort: $effort_final,
  max_turns: ($max_turns | to_num),
  review_timeout_minutes: ($review_timeout_minutes | to_num),
  cli_version: $cli_version,
  outcome: $outcome,
  no_verdict_reason: $no_verdict_reason,
  refusal_category: (if $no_verdict_reason == "refused" then $refusal.category else null end),
  collapse_fired: ($collapse_fired | to_bool),
  turns_used: $turns_used,
  duration_ms: (($xr.duration_ms) // ($tr.duration_ms) // null),
  cost_usd: (($xr.cost_usd) // ($tr.cost_usd) // ($x.summed_cost_usd) // ($t.summed_cost_usd) // null),
  # A result record's `usage` is the run total; the per-message sum is the
  # fallback. Always an object with all four keys so a Logs Insights query can
  # reference `tokens.output` without branching on record shape.
  tokens: (($xr.tokens) // ($x.summed_tokens) // ($tr.tokens) // ($t.summed_tokens)
           // {input: null, output: null, cache_read: null, cache_creation: null})
}
