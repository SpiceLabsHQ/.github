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

> Every query below was run against the first live record on 2026-08-07 (the
> day the stack and IAM statement were deployed): each field name resolved and
> each aggregate matched the raw record. One observed behavior worth knowing
> when reading results: grouping by a field that is `null` (e.g.
> `standards_sha256` on a repo with no standards file) omits that column from
> the result row entirely rather than printing a null bucket label.

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
  "cookbook_ref": "v1.2.0",
  "arm": "s5-high",
  "model": "arn:aws:bedrock:us-west-2:618640261060:application-inference-profile/xda66yqkegz4",
  "model_executed": "claude-sonnet-5",
  "effort": "high",
  "max_turns": 80,
  "review_timeout_minutes": 50,
  "cli_version": "2.1.223",
  "outcome": "approved",
  "no_verdict_reason": null,
  "refusal_category": null,
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
| `cookbook_ref` | The Eng-Cookbook release tag whose `standards/` the prompt actually carried (DEV-1119), or `null` when the run degraded to the "no org standards this run" marker — no stable release, a failed checkout, or the `dependency` flavor, which has no standards block. Pepper reviews against the **latest stable** release, a deliberate float, so this is the field that attributes a behavior or cost shift to a cookbook release rather than to a prompt or model change. |
| `arm` | The model/effort arm the workflow picked for this PR (DEV-2455): an arm name from the workflow's arm table (e.g. `s5-high`, `s55-high`), `override` when the caller's `model` or a non-default `review_model` input replaced the arm, `default-fallback` when selection failed and the run used the default model at `high`, or `null` on records written before the field existed. A PR keeps one arm across all its review rounds, so compare arms by PR as well as by run. |
| `model` | The application-inference-profile ARN the workflow resolved, **as passed** — the key AWS Cost Explorer attribution and IAM scoping hang off. Group cost by this. |
| `model_executed` | The resolved model id the CLI actually sent (e.g. `claude-sonnet-5`), read off the SDK stream; `null` when no stream was readable. A row whose `model_executed` names something its `model` profile does not wrap is the CLI ignoring the workflow — the DEV-881 failure class. |
| `effort`, `cli_version` | Recorded **as executed** — read off what the CLI actually sent, with the workflow's own settings only as a fallback (both sources speak the same vocabulary, so as-executed is strictly the better observation). |
| `outcome` | `approved`, `changes_requested`, `escalated`, `no_verdict`, or `null`. **`escalated` and `no_verdict` are different things.** `escalated` is the review working — Pepper formed a judgment and deferred to a human, and a rise in its rate is how a too-low `effort` shows up. `no_verdict` is a failure: the run ended without a verdict the workflow could read — `no_verdict_reason` says why. `null` means the outcome labels were unreadable at capture time. |
| `no_verdict_reason` | Why a `no_verdict` run ended (DEV-1335); `null` on every other outcome. First match wins: `prompt_build_failure` (a setup step before Run Pepper failed — checkout, prompt build, model/tools/MCP, AWS credentials — so the model never ran); `verdict_unparseable` (Pepper filed a review on the head SHA but never swapped `pepper-cooking`, so the workflow could not read it as a verdict); `refused` (the model stopped with `stop_reason: "refusal"`); `api_error` (a harness-made error message — model `<synthetic>` or `isApiErrorMessage`, e.g. a Bedrock `ValidationException` — or an errored result other than the turn cap); `turn_cap` (`turns_used` reached `max_turns`); `timeout` (Run Pepper failed or was cancelled with no result record and the transcript spans at least 90% of `review_timeout_minutes`); `cancelled` (Run Pepper cancelled otherwise); `verdict_not_filed` (a clean finish under both caps with no verdict filed — the model skipped its one required action); `unknown` (none of these could be established). Added without a schema bump. |
| `refusal_category` | The refusal's `stop_details.category` (`cyber`, `bio`, `frontier_llm`, `reasoning_extraction`, `general_harms`) when `no_verdict_reason` is `refused`; otherwise `null`, including a refusal whose category was not reported. |
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

Or by Eng-Cookbook release (`cookbook_ref`), to tell a standards cut that
started blocking on a new MUST apart from a prompt edit. `null` rows are the
runs that carried no org standards (no stable release yet, a failed checkout, or
the `dependency` flavor); a rate change between the `null` rows and the first
tagged rows is the cost of the standards block itself:

```text
filter ispresent(outcome) and flavor = "default"
| stats count(*) as runs,
        sum(outcome = "changes_requested") * 100.0 / count(*) as changes_pct,
        sum(outcome = "escalated") * 100.0 / count(*) as escalated_pct,
        avg(tokens.input + tokens.cache_read + tokens.cache_creation) as avg_input_tokens
    by cookbook_ref
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

### Comparing runs by model and effort

The canary comparison: does a different model or `effort` change what a review
costs, how it ends, or how long it takes? Every query here groups by
`model_executed`, `effort` and `flavor`. Group by `model_executed`, not `model`:
the profile ARN is what the workflow asked for, `model_executed` is what the CLI
ran. Once the `arm` field exists (DEV-2455), group by `arm` instead of the
`model_executed, effort` pair. Read "Reading a canary" below before comparing
two rows.

Measured over 2026-08-31 to 2026-09-30, 1,018 runs (901 `default`, 117
`dependency`), all `claude-sonnet-5` at `effort` `high`, so each query returns
two rows today, one per `flavor`.

Cost, output tokens, cache reads and turns, mean and median. `pct(x, 50)` is the
median. `runs_with_cost` is the number of runs that had a `cost_usd`; if it is
below `runs`, the cost columns cover fewer runs than the others (see
[`cost_usd` may be null](#cost_usd-may-be-null)):

```text
stats count(*) as runs,
      count(cost_usd) as runs_with_cost,
      avg(cost_usd) as avg_cost,
      pct(cost_usd, 50) as median_cost,
      avg(tokens.output) as avg_out,
      pct(tokens.output, 50) as median_out,
      avg(tokens.cache_read) as avg_cache_read,
      pct(tokens.cache_read, 50) as median_cache_read,
      avg(turns_used) as avg_turns,
      pct(turns_used, 50) as median_turns
  by model_executed, effort, flavor
