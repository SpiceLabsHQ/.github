# Infrastructure

AWS resources this repo's workflows depend on, in the Spice account (`618640261060`).

**Nothing here is deployed by CI.** These documents are the source of truth for
resources that are currently applied by hand with admin credentials. Adopting
them into CloudFormation is tracked in DEV-693; this directory exists so that,
until then, a hand-push is a documented procedure rather than tribal knowledge —
and so the eventual template has its starting artifacts.

If you change one of these resources in AWS, change it here in the same PR. A
live edit that never lands in the repo is exactly the failure this directory was
created to stop.

---

## `GitHubActions-ClaudeCode-Bedrock`

The role every Claude-on-Bedrock workflow at the org assumes via GitHub OIDC. It
is referenced by the org-level secret `AWS_CLAUDE_BEDROCK_ROLE_ARN` and consumed
today by [`pepper-pr-review.yml`](../.github/workflows/pepper-pr-review.yml).

| File | Applied to |
|---|---|
| [`bedrock-role-policy.json`](bedrock-role-policy.json) | The inline policy named `BedrockModelAccess` |
| [`bedrock-role-trust-policy.json`](bedrock-role-trust-policy.json) | The role's trust policy (`AssumeRolePolicyDocument`) |

Both files were captured from the live role and are byte-identical to what is
applied.

### What the policy allows, and why

`BedrockModelAccess` is deliberately narrow (DEV-875). Before it was scoped, it
granted `bedrock:InvokeModel` on `arn:aws:bedrock:*:*:foundation-model/*` with no
condition — any model, any region — which meant the inference profile was a
convention the workflow followed rather than a boundary the credential enforced.

| Sid | Grants | Why it is shaped this way |
|---|---|---|
| `InvokePepperTaggedProfilesOnly` | Invoke any application inference profile tagged `Product=pepper` | Scoped by **tag, not ARN**. Application inference profiles are immutable in the model they wrap, so a model upgrade replaces the profile and mints a new ARN. Tag-scoping survives that untouched; ARN-pinning would force an IAM edit on every upgrade. |
| `WritePepperReviewAuditLog` | `logs:CreateLogStream` + `logs:PutLogEvents` on `/pepper/pr-review/audit` only | The DEV-653 audit record, written with the credentials the review job has already assumed. **Append-only, one log group.** No read, no delete, no `logs:CreateLogGroup` — the group and its retention are a CloudFormation resource (`pepper-audit.cfn.yml`), not a role permission. Worst case under role compromise is junk lines in the audit log that the same role cannot then erase. |
| `AuthorizedModelsReachableOnlyThroughAProfile` | Invoke Sonnet 5 and Sonnet 4.5, in three regions, **only** when reached through one of this account's application inference profiles | AWS requires the underlying foundation model to be authorized alongside the profile. The `bedrock:InferenceProfileArn` condition is what stops a direct model call that would bypass the profile — and therefore bypass the `Product`/`Mode` cost-allocation tags. Sonnet 4.5 is retained as a rollback path to the DEV-245 profiles. |
| `DiscoverProfiles` | Read-only `ListInferenceProfiles` / `GetInferenceProfile` | The action enumerates profiles at startup. |
| `MarketplaceModelAccess` | `aws-marketplace:Subscribe` / `ViewSubscriptions` | Retained deliberately — auto-subscription on first use of a model is acceptable. |

The policy denies system-defined inference profiles (`inference-profile/*`)
outright. `claude-code-action` runs a model-availability preflight that pings
every model ID it knows about; those pings now fail with `AccessDenied`, which is
the intended answer and is not fatal to the run. That preflight is what generated
the spurious Bedrock deprecation and new-model-subscription notices this scoping
was written to stop.

### Constraints that will break Pepper

- **Replacement inference profiles must carry the `Product` and `Mode` tags.**
  Access is granted by `aws:ResourceTag/Product = pepper`. An untagged profile is
  invisible to this role no matter how the workflow references it.
- **The trust policy must keep both `sub` patterns.** `repo:SpiceLabsHQ/*` and
  `repo:SpiceLabsHQ@173748738/*` are not redundant: repos created after
  2026-07-15 emit ID-qualified OIDC subjects, and dropping the second silently
  breaks every one of them (DEV-693).
