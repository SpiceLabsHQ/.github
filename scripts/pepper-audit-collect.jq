# Pepper review audit: the telemetry-reading half (DEV-653).
#
# Reduces ONE stream of SDK/CLI records into the handful of numbers the audit
# record needs. Deliberately shape-agnostic so the SAME program reads both
# sources the runner offers, which carry the same record vocabulary:
#
#   1. `steps.pepper.outputs.execution_file` — claude-code-action's copy of the
#      SDK stream. Preferred, because its final `result` record is the SDK's own
#      accounting (`total_cost_usd`, `num_turns`, `duration_ms`, `usage`) rather
#      than a sum we computed.
#   2. The CLI session transcript JSONL on the runner
#      (`~/.claude/projects/<cwd-slug>/<session>.jsonl`). Fallback for the
#      numbers, and the verified source for the as-executed config fields.
#
# Accepts either a JSON array or a stream/JSONL of objects — the execution file
# is the former today and the transcript is always the latter, and neither
# format is contractual, so the program tolerates both rather than betting on
# one. Run as: jq -nR -f pepper-audit-collect.jq <file>
#
# Read RAW (`-R`), then parsed here: a timeout kill can leave a torn last JSONL
# line, and parsing the file as JSON would reject the whole thing and lose the
# very run the audit most needs (DEV-1335). The whole text is tried as one
# value first (the execution file's array); failing that, each line is parsed
# on its own and a malformed line is skipped.
#
# WHY as-executed CONFIG IS READ HERE AT ALL. Every `assistant` record stamps a
# top-level `version` and `effort` and a `message.model` — what the CLI actually
# sent, not what the workflow asked for. DEV-881 (a CLI silently sending a
# removed field) and DEV-875 (a preflight enumerating models nobody asked for)
# are both failure classes where as-passed config reads clean while the wire
# says otherwise. The workflow's own step outputs remain the fallback.
#
# Output (every field nullable — a missing source is a null, never an error):
#   {
#     "result":          {cost_usd, turns_used, duration_ms, tokens,
#                         subtype, is_error} | null,
#     "summed_tokens":   {input, output, cache_read, cache_creation} | null,
#     "summed_cost_usd": <number> | null,
#     "assistant_count": <number>,
#     "cli_version":     <string> | null,
#     "effort":          <string> | null,
#     "model":           <string> | null,
#     "refusal":         {category: <string> | null} | null,
#     "api_error":       <boolean>,
#     "span_ms":         <number> | null
#   }
#
# The last three feed `no_verdict_reason` (DEV-1335). `refusal` is set when any
# record stops with `stop_reason: "refusal"` (the model's safety classifier
# declined); `category` is its `stop_details.category`. `api_error` is set by a
# harness-made error message — `message.model == "<synthetic>"` or
# `isApiErrorMessage: true`, which is how the CLI surfaces a Bedrock
# ValidationException (DEV-881) — never by the model's own text, which may
# quote an error while reviewing code. `span_ms` is first-to-last `timestamp`
# across records (the transcript carries them; the execution file may not): the
# only clock that survives a timeout kill.

# Numbers only. A string "12" from a malformed record is NOT coerced: the audit
# would rather record a null than a number it invented.
def as_number: if type == "number" then . else null end;

# Non-empty strings only. `//` treats "" as present (only null/false are falsy
# in jq), so an empty `version` would otherwise beat a real one from an earlier
# record.
def as_text: if type == "string" and length > 0 then . else null end;

# Object-safe field read. `.a.b` errors when `.a` is a non-object (a truncated
# or unexpected record shape), which would abort the whole reduce.
def field($k): if type == "object" then .[$k] else null end;

# ISO-8601 -> epoch ms, or null. `fromdateiso8601` rejects fractional seconds,
# so they are cut first; a malformed stamp is a null, never an abort.
def ts_ms:
  if type == "string" then
    (try (sub("[.][0-9]+"; "") | fromdateiso8601 * 1000) catch null)
  else null end;

