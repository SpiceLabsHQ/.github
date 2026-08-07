# Pepper review audit log

Every Pepper PR review emits one structured JSON record describing the
configuration it ran under, the outcome it reached, and what it cost. This
document is the query pack: what the data is, where it lives, and the working
CloudWatch Logs Insights queries for the questions it exists to answer.

The primary consumer is an agent working in this repo. Everything below runs
with the read-only SSO profile (`spice-ro`) and needs no new IAM.

| | |
|---|---|
| Log group | `/pepper/pr-review/audit` |
| Account / region | `618640261060` / `us-west-2` |
| Profile | `spice-ro` (read) |
| Retention | 731 days |
| Streams | one per run attempt, named `<run_id>-<run_attempt>` |
| Written by | `scripts/pepper-audit-record.sh`, from the review job |
| Infrastructure | [`infrastructure/pepper-audit.cfn.yml`](../infrastructure/pepper-audit.cfn.yml) |

## Why this exists

To tell "the model changed" apart from "we changed a setting." Reasoning
`effort` is the single highest-leverage behavior and cost knob on the review and
it is invisible to every AWS-side source — Bedrock metrics are dimensioned by
model only, CloudTrail carries no request body, and model-invocation logging
would persist full prompts and responses to capture one config field. Neither is
`claude-code-action@v1` a version: it installs claude-cli at runtime with no pin,
and four CLI versions shipped in 25 days while the action tag sat still. So the
record captures configuration alongside outcome and cost, and a change in any of
them is attributable.

## Reading it

Records are ordinary JSON log events, so `filter` and `stats` address fields by
name and nested fields by dotted path (`tokens.output`).

Insights is asynchronous — start a query, poll for results:

```sh
QID=$(aws logs start-query \
  --profile spice-ro --region us-west-2 \
  --log-group-name /pepper/pr-review/audit \
  --start-time "$(date -u -v-7d +%s 2>/dev/null || date -u -d '7 days ago' +%s)" \
  --end-time "$(date -u +%s)" \
  --query-string 'fields @timestamp, repo, outcome, cost_usd | sort @timestamp desc | limit 20' \
  --query queryId --output text)

# Poll until .status is "Complete".
aws logs get-query-results --query-id "$QID" \
  --profile spice-ro --region us-west-2
```

Every query below is a `--query-string` value; the start/end/poll scaffolding is
the same each time. `-v-7d` is BSD `date` (macOS) and `-d '7 days ago'` is GNU
`date` (Linux) — the fallback above covers both.

> These queries are written against the schema below. They have not yet been run
> against live records — there are none until the first review after the stack
> and the IAM statement are deployed. Confirm each one on that first day's data
> and correct this file in the same pass; a query that silently returns nothing
> because a field name drifted looks exactly like a quiet week.

For a single run, skip Insights entirely and read the stream directly:

```sh
aws logs get-log-events \
  --profile spice-ro --region us-west-2 \
  --log-group-name /pepper/pr-review/audit \
  --log-stream-name "<run_id>-<run_attempt>" \
  --query 'events[].message' --output text | jq .
```

The same record is rendered into the review run's GitHub job summary, so any
individual run is readable without AWS access at all.

## Record schema (v1)

```json
{
  "schema_version": 1,
  "ts": "2026-08-06T21:14:03Z",
  "repo": "SpiceLabsHQ/example",
  "pr_number": 123,
  "run_id": 17123456789,
  "run_attempt": 1,
  "event": "pull_request",
  "head_sha": "abc1234...",
  "pr_author": "renovate[bot]",
  "flavor": "dependency",
  "workflow_sha": "3fd2805...",
  "standards_sha256": "9f86d081...",
  "model": "arn:aws:bedrock:us-west-2:618640261060:application-inference-profile/xda66yqkegz4",
  "model_executed": "us.anthropic.claude-sonnet-5",
  "effort": "high",
  "max_turns": 80,
  "review_timeout_minutes": 50,
  "cli_version": "2.1.223",
  "outcome": "approved",
  "collapse_fired": false,
  "turns_used": 34,
  "duration_ms": 723000,
  "cost_usd": 1.21,
  "tokens": {
    "input": 51234,
    "output": 98765,
    "cache_read": 401234,
    "cache_creation": 12345
  }
}
```