- **Adding a model means editing this policy.** The model ARNs are pinned, so a
  new profile wrapping an unlisted model gets `AccessDenied` even when correctly
  tagged. The workflow default and the ARNs here move together.
- **The audit log-group ARN is pinned.** Renaming the group in
  `pepper-audit.cfn.yml` without renaming it here silently stops audit records —
  and, because the capture step is non-fatal by design, stops them inside a green
  required check. The group name appears in three places that move together: this
  policy, that template, and the `PEPPER_AUDIT_LOG_GROUP` default in
  `scripts/pepper-audit-record.sh`.

### Applying a change

Requires admin credentials — the PowerUser daily-driver profile cannot read or
write IAM.

```sh
# 1. Capture the current policy first, so you have a rollback artifact.
aws iam get-role-policy \
  --role-name GitHubActions-ClaudeCode-Bedrock \
  --policy-name BedrockModelAccess \
  --profile spice-admin --output json \
  | jq .PolicyDocument > /tmp/bedrock-role-policy.rollback.json

# 2. Validate the change before applying it. Both cases must hold.
POLICY=$(jq -c . infrastructure/bedrock-role-policy.json)
PROFILE=arn:aws:bedrock:us-west-2:618640261060:application-inference-profile/xda66yqkegz4

#    Authorized model reached through a profile -> allowed
aws iam simulate-custom-policy --profile spice-admin \
  --policy-input-list "$POLICY" \
  --action-names bedrock:InvokeModelWithResponseStream \
  --resource-arns arn:aws:bedrock:us-west-2::foundation-model/anthropic.claude-sonnet-5 \
  --context-entries "ContextKeyName=bedrock:InferenceProfileArn,ContextKeyType=string,ContextKeyValues=$PROFILE" \
  --query 'EvaluationResults[0].EvalDecision'

#    Same model called directly -> implicitDeny
aws iam simulate-custom-policy --profile spice-admin \
  --policy-input-list "$POLICY" \
  --action-names bedrock:InvokeModel \
  --resource-arns arn:aws:bedrock:us-west-2::foundation-model/anthropic.claude-sonnet-5 \
  --query 'EvaluationResults[0].EvalDecision'

# 3. Apply.
aws iam put-role-policy \
  --role-name GitHubActions-ClaudeCode-Bedrock \
  --policy-name BedrockModelAccess \
  --policy-document file://infrastructure/bedrock-role-policy.json \
  --profile spice-admin
```

Do not try to validate the `WritePepperReviewAuditLog` statement with the
simulator: `simulate-custom-policy` fails to wildcard-match log-*stream* ARNs
(the extra `:log-stream:` colons defeat its matcher, so even a policy resource
of `log-group:*` returns `implicitDeny` against a stream ARN, with no matched
statements). Real IAM evaluation matches `log-group:/pepper/pr-review/audit:*`
against stream ARNs fine — the live-run check below is the authoritative one
for that statement. Note also the simulator caps each policy at 2,000
characters, which is why the `jq -c` minify in step 2 is not optional.

### Verifying it took

Open a PR in this repo and let Pepper review it. A green review is the real
check — the simulator validates the policy, not the runtime.

For a direct read, CloudTrail shows the split cleanly. In the minutes after a
Pepper run, `bedrock.amazonaws.com` events for the run's session should show the
preflight probe (`<minified>/JS <version>` user agent, e.g. `K9s/JS 0.94.0`)
returning `AccessDenied`, and the review itself (`claude-cli/<version>`) against
the profile ID returning success. Denials against any `claude-cli` caller mean
the policy is too tight — roll back.

### Rolling back

```sh
aws iam put-role-policy \
  --role-name GitHubActions-ClaudeCode-Bedrock \
  --policy-name BedrockModelAccess \
  --policy-document file:///tmp/bedrock-role-policy.rollback.json \
  --profile spice-admin
```

If you need the pre-DEV-875 policy specifically, it is the version of
`bedrock-role-policy.json` immediately before the commit that introduced this
directory.

### Testing a change without risking the org

The role is shared — its trust policy accepts `repo:SpiceLabsHQ/*`, so a bad
policy breaks Pepper everywhere at once. To canary a change first:

1. Create a second role with the candidate policy and a **verbatim copy** of
   `bedrock-role-trust-policy.json`.