| sort flavor, model_executed, effort
```

Result: `default` averaged $1.45 (median $1.31), 9.9k output tokens, 19.2 turns;
`dependency` averaged $0.52 (median $0.50), 2.2k output tokens, 8.4 turns.
Across both flavors the average was $1.34 and the median $1.24, with 17.9 turns.
Drop the `by` line for that all-runs row.

Duration, p50 and p90 in seconds:

```text
stats count(*) as runs,
      pct(duration_ms / 1000, 50) as p50_secs,
      pct(duration_ms / 1000, 90) as p90_secs
  by model_executed, effort, flavor
| sort flavor, model_executed, effort
```

Result: `default` p50 134 s, p90 252 s; `dependency` p50 42 s, p90 72 s. Across
both flavors, p50 123 s and p90 243 s.

Outcome mix. A row with zero `no_verdict` runs still prints `no_verdict = 0`,
because the `sum` is always present. A no-verdict reason field is planned
(DEV-1335); until it exists, `no_verdict` cannot be split by cause:

```text
filter ispresent(outcome)
| stats count(*) as runs,
        sum(outcome = "approved") as approved,
        sum(outcome = "changes_requested") as changes_requested,
        sum(outcome = "escalated") as escalated,
        sum(outcome = "no_verdict") as no_verdict,
        sum(outcome = "approved") * 100.0 / count(*) as approved_pct,
        sum(outcome = "changes_requested") * 100.0 / count(*) as changes_pct,
        sum(outcome = "escalated") * 100.0 / count(*) as escalated_pct,
        sum(outcome = "no_verdict") * 100.0 / count(*) as no_verdict_pct
    by model_executed, effort, flavor
| sort flavor, model_executed, effort
```

Result: `default` 793 approved, 100 changes requested, 8 escalated, 0 no-verdict
(88.0% / 11.1% / 0.9% / 0%); `dependency` 117 approved, nothing else. Both
flavors together: 910 / 100 / 8 / 0.

Review rounds per PR. A round is one run on the same PR, so a PR that was
pushed to and re-reviewed three times has three. The first `stats` counts runs
per PR, the second averages those counts:

```text
stats count(*) as runs by repo, pr_number, model_executed, effort, flavor
| stats count(*) as prs,
        avg(runs) as avg_rounds,
        pct(runs, 50) as median_rounds,
        max(runs) as max_rounds,
        sum(runs > 1) * 100.0 / count(*) as pct_prs_rereviewed
    by model_executed, effort, flavor
| sort flavor, model_executed, effort
```

Result: `default` 703 PRs at 1.28 rounds on average (median 1, max 10, 20.5%
re-reviewed); `dependency` 105 PRs at 1.11 (median 1, max 9, 3.8%
re-reviewed). The same query without `model_executed, effort, flavor` in the
first `stats` gives one figure for all PRs: 808 PRs at 1.26 rounds. A PR whose
runs span two arms is counted once in each arm, with only that arm's runs.

### Reading a canary

- **Sample size.** Wait for about 80 PRs per arm before comparing. Count PRs, not
  runs: the `prs` column of the rounds query. With fewer, one slow repo moves the
  mean, and the escalation rate (8 in 1,018 runs today) is too rare to compare
  at all.
- **Check the repo mix.** `SpiceLabsHQ/Lumen-BI` is about 69% of runs (702 of
  1,018). An arm that happened to review more or fewer Lumen-BI PRs will look
  cheaper or dearer for that reason alone. Compare the same repos across arms
  first:

  ```text
  stats count(*) as runs,
        avg(cost_usd) as avg_cost,
        sum(outcome = "changes_requested") * 100.0 / count(*) as changes_pct
      by repo, model_executed, effort
  | sort runs desc
  | limit 25
  ```

- **Rounds are per PR, not per run.** Average runs per PR, as above. Dividing
  total runs by distinct PRs across arms, or counting a run as a round, mixes
  PRs that only one arm saw.
- **Cost may be null.** Averages skip `null` `cost_usd`. Check `runs_with_cost`
  against `runs` before comparing cost, and derive cost from the token split
  when they differ.
- **Split by `flavor`.** `dependency` reviews run about a third of the turns
  and cost about a third as much. A mix shift between arms looks like a cost
  change.

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
`schema_version` when a series spans a bump. Adding a nullable field is not a
bump: rows written before it simply lack the key, which Logs Insights reads as
absent (`model_executed` and `cookbook_ref` arrived this way). The record is assembled by
`scripts/pepper-audit-record.jq` and pinned field-by-field by
`scripts/test/pepper-audit-record_test.sh`, which asserts the exact key set.
