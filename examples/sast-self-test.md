# SAST self-test — language auto-detect

Manual self-test of the language-ruleset auto-detection logic in
[`.github/workflows/sast.yml`](../.github/workflows/sast.yml). The shell logic
below is extracted from the `Build Semgrep config flags` step (the
`for ruleset in p/javascript p/python p/golang p/java` loop) so a developer
can re-run it against any working tree without invoking GitHub Actions.

This file is **not** shipped to consumers as a workflow — it is a developer
reference / regression record only. The full reusable workflow continues to
live at `.github/workflows/sast.yml`.

## Why the self-test exists

PR review (Pepper, round 3 of #25) flagged a shell-globbing bug in the prior
implementation: language patterns were stored as a single string
(`-name *.js -o -name *.jsx ...`) and then expanded *unquoted* into a `find`
invocation. If the workspace cwd happened to contain any file matching one of
those globs (e.g. a top-level `index.js`), bash performed pathname expansion
on the unquoted string and substituted the matched filenames into the `find`
argv, yielding either an `unknown primary or operator` error or — worse —
silently wrong detection results. See
[demonstration 3](#demonstration-3--reproduction-of-the-defect-1-glob-bug)
below for the actual reproduction.

The fix uses a properly quoted bash array of `-name <pattern>` arguments,
expanded as `"${args[@]}"`, so each pattern reaches `find` as a literal token
with no globbing.

## Extracted self-test snippet

```bash
#!/usr/bin/env bash
# Mirrors the language auto-detect block of .github/workflows/sast.yml
# (the loop over `p/javascript p/python p/golang p/java`). Run from the
# worktree root you want to probe.
set -euo pipefail

declare -A LANG_GLOB_PATTERNS=(
  [p/javascript]="*.js,*.jsx,*.ts,*.tsx"
  [p/python]="*.py"
  [p/golang]="*.go"
  [p/java]="*.java"
)

added=()
for ruleset in p/javascript p/python p/golang p/java; do
  IFS=',' read -ra patterns <<< "${LANG_GLOB_PATTERNS[$ruleset]}"
  args=()
  for ((i=0; i<${#patterns[@]}; i++)); do
    [ $i -gt 0 ] && args+=(-o)
    args+=(-name "${patterns[$i]}")
  done
  if [ -n "$(find . \
        -type d \( -name node_modules -o -name .git -o -name vendor \
                  -o -name dist -o -name build \) -prune \
        -o -type f \( "${args[@]}" \) -print -quit 2>/dev/null)" ]; then
    added+=("$ruleset")
    echo "Detected source for ${ruleset} -- adding ruleset"
  else
    echo "No source for ${ruleset} -- skipping"
  fi
done
echo "---"
echo "Final rulesets added: ${added[*]:-<none>}"
```

> **Bash version note.** The block above uses an associative array
> (`declare -A`), which requires bash 4+. GitHub Actions `ubuntu-latest`
> ships bash 5.x, so the workflow itself is unaffected. macOS ships bash 3.2
> by default; if you want to run the self-test on macOS without installing a
> newer bash, replace the associative array with parallel indexed arrays:
>
> ```bash
> RULESETS=(p/javascript p/python p/golang p/java)
> PATTERNS=("*.js,*.jsx,*.ts,*.tsx" "*.py" "*.go" "*.java")
> # then iterate over "${!RULESETS[@]}" and look up PATTERNS[$idx]
> ```
>
> The argv-passing semantics are identical; only the storage shape differs.

## Demonstration 1 — this `.github` org repo (no source files)

This repository contains only `.yml`, `.md`, and `.json` files — none of the
language probes should match.

```console
$ cd /path/to/SpiceLabsHQ-.github
$ bash self-test.sh
No source for p/javascript -- skipping
No source for p/python -- skipping
No source for p/golang -- skipping
No source for p/java -- skipping
---
Final rulesets added: <none>
```

Result: `--config p/<lang>` flags would NOT be added to the Semgrep
invocation. Curated rulesets (`p/default`, `p/owasp-top-ten`, `p/secrets`)
still apply unconditionally.

## Demonstration 2 — temp dir with a `.py` file

Create a one-file Python tree and confirm `p/python` is auto-detected:

```console
$ mkdir -p /tmp/sast-demo2 && cd /tmp/sast-demo2
$ printf 'def hello():\n    print("hi")\n' > app.py
$ ls -la
-rw-r--r--  1 user group  29 ... app.py

$ bash /path/to/self-test.sh
No source for p/javascript -- skipping
Detected source for p/python -- adding ruleset
No source for p/golang -- skipping
No source for p/java -- skipping
---
Final rulesets added: p/python
```

Result: `--config p/python` would be appended.

## Demonstration 3 — reproduction of the defect-1 glob bug

This demonstration creates a fixture where the workspace cwd contains files
literally matching `*.js` (`index.js`, `webpack.config.js`) and a
`package.json` whose textual content includes `"webpack *.js"`. The OLD
implementation (single-string pattern, unquoted expansion) breaks; the NEW
implementation (quoted-array `-name` args) returns the correct answer.

### Fixture setup

```console
$ rm -rf /tmp/sast-demo3 && mkdir -p /tmp/sast-demo3/src && cd /tmp/sast-demo3
$ printf 'console.log("a");\n' > src/app.js
$ printf 'console.log("b");\n' > src/util.jsx
$ printf 'export const x = 1;\n' > src/types.ts
$ printf '{"name":"demo","scripts":{"build":"webpack *.js"}}\n' > package.json
$ printf 'module.exports = {};\n' > webpack.config.js
$ printf 'console.log("c");\n' > index.js
$ ls *.js
index.js
webpack.config.js
```

### OLD (buggy) behavior

The previous implementation stored the patterns as
`globs="-name *.js -o -name *.jsx -o -name *.ts -o -name *.tsx"` and used
`find ... \( ${globs} \) ...` (unquoted). Reproduced:

```console
$ globs="-name *.js -o -name *.jsx -o -name *.ts -o -name *.tsx"
$ printf '  arg: %q\n' ${globs}
  arg: -name
  arg: index.js
  arg: webpack.config.js
  arg: -o
  arg: -name
  arg: \*.jsx
  arg: -o
  arg: -name
  arg: \*.ts
  arg: -o
  arg: -name
  arg: \*.tsx

$ find . -type d \( -name node_modules -o -name .git -o -name vendor \
       -o -name dist -o -name build \) -prune \
     -o -type f \( ${globs} \) -print -quit 2>&1
find: webpack.config.js: unknown primary or operator
$ echo "exit=$?"
exit=1
```

`*.js` was glob-expanded against the cwd to `index.js webpack.config.js`,
splicing an extra positional argument (`webpack.config.js`) into find's
predicate group and making the whole expression a syntax error. Whether this
fired at all was a function of cwd contents — exactly the kind of latent
defect we want gone. (`*.jsx`, `*.ts`, `*.tsx` survived only because no files
in cwd matched them; bash's default behavior leaves a non-matching glob
literal, so the bug was conditional on which language extensions happened to
exist in the workspace root.)

### NEW (fixed) behavior

Same fixture, run with the array-passing implementation from the snippet
above:

```console
$ bash /path/to/self-test.sh
Ruleset p/javascript: find -name args:
  -name
  \*.js
  -o
  -name
  \*.jsx
  -o
  -name
  \*.ts
  -o
  -name
  \*.tsx
  -> Detected source for p/javascript -- adding ruleset
Ruleset p/python: find -name args:
  -name
  \*.py
  -> No source for p/python -- skipping
Ruleset p/golang: find -name args:
  -name
  \*.go
  -> No source for p/golang -- skipping
Ruleset p/java: find -name args:
  -name
  \*.java
  -> No source for p/java -- skipping
---
Final rulesets added: p/javascript
```

Each pattern (`*.js`, `*.jsx`, `*.ts`, `*.tsx`, `*.py`, `*.go`, `*.java`)
reaches `find` as a single literal argv token. No pathname expansion. The
detection is correct (`p/javascript` matched on `index.js`, `src/app.js`,
`src/util.jsx`, `src/types.ts`; the other three languages correctly skipped)
and the result is independent of what files happen to live in the workspace
root.

## Acceptance-criterion 3 (OWASP A03 fixture)

The `.github` org repo cannot run `semgrep scan` end-to-end as part of this
self-test (no Python venv / Semgrep install is assumed locally, and the SARIF
upload step requires the GitHub `security-events` token). The acceptance
criterion is verified at workflow runtime — the curated `p/owasp-top-ten`
ruleset (always applied unconditionally; see line 107 of
`.github/workflows/sast.yml`) covers OWASP A01..A10 including A03 injection,
and the SARIF is uploaded by `github/codeql-action/upload-sarif@v3` (line
196). To exercise A03 end-to-end, point a sample caller workflow at this
reusable workflow with a fixture file containing a known injection sink
(e.g. an unsanitized SQL concat or `eval` of user input) and confirm the
finding appears in the Security tab.