2. Set a repo-level `AWS_CLAUDE_BEDROCK_ROLE_ARN` secret on this repo pointing at
   it. A repo secret overrides the org secret for this repo only.
3. Open a PR and watch Pepper.
4. Green: apply to the real role, then `gh secret delete
   AWS_CLAUDE_BEDROCK_ROLE_ARN --repo SpiceLabsHQ/.github` and delete the canary
   role. Red: delete the repo secret and the org is untouched.

Do **not** canary by editing `pepper-pr-review.yml` — `pepper-self-review.yml`
calls the local copy of that workflow, so the PR under test would be reviewed by
its own modified version.

---

## The rest of Pepper's AWS surface

Everything else Pepper stands on in this account, none of it defined in any
repo. Captured 2026-08-06 from the live account (DEV-653) so that this
directory reads as Pepper's COMPLETE AWS footprint — before this section, a
reader could reasonably assume the role above was all there is, and recreate or
delete one of these without knowing what it holds up.

### Application inference profiles

The model identities Pepper invokes. Both live in `us-west-2` only, both tagged
`Product=pepper, Mode=review`.

| Profile | Id | Wraps | Created |
|---|---|---|---|
| `pepper-pr-review-sonnet-5` | `xda66yqkegz4` | `anthropic.claude-sonnet-5` (us-east-1/2, us-west-2) | 2026-07-04 |
| `pepper-pr-review` | `cz21awrop223` | `anthropic.claude-sonnet-4-5` (us-east-1/2, us-west-2) | 2026-05-10 |

`pepper-pr-review-sonnet-5` is the workflow default
(`review_model` in `pepper-pr-review.yml`). `pepper-pr-review` is the DEV-245
Sonnet 4.5 profile, retained deliberately as the rollback path — the policy
above keeps its wrapped model authorized for exactly that reason.

**The tags are load-bearing twice over.** IAM access is granted by
`aws:ResourceTag/Product = pepper` (see the policy table above), and Cost
Explorer attribution keys on `Product`/`Mode`. A profile recreated without the
tags is invisible to the role — Pepper loses Bedrock access org-wide — and its
spend disappears from attribution. Profiles are **immutable** in the model they
wrap: an upgrade means a NEW profile (new id), which in turn means updating the
`review_model` default in the workflow, the `BedrockModelIdDimension` parameter
of the `pepper-audit` stack below, and the pinned model ARNs in the policy —
those four move together (DEV-492/DEV-875).

### GitHub OIDC identity provider

`arn:aws:iam::618640261060:oidc-provider/token.actions.githubusercontent.com`,
audience `sts.amazonaws.com`. The role's trust policy is meaningless without
it — every `configure-aws-credentials` assume in every Pepper run authenticates
through this provider. It is shared account plumbing, not Pepper-specific:
deleting it breaks every GitHub-OIDC consumer in the account at once.

### Cost-allocation tag activation

`Product` and `Mode` are activated as **cost allocation tags** in the account's
billing settings (active since 2026-05-11). This is an account-level toggle,
not a resource: the DEV-245 cost-attribution story — and the spend-by-profile
numbers the DEV-653 audit complements — silently depend on it. Deactivating it
stops Cost Explorer from grouping by these tags going forward; nothing in any
repo would fail or warn.

---

## `pepper-audit` — the review audit log and its alarm

[`pepper-audit.cfn.yml`](pepper-audit.cfn.yml) creates the two resources the
DEV-653 audit record depends on:

| Resource | What it is |
|---|---|
| Log group `/pepper/pr-review/audit` | Where every review run writes one schema-v1 JSON record. Retention 731 days (two years), because the dataset's purpose is longitudinal comparison across model, prompt and CLI versions and a series that expires is a comparison you can only run for as long as its shorter arm survives. |
| Composite alarm `<stack>-missing-records` | Fires when Bedrock was invoked but no records landed. The capture step is `continue-on-error` by hard requirement (a required check must never go red over telemetry), so this alarm is the **only** signal that the pipeline has broken. |

Plain CloudFormation, not SAM: there are no Lambdas and no build step, so a
transform would buy nothing. And, per the rule at the top of this file, there is
no deploy workflow — with none, no merge can ever trigger a deployment.