| Field | Notes |
|---|---|
| `flavor` | `default` or `dependency`. A different prompt template is a different behavior surface, so it is a config dimension, not a label. |
| `workflow_sha` | The commit of the reusable workflow this run used — which is also the commit its prompt templates and post-verdict scripts were fetched at. The prompt/template version. |
| `standards_sha256` | SHA-256 of the calling repo's `standards_path` file, or `null` when it has none. The per-repo prompt-customization identity: it separates "this repo's PRs are big" from "this repo's custom standards drive long reviews", and it changes the moment a repo edits its standards mid-series. |
| `model` | The application-inference-profile ARN the workflow resolved, **as passed** — the key AWS Cost Explorer attribution and IAM scoping hang off. Group cost by this. |
| `model_executed` | The resolved model id the CLI actually sent (e.g. `us.anthropic.claude-sonnet-5`), read off the SDK stream; `null` when no stream was readable. A row whose `model_executed` names something its `model` profile does not wrap is the CLI ignoring the workflow — the DEV-881 failure class. |
| `effort`, `cli_version` | Recorded **as executed** — read off what the CLI actually sent, with the workflow's own settings only as a fallback (both sources speak the same vocabulary, so as-executed is strictly the better observation). |
| `outcome` | `approved`, `changes_requested`, `escalated`, `no_verdict`, or `null`. **`escalated` and `no_verdict` are different things.** `escalated` is the review working — Pepper formed a judgment and deferred to a human, and a rise in its rate is how a too-low `effort` shows up. `no_verdict` is a failure: the run stopped (timeout, error, turn exhaustion) before any verdict existed. `null` means the outcome labels were unreadable at capture time. |
| `collapse_fired` | The bot-PR outcome collapse rewrote the verdict. `true` only on a confirmed, complete collapse. |
| `turns_used` / `max_turns` | Turns against the cap. `max_turns` is the graceful primary stop; `review_timeout_minutes` is the ungraceful backstop. |
| `cost_usd` | **May be `null`** — see below. |
| `tokens` | Split four ways deliberately. Output tokens are ~5x the unit price of input and roughly 90% of Bedrock spend, so an undifferentiated total hides the thing worth watching. Thinking tokens are output tokens, and `effort` is the direct lever on them. |

Any field can be `null`: the capture step must never fail a PR, so a missing
source becomes a hole rather than an error. Filter for the field you are grouping
by, or the nulls will form their own bucket.

### `cost_usd` may be null

The record never invents a price. `cost_usd` is populated only when a telemetry
source reports one; when it does not, the field is `null` and **the token counts
are the ground truth** — derive cost at query time from the split and current
Bedrock unit prices. Deriving in the query rather than baking a price table into
the capture step also means a price change re-prices history instead of splitting
the series at the commit that updated the table.

Sketch, with placeholder rates (substitute current Bedrock per-1K prices — cache
reads and cache writes are priced differently from fresh input):

```text
fields (tokens.input / 1000) * 0.003
     + (tokens.output / 1000) * 0.015
     + (tokens.cache_read / 1000) * 0.0003
     + (tokens.cache_creation / 1000) * 0.00375 as est_usd
```

## Standing queries

### Cost and tokens by `effort` x `cli_version`

The before/after for any tuning change. `cli_version` is in the grouping because
the CLI is unpinned: a change in behavior that lines up with a CLI bump rather
than with the setting you changed is the answer, and a query grouped on `effort`
alone would hide it.

```text
filter ispresent(effort) and ispresent(cli_version)
| stats count(*) as runs,
        avg(cost_usd) as avg_cost,
        sum(cost_usd) as total_cost,
        avg(tokens.output) as avg_out,
        avg(tokens.input) as avg_in,
        avg(tokens.cache_read) as avg_cache_read,
        avg(duration_ms) / 1000 as avg_secs
    by effort, cli_version
| sort effort, cli_version
```

Same cut over time, to see a transition rather than two averages:

```text
filter ispresent(effort)
| stats avg(cost_usd) as avg_cost, avg(tokens.output) as avg_out, count(*) as runs
    by bin(1d), effort, cli_version
```

### Cost per run by repo, cross-cut by `standards_sha256`

Who is driving spend, and whether it is the repo's PRs or the repo's custom
standards. Two rows for one repo with different `standards_sha256` values means
its standards changed mid-series — compare those rows before comparing the repo
against anyone else.

