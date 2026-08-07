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