The **IAM half** of this change is the `WritePepperReviewAuditLog` statement in
`bedrock-role-policy.json`. It is applied with the ordinary
[Applying a change](#applying-a-change) flow above and rolled back with
[Rolling back](#rolling-back) — nothing about it is special except the order:
deploy the stack first, so the log group exists before the role is allowed to
write to it.

### Deploying the stack

Requires admin credentials — the daily-driver PowerUser profile cannot create
alarms or log groups.

```sh
# 1. Confirm the ModelId dimension for the review inference profile. The alarm's
#    "reviews ran" half keys on it, and a stale value makes the alarm silently
#    un-fireable. Expect a bare profile id (e.g. xda66yqkegz4) — application
#    inference profiles are immutable, so a model upgrade mints a new one.
aws cloudwatch list-metrics --namespace AWS/Bedrock --metric-name Invocations \
  --profile spice-ro --region us-west-2 \
  --query 'Metrics[].Dimensions' --output json

# 2. Confirm the shared critical-alerts export exists in this account and
#    region. The template imports it by name, so a missing export fails the
#    deploy outright rather than producing an alarm that notifies nothing.
aws cloudformation list-exports \
  --profile spice-ro --region us-west-2 \
  --query "Exports[?Name=='critical-alerts-topic-arn'].Value" --output text

#    Its topic policy must permit CloudWatch alarms from THIS account. The
#    channel ships a statement that does exactly that, pinned with
#    aws:SourceAccount; confirm it is still present before relying on it.
aws sns get-topic-attributes \
  --topic-arn arn:aws:sns:us-west-2:618640261060:critical-alerts \
  --profile spice-ro --region us-west-2 --query 'Attributes.Policy' --output text

# 3. Deploy. Idempotent — re-run it after any edit to the template.
aws cloudformation deploy \
  --template-file infrastructure/pepper-audit.cfn.yml \
  --stack-name pepper-audit \
  --parameter-overrides BedrockModelIdDimension=xda66yqkegz4 \
  --profile spice-admin --region us-west-2

# 4. Read back what was created.
aws cloudformation describe-stacks --stack-name pepper-audit \
  --profile spice-admin --region us-west-2 --query 'Stacks[0].Outputs'
```

Then apply the `WritePepperReviewAuditLog` statement to the role with the
[Applying a change](#applying-a-change) flow above.

The log group carries `DeletionPolicy: Retain`: deleting the stack must never be
the thing that discards two years of evidence. That also means a re-`deploy`
after a stack delete fails on the already-existing group — import it or delete it
by hand first, deliberately.

### Verifying a record landed

The real check is a live Pepper run. Open a PR in this repo, let Pepper review
it, and then:

```sh
# The job summary on the review run renders the same record — start there if you
# only want to see one run. For the durable copy, one stream per run attempt,
# named <run_id>-<run_attempt>:
aws logs describe-log-streams \
  --log-group-name /pepper/pr-review/audit \
  --order-by LastEventTime --descending --max-items 5 \
  --profile spice-ro --region us-west-2 \
  --query 'logStreams[].[logStreamName,lastEventTimestamp]' --output table

# The record itself.
aws logs get-log-events \
  --log-group-name /pepper/pr-review/audit \
  --log-stream-name "<run_id>-<run_attempt>" \
  --profile spice-ro --region us-west-2 \
  --query 'events[].message' --output text | jq .
```

A record whose `cost_usd` is `null` is expected, not broken: the capture step
never invents a price, and the token split is the ground truth cost is derived
from at query time. See [`docs/pepper-audit.md`](../docs/pepper-audit.md) for the
schema and the standing Logs Insights queries.

If nothing lands, the review run's log is where the reason is: the capture step
annotates every failure with a `::warning::` and still exits green, by design.
The usual cause is the IAM statement not having been applied.

### Rolling the stack back

```sh
# Alarms only — the log group is Retain, so this leaves the records intact.
aws cloudformation delete-stack --stack-name pepper-audit \
  --profile spice-admin --region us-west-2
```

To stop the writes without touching the stack, drop the
`WritePepperReviewAuditLog` statement from `bedrock-role-policy.json` and
re-apply. Reviews are unaffected either way — a denied write is a `::warning::`
inside a green check, which is the whole point of the design.
