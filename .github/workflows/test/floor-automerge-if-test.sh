#!/usr/bin/env bash
# Fixture tests for the floor-automerge arming condition (ADR-0017). The
# author-class logic lives entirely in the job-level `if:` expression of
# floor-automerge.yml (it MUST stay there — that is what makes non-arming PRs
# skip before a runner is provisioned). To test the EXACT expression that
# ships without duplicating it, this harness extracts the `if:` string
# straight from the YAML and evaluates it against fixture event contexts with
# a minimal evaluator covering exactly the operators the expression uses
# (&&, ||, ==, !=, contains(), fromJSON(), dotted/bracketed context paths).
#
# If the expression is ever rewritten with syntax the evaluator doesn't know,
# the harness fails loudly — update the evaluator alongside, consciously.
# What this pins down (the invariants, per ADR-0017):
#   - only the ENUMERATED bots arm by default (never an unlisted [bot] app)
#   - humans arm only where `automerge-humans == 'true'`
#   - the opt-in branch is gated on user.type == 'User', so an unlisted bot
#     cannot arm THROUGH an opt-in repo (the hole Pepper caught in review)
#   - rosemary-releaser, drafts, and the .github repo always skip
#   - a missing/false property fail-safes to skip
#
# Run locally:  .github/workflows/test/floor-automerge-if-test.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
YAML="${HERE}/../floor-automerge.yml"

python3 - "${YAML}" <<'PY'
import json, re, sys, yaml

doc = yaml.safe_load(open(sys.argv[1]))
expr = doc["jobs"]["enable-auto-merge"]["if"]
if not expr.strip():
    print("FAIL: could not extract the enable-auto-merge if: expression", file=sys.stderr)
    sys.exit(1)

# --- minimal evaluator for the GitHub expression subset the if: uses ---------
CTX = {}

def get(*segs):
    node = CTX
    for seg in segs:
        if not isinstance(node, dict) or seg not in node:
            return None  # GitHub yields null for a missing context path
        node = node[seg]
    return node

PATH = re.compile(r"github(?:\.[A-Za-z_]\w*|\['[^']+'\])+")

def to_get(match):
    token = match.group(0)
    segs = []
    for part in re.finditer(r"\.([A-Za-z_]\w*)|\['([^']+)'\]", token):
        segs.append(part.group(1) or part.group(2))
    return "get(" + ", ".join(repr(s) for s in ["github"] + segs) + ")"

def evaluate(expression, ctx):
    global CTX
    CTX = ctx
    py = PATH.sub(to_get, expression)
    py = py.replace("&&", " and ").replace("||", " or ")
    ns = {"get": get, "contains": lambda hay, item: item in hay,
          "fromJSON": json.loads, "true": True, "false": False, "null": None,
          "__builtins__": {}}
    return bool(eval(py, ns))  # noqa: S307 — fixture harness, fixed input

# --- fixture contexts ---------------------------------------------------------
def ctx(repo="SpiceLabsHQ/some-repo", login="human-dev", utype="User",
        draft=False, props=None):
    repository = {}
    if props is not None:
        repository["custom_properties"] = props
    return {"github": {
        "repository": repo,
        "event": {
            "pull_request": {"draft": draft,
                             "user": {"login": login, "type": utype}},
            "repository": repository,
        },
    }}

CASES = [
    # (description, context, should_arm)
    ("renovate arms by default (no property)",
     ctx(login="renovate[bot]", utype="Bot"), True),
    ("dependabot arms by default (no property)",
     ctx(login="dependabot[bot]", utype="Bot"), True),
    ("allowlisted bot still arms in an opt-in repo",
     ctx(login="renovate[bot]", utype="Bot",
         props={"automerge-humans": "true"}), True),
    ("human skips without the property",
     ctx(), False),
    ("human arms in an opt-in repo",
     ctx(props={"automerge-humans": "true"}), True),
    ("human skips when the property is 'false'",
     ctx(props={"automerge-humans": "false"}), False),
    ("human skips when custom_properties is absent entirely",
     ctx(props=None), False),
    ("UNLISTED bot skips even in an opt-in repo (the review catch)",
     ctx(login="some-future-app[bot]", utype="Bot",
         props={"automerge-humans": "true"}), False),
    ("rosemary-releaser skips even in an opt-in repo",
     ctx(login="rosemary-releaser[bot]", utype="Bot",
         props={"automerge-humans": "true"}), False),
    ("draft skips even in an opt-in repo",
     ctx(draft=True, props={"automerge-humans": "true"}), False),
    ("the .github repo always skips",
     ctx(repo="SpiceLabsHQ/.github", login="renovate[bot]", utype="Bot"),
     False),
]

fails = 0
for desc, context, want in CASES:
    try:
        got = evaluate(expr, context)
    except Exception as exc:  # unknown syntax => evaluator needs updating
        print(f"FAIL: {desc} — evaluator error: {exc}", file=sys.stderr)
        fails += 1
        continue
    if got == want:
        print(f"PASS: {desc}")
    else:
        print(f"FAIL: {desc} — got arm={got} want arm={want}", file=sys.stderr)
        fails += 1

sys.exit(1 if fails else 0)
PY
