# Changing Pepper's model

| | |
|---|---|
| **Status** | Proposed |
| **First exercised by** | [Pepper on Sonnet 5.5](https://linear.app/spicelabshq/project/pepper-on-sonnet-55-3760eb1e7710) (Sonnet 5 → Sonnet 5.5, then global → US-only routing) |
| **Accepted when** | That project completes and DEV-2467 revises this runbook against what actually happened |

How to move Pepper's review to a different model, a different Bedrock routing
type, or a different reasoning-effort default, without breaking a required
check that every org PR waits on. It is written for the next change, not the
last one: model names below are examples.

**Proposed** means nobody has run this end to end yet. Where a step or a
threshold is a guess, it says so. Treat the numbers as starting values to
question, not settled policy.

## When this applies

| Change | Sections |
|---|---|
| New model (e.g. a new Sonnet) | All of them, in order |
| Routing only, same model (e.g. global → US-only) | [Assess](#1-assess), [Access](#2-access), [Routing-only changes](#6-routing-only-changes) |
| Effort default only, same model | [Assess](#1-assess) (baseline), [Re-tune effort](#5-re-tune-effort) |
| claude-cli version | Not covered. The CLI is unpinned (see [`pepper-audit.md`](pepper-audit.md)); watch `cli_version` in the audit record instead. |

## Principles

- **One change at a time.** A model change runs at the old effort level; effort
  is re-tuned afterwards. A routing change keeps model and effort fixed.
  Otherwise a shift in cost or behavior cannot be attributed.
- **Measure against the audit record.** Every run writes configuration, outcome,
  tokens and cost to `/pepper/pr-review/audit`. The baseline and every readout
  come from there, using [`pepper-audit.md`](pepper-audit.md).
- **Write the pass criteria before the data exists.** Put them in the readout
  issue when the plan is filed.
- **A person's step is its own issue.** Admin applies, AWS releases and spend
  approvals block the agent work that needs them; they never hide inside it
  (`project-planning.md` rule 9).
- **Rollback is one step at every point.** Know what it is before starting each
  phase.

## Constraints that shape every transition

These come from how Pepper's AWS footprint is built. The detail is in
[`infrastructure/README.md`](../infrastructure/README.md).

- **Application inference profiles are immutable.** A profile wraps one model
  and one routing type forever. Any change of either means a new profile with a
  new ARN.
- **Four things move together** when the default moves: the tagged profile, the
  role policy, the workflow's `review_model` default, and the missing-records
  alarm's `BedrockModelIdDimension`. Missing the alarm is silent: it keeps
  watching a profile with no traffic and can never fire.
- **Tags are load-bearing.** The role can only invoke profiles tagged
  `Product=pepper`, and cost attribution keys on `Product`/`Mode`. An untagged
  profile is invisible to Pepper.
- **The role grants models by ARN.** A new model, or a new routing type for an
  existing one, needs a policy edit. Only `spice-admin` can apply it.
- **The missing-records alarm stack** is also deployed with `spice-admin`.
- **The rollback profile should not be older than the primary.** Older models
  reach the deprecation list first.

## Phases

### 1. Assess

Before filing the plan, gather:

1. **What routing exists.** In `us-west-2`, list system-defined profiles for the
   model:

   ```sh
   aws bedrock list-inference-profiles --type-equals SYSTEM_DEFINED \
     --profile spice-ro --region us-west-2 \
     --query "inferenceProfileSummaries[?contains(inferenceProfileId,'<model>')].inferenceProfileId"
   ```

   `us.<model>` keeps inference in US regions. `global.<model>` routes to any
   commercial region worldwide. A new model sometimes ships `global.` first; in
   past launches `us.` followed within hours to three weeks, but nothing
   guarantees it. The model card in the Bedrock user guide lists routing per
   region.
2. **Data residency.** If only `global.` exists, whether Pepper may send code
   outside the US is a decision for a person, made before any work starts. If
   the answer is "yes for now, US-only later", plan the
   [routing-only change](#6-routing-only-changes) as a later phase with a
   detector (see [Monitoring](#monitoring)).
3. **Price and lifecycle.** List price per token, and the Bedrock model card's
   "EOL no sooner than" date. A same-price model changes the bill only through
   tokens per review.
4. **Breaking changes.** Read the model's migration notes for request shapes it
   rejects (thinking modes, `tool_choice`, removed parameters) and safety
   classifiers that can refuse. Pepper sets only `--effort`, but claude-cli has
   sent rejected shapes on side calls before (DEV-881), so plan to check
   CloudTrail rather than assume.
5. **Effort guidance.** Whether the vendor recalibrated effort levels for this
   model. That decides whether [Re-tune effort](#5-re-tune-effort) is needed.
6. **Baseline.** At least 30 days of the current configuration from the audit
   log: runs, cost (mean and median), outcome mix, turns, p50/p90 duration,
   split by `flavor`, plus traffic share per repo. Paste it into the project
   description.

### 2. Access

| Step | Who | Done when |
|---|---|---|
| Create the tagged application profile wrapping the chosen routing (`spice` profile) | Agent | `list-tags-for-resource` shows `Product=pepper`, `Mode=review` |
| PR adding the model's ARNs to `AuthorizedModelsReachableOnlyThroughAProfile` in `bedrock-role-policy.json`, plus the profile table in `infrastructure/README.md` | Agent | Under `spice-ro`, `iam simulate-custom-policy` allows invoke through the new profile and denies a direct model call |
| Apply the merged policy (runbook in `infrastructure/README.md`) | Person, `spice-admin` | `get-role-policy` under `spice-ro` matches `main` |

Which ARNs to grant depends on the routing. Read them off the system profile
rather than guessing:

```sh
aws bedrock get-inference-profile --inference-profile-identifier <us.|global.><model> \
  --profile spice-ro --region us-west-2 --query "models[].modelArn"
```

A `us.` profile lists one ARN per US region. A `global.` profile lists the
source-region ARN **and** a region-less `arn:aws:bedrock:::foundation-model/<model>`;
both are required. Keep the `bedrock:InferenceProfileArn` condition on the
statement so the model stays reachable only through a tagged profile.

### 3. Canary

Run the new model on a share of live PRs, at the **current** effort level,
alongside the current model.

- **Assign per PR, not per repo.** A deterministic hash of `repo#pr_number`
  picks the arm, so every review round of a PR stays on one model. Traffic is
  concentrated (one repo has carried about 70% of reviews), so a repo split is
  either trivial or most of the fleet.
- **Share: 50%** was the first choice. Lower it if the change is riskier than a
  same-family upgrade.
- **Mechanism:** the arm table in `pepper-pr-review.yml` (name, profile, effort,
  weight), with `arm` recorded in the audit record. Built in DEV-2455; until it
  lands this step has no tooling.

**Day 1**, on the first ten runs in the new arm:

- every run reached a verdict, with the expected `model_executed`
- no `ValidationException` on the new profile in CloudTrail
- the arm split looks even

Any failure: set the new arm's weight to 0 and find out why.

**Readout** after at least 7 days and about 80 PRs per arm (a guess, to be
checked). Starting pass criteria, new arm against the current one:

| Signal | Pass |
|---|---|
| `no_verdict` | none caused by the model, including safety refusals (needs the reason code from DEV-1335) |
| changes-requested rate | within ±5 points |
| escalation rate | up no more than 2 points |
| p90 duration | no more than 25% worse |
| cost per review | no more than 20% higher |
| CloudTrail | no errors on the new profile |
| Cost Explorer | new profile's spend appears under `Product=pepper, Mode=review` |

Post the table and a go/no-go as a project update. Missing one criterion is a
no-go unless the readout explains why it does not matter.

**Rollback:** new arm weight to 0.

### 4. Switch the default

| Step | Who |
|---|---|
| PR: `review_model` default and arm table → new model 100%; the previous primary becomes the rollback; retire any rollback profile older than it (README row and policy ARNs); update ids in the alarm deploy command, `pepper-audit.cfn.yml` parameter text and `pepper-audit.md` examples. Release through the pepper-pr-review release loop. | Agent |
| Redeploy `pepper-audit` with the new `BedrockModelIdDimension`, apply the policy, delete the retired profile. Do it promptly: until then the alarm cannot fire. | Person, `spice-admin` |

Done when the first five runs after release record the new `model_executed`,
and `describe-stacks` shows the new dimension.

**Rollback:** pass the rollback profile's ARN as `review_model`, or revert the
release.

### 5. Re-tune effort

Needed when the vendor recalibrates effort levels, or when an effort change is
being considered for cost. Two parts, because neither answers the question
alone:

- **Offline benchmark (recall).** Replay a fixed set of past PRs with known
  answers: roughly 20 where a change request led to a real fix (the fix is the
  answer key) and 15 clean approvals. Run each configuration being compared in
  a sandbox repo, grade whether the known defect was flagged and whether a
  clean PR drew a change request. Keep the grader's reasoning per case.
  Budget about $1.30 per review per configuration at current prices; set a cap
  before running. Harness built in DEV-2458.
- **Live A/B (cost, latency, gross regressions).** Two effort arms on the same
  model, 50/50 per PR, two weeks, at least 150 PRs per arm. At Pepper's volume,
  changes are requested on about 10% of PRs and escalations on under 1%, so a
  live A/B cannot prove recall; it measures cost, turns and duration reliably
  and catches large behavior changes.

Run the benchmark first and only A/B a lower effort the benchmark says is safe.
Adopt the lower level only if its benchmark recall is within one case of the
higher level and the live pass criteria hold (no model-caused `no_verdict`,
escalation up no more than 2 points, changes-requested within ±4 points, p90
duration no worse). Otherwise keep the higher level and record why.

Avoid `low` for review unless the benchmark supports it: vendors flag that
low effort skips verification.

### 6. Routing-only changes

Same model, different routing (typically `global.` → `us.` when the US profile
ships). No canary or effort work, because the model does not change.

1. [Access](#2-access) for the new routing: new profile, policy adds its ARNs,
   keeps the old ones.
2. PR switching every arm and the default to the new profile, and dropping the
   old routing's ARNs from the policy.
3. Person: redeploy the alarm on the new profile id, apply the policy, delete
   the old profile.
4. After one week, compare cost per review, p50/p90 duration and `no_verdict`
   with the last week on the old routing. Regional routing may cost more than
   global; report the difference in dollars per month.

## Monitoring

Through any transition, check:

| What | Where | Why |
|---|---|---|
| Outcome mix, cost, turns, duration by arm | Audit log, [`pepper-audit.md`](pepper-audit.md) queries | The readout |
| `no_verdict` with reason | Audit log (DEV-1335) | Separates model failures and safety refusals from infrastructure noise |
| Rejected requests | CloudTrail, errors on the profile | CLI side calls can send shapes a new model rejects, and the CLI swallows them |
| Spend attribution | Cost Explorer, `Product`/`Mode` tags | Confirms the new profile's tags are live (lags about a day) |
| Missing-records alarm target | `pepper-audit` stack parameter | Must match the profile carrying the traffic |
| US routing availability | Weekly check (DEV-2460) | Starts the routing-only change when AWS ships it |

## Planning the work

File the transition as a Linear project with one milestone per phase used above
(`project-planning.md`). Keep each admin apply and each external gate as its own
issue assigned to a person, blocking the work that needs it. The Sonnet 5.5
project is a worked example of the tree.