# `stop_reason: "refusal"` on the record itself or on its API message.
def refusal_of:
  if ((field("stop_reason")) == "refusal") or ((field("message") | field("stop_reason")) == "refusal") then
    {category: (((field("stop_details") | field("category"))
                 // (field("message") | field("stop_details") | field("category"))) | as_text)}
  else null end;

# The four-way token split the schema requires. Undifferentiated totals hide
# output tokens, which are ~90% of Bedrock cost (DEV-653).
#
# `cache_creation_input_tokens` is the scalar total; newer CLIs also emit a
# `cache_creation` object carrying the 5m/1h ephemeral split. Prefer the scalar,
# fall back to summing the split, so neither shape drops the field.
def tokens_of:
  if type != "object" then null
  else
    {
      input:      (.input_tokens | as_number),
      output:     (.output_tokens | as_number),
      cache_read: (.cache_read_input_tokens | as_number),
      cache_creation:
        ((.cache_creation_input_tokens | as_number)
         // (.cache_creation
             | if type == "object" then ([.[] | as_number | select(. != null)] | add)
               else null end))
    }
  end;

# Pairwise sum that treats "no observation yet" and "no value in this record"
# distinctly from zero, so a run with no readable usage stays null rather than
# reporting a confident 0.
def add_tokens($a; $b):
  if $a == null then $b
  elif $b == null then $a
  else
    {
      input:          (($a.input // 0) + ($b.input // 0)),
      output:         (($a.output // 0) + ($b.output // 0)),
      cache_read:     (($a.cache_read // 0) + ($b.cache_read // 0)),
      cache_creation: (($a.cache_creation // 0) + ($b.cache_creation // 0))
    }
  end;

def records:
  ([inputs] | join("\n")) as $raw
  | ($raw | try fromjson catch null) as $whole
  | if $whole != null then ($whole | if type == "array" then .[] else . end)
    else ($raw | split("\n")[] | select(length > 0) | (try fromjson catch empty))
    end;

reduce records as $r
  ({result: null, summed_tokens: null, summed_cost_usd: null,
    assistant_count: 0, cli_version: null, effort: null, model: null,
    refusal: null, api_error: false, first_ms: null, last_ms: null};

   if ($r | type) != "object" then .
   else
   # No-verdict signals (DEV-1335), read off every record before the per-type
   # branch below, so a refusal or a synthetic error is seen whatever its type.
   (($r | field("timestamp") | ts_ms) as $ms
    | if $ms == null then .
      else .first_ms = ([.first_ms, $ms] | map(select(. != null)) | min)
         | .last_ms = ([.last_ms, $ms] | max)
      end)
   | .refusal = (($r | refusal_of) // .refusal)
   | (if ($r | field("message") | field("model")) == "<synthetic>"
         or ($r | field("isApiErrorMessage")) == true
      then .api_error = true else . end)
   |

   # The final accounting record. Recognised by `type` OR by carrying the
   # accounting fields, because the stream's `type` vocabulary is the SDK's and
   # not something this repo controls. LAST one wins: a resumed session can emit
   # more than one and the last is the run's total.
   if ($r | field("type")) == "result"
        or ($r | field("num_turns") | as_number) != null
        or ($r | field("total_cost_usd") | as_number) != null then
     .result = {
       cost_usd:    ($r | field("total_cost_usd") | as_number),
       turns_used:  ($r | field("num_turns") | as_number),
       duration_ms: ($r | field("duration_ms") | as_number),
       tokens:      ($r | field("usage") | tokens_of),
       subtype:     ($r | field("subtype") | as_text),
       is_error:    ($r | field("is_error") | if type == "boolean" then . else null end)
     }

   elif ($r | field("type")) == "assistant" then
     .assistant_count += 1
     # Last non-empty value wins. Config cannot change mid-run today, so "last"
     # and "first" agree; last is chosen so that if it ever DOES change, the
     # record reflects what the run finished as.
     | .cli_version = (($r | field("version") | as_text) // .cli_version)
     | .effort      = (($r | field("effort") | as_text) // .effort)
     | .model       = (($r | field("message") | field("model") | as_text) // .model)
     | .summed_tokens =
         add_tokens(.summed_tokens; ($r | field("message") | field("usage") | tokens_of))
     # Per-line `costUSD` is null on a subscription session (verified, CLI
     # 2.1.223) and unverified on Bedrock. Sum it only when a record actually
     # carries a number — never synthesise a price.
     | .summed_cost_usd =
         (($r | field("costUSD") | as_number) as $c
          | if $c == null then .summed_cost_usd else ((.summed_cost_usd // 0) + $c) end)

   else . end
   end)
| .span_ms = (if .first_ms != null and .last_ms != null then .last_ms - .first_ms else null end)
| del(.first_ms, .last_ms)