```text
stats count(*) as runs,
      sum(cost_usd) as total_cost,
      avg(cost_usd) as avg_cost,
      avg(tokens.output) as avg_out,
      avg(duration_ms) / 1000 as avg_secs
  by repo, standards_sha256
| sort total_cost desc
```

Repo totals only:

```text
stats count(*) as runs, sum(cost_usd) as total_cost, avg(cost_usd) as avg_cost
  by repo
| sort total_cost desc
| limit 25
```

### Escalation and no-verdict rate by config dimension

The under-confidence signal. `escalated` rising after a config change is the
review hedging more; `no_verdict` rising is runs dying before they finish. They
argue for different fixes, which is why they are separate outcomes.

The outcome mix per config, as a pivot. Read the four rows per `effort` x
`cli_version` group against each other:

```text
filter ispresent(outcome)
| stats count(*) as runs, avg(cost_usd) as avg_cost, avg(duration_ms) / 1000 as avg_secs
    by effort, cli_version, outcome
| sort effort, cli_version, outcome
```

The same thing as rates, in one row per group. `outcome = "escalated"` evaluates
to 1 or 0, so summing it counts matches:

```text
filter ispresent(outcome)
| stats count(*) as runs,
        sum(outcome = "escalated") * 100.0 / count(*) as escalated_pct,
        sum(outcome = "no_verdict") * 100.0 / count(*) as no_verdict_pct,
        sum(outcome = "changes_requested") * 100.0 / count(*) as changes_pct
    by effort, cli_version
| sort effort, cli_version
```

By prompt version (`workflow_sha`) instead, to attribute a rate change to a
prompt edit rather than a setting:

```text
filter ispresent(outcome)
| stats count(*) as runs,
        sum(outcome = "escalated") * 100.0 / count(*) as escalated_pct,
        sum(outcome = "no_verdict") * 100.0 / count(*) as no_verdict_pct
    by workflow_sha, flavor
| sort runs desc
```

Just the failures, newest first, when you want the runs themselves:

```text
filter outcome = "no_verdict"
| fields @timestamp, repo, pr_number, run_id, effort, cli_version, turns_used, max_turns, duration_ms
| sort @timestamp desc
| limit 50
```

### Turns used against the cap, and the duration distribution

Latency on a required check every PR waits on. A `turns_used` distribution
pressed against `max_turns` means the cap, not a loop, is ending reviews — which
is what turns a healthy long review into a `no_verdict`.

```text
filter ispresent(turns_used)
| fields turns_used * 100.0 / max_turns as pct_of_cap
| stats count(*) as runs,
        avg(turns_used) as avg_turns,
        max(turns_used) as max_turns_used,
        pct(turns_used, 50) as p50_turns,
        pct(turns_used, 90) as p90_turns,
        pct(turns_used, 99) as p99_turns,
        avg(pct_of_cap) as avg_pct_of_cap
    by effort
```

Runs that got within 10% of the cap — the population at risk:

```text
filter ispresent(turns_used) and turns_used >= max_turns * 0.9
| fields @timestamp, repo, pr_number, run_id, turns_used, max_turns, outcome, duration_ms
| sort @timestamp desc
| limit 50
```

Duration distribution against the wall-clock cap:

```text
filter ispresent(duration_ms)
| fields duration_ms / 1000 as secs
| stats count(*) as runs,
        avg(secs) as avg_secs,
        pct(secs, 50) as p50,
        pct(secs, 90) as p90,
        pct(secs, 99) as p99,
        max(secs) as max_secs
    by effort, flavor
```

### Housekeeping

Is the pipeline alive at all — records per day, and the config spread in them:

```text
stats count(*) as records,
      count_distinct(repo) as repos,
      count_distinct(cli_version) as cli_versions
  by bin(1d)
```

Sustained loss is detected account-side by the `pepper-audit` composite alarm,
not by this query and never by a failing check — see
[`infrastructure/README.md`](../infrastructure/README.md).

## Schema changes

`schema_version` is the contract. Every query above addresses fields by name, so
renaming or removing one is a version bump, not a refactor — filter on
`schema_version` when a series spans a bump. The record is assembled by
`scripts/pepper-audit-record.jq` and pinned field-by-field by
`scripts/test/pepper-audit-record_test.sh`, which asserts the exact key set.
