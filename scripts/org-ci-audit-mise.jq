# Development-environment compliance for one repo (org CI audit).
#
# Scores a repo against the auditable rules of the Eng-Cookbook standard
# `standards/development-environment.md` (ADR-0024). That standard's Enforcement
# section names rules 1, 2, 3, 4, 5, 6, 8 and 9 as "Audited, not blocked" — this
# audit is that audit, and this file is where the judgment lives.
#
# Rules checked here (DEV-1177):
#   1. Toolchain pinned in a committed root `mise.toml` (MUST) — both that a
#      config exists and covers every runtime, and that it is the canonical file
#   2. No `.devcontainer/` (MUST) — unconditional, so it applies even to a repo
#      with no language runtime at all
#   4. A `setup` task where a checkout needs a dependency install (MUST)
#
# Not checked: rules 5 and 6 (CI and Dockerfile read `mise.toml`) need content
# inspection of workflows and Dockerfiles; rule 3 is a SHOULD; rules 8 and 9
# (no services / no secrets in `mise.toml`) need judgment about what a tool or
# an env value means. See DEV-1177 "Out of scope".
#
# Pure function: no network, no shell. `scripts/org-ci-audit.sh` gathers the
# facts and pipes them through here, so the judgment is testable without the API.
#
# INPUT (one JSON object on stdin):
#   { repo:       "Lumen-BI",
#     truncated:  false,          # git tree came back truncated (facts unusable)
#     paths:      ["mise.toml", "package.json", ...],
#     mise_tools: ["node", "php"],  # keys of the config's [tools] table
#     mise_tasks: ["setup", "test"] # names of the config's [tasks] tables
#   }
#
# OUTPUT:
#   { state:      "ok"|"partial"|"missing"|"na"|"unknown",
#     config:     "mise.toml"|null,
#     canonical:  true,               # config is the root `mise.toml` rule 1 names
#     detected:   [{tool, evidence}], # ecosystems mise could pin
#     unmanaged:  ["node"],           # detected, but absent from [tools]
#     devcontainer: ".devcontainer/devcontainer.json"|null,
#     violations: [{rule, label, text}],  # most severe first
#     headline:   "node"|"devcontainer"|null  # short label for the table cell
#   }
#
# THE POINT OF `na`: most of the org is docs, PowerShell, or markdown with no
# language runtime. A repo with nothing for mise to manage and no devcontainer is
# NOT out of compliance and must never appear in the gap list — otherwise the
# dashboard cries wolf and stops being read. Violations are only ever reported
# against evidence: a `package.json`, a `go.mod`, a `.devcontainer/`.

# Config files mise loads. Only the root `mise.toml` satisfies rule 1's "in
# `mise.toml` at the repository root", but the others are still recognised: a
# repo that pinned its toolchain in `.tool-versions` has a location problem, not
# a missing toolchain, and reporting it as the latter would be wrong.
def CANONICAL_CONFIG: "mise.toml";
def CONFIGS: [
  CANONICAL_CONFIG, ".mise.toml", "mise/config.toml", ".mise/config.toml",
  ".config/mise.toml", ".config/mise/config.toml", ".tool-versions"
];

# Marker file -> the mise tool that would pin it. Exact basenames.
def NAME_MARKERS: {
  "package.json": "node", "package-lock.json": "node",
  "pnpm-lock.yaml": "node", "yarn.lock": "node",
  ".nvmrc": "node", ".node-version": "node",
  "composer.json": "php",
  "pyproject.toml": "python", "requirements.txt": "python",
  "setup.py": "python", "Pipfile": "python", ".python-version": "python",
  "go.mod": "go", "Gopkg.toml": "go",
  "Cargo.toml": "rust",
  "Gemfile": "ruby", ".ruby-version": "ruby",
  "pom.xml": "java", "build.gradle": "java", "build.gradle.kts": "java",
  "deno.json": "deno", "deno.jsonc": "deno",
  "global.json": "dotnet"
};

# Where several markers prove the same ecosystem, cite the one a human would
# open. "unpinned node, see package-lock.json" reads like a tooling artifact;
# "see package.json" reads like the actual claim.
def PRIMARY_MARKERS: [
  "package.json", "composer.json", "pyproject.toml", "requirements.txt",
  "go.mod", "Cargo.toml", "Gemfile", "pom.xml", "deno.json", "global.json"
];

# Marker suffix -> tool, for ecosystems identified by file extension.
def EXT_MARKERS: [
  {suffix: ".tf",     tool: "terraform"},
  {suffix: ".csproj", tool: "dotnet"},
  {suffix: ".fsproj", tool: "dotnet"}
];

# Ecosystems whose checkout genuinely does not work until dependencies are
# installed — the precondition rule 4 attaches to. Deliberately narrower than
# the full marker list: `go build` and `cargo build` fetch on demand, so a Go or
# Rust repo has no install step to name and must not be flagged for lacking one.
def INSTALL_ECOSYSTEMS: ["node", "php", "python", "ruby"];

# Directories whose contents are never evidence of this repo's own toolchain:
# vendored code, build output, and — the one that actually bites — test
# fixtures. This repo's own `scripts/test/fixtures/` and Claude-Spice-Mise's
# `tests/fake-mise` would otherwise each invent a runtime the repo doesn't have.
def DENY_DIRS: [
  "node_modules", "vendor", "venv", ".venv", "dist", "build", "out", "target",
  "third_party", "thirdparty", "testdata", "fixture", "fixtures",
  "example", "examples", "sample", "samples", "coverage", "tmp",
  ".git", ".terraform", ".claude", "__pycache__", "site-packages"
];

# mise accepts backend prefixes (`core:node`, `asdf:nodejs`) and several
# spellings of the same runtime. Normalize before comparing against detection.
def normalize_tool:
  (if test(":") then sub("^[^:]+:"; "") else . end)
  | ascii_downcase
  | {"nodejs": "node", "node.js": "node", "golang": "go", "python3": "python",
     "dotnet-core": "dotnet", "openjdk": "java", "temurin": "java",
     "opentofu": "terraform", "tofu": "terraform"}[.] // .;

# Keep only paths that are plausibly this repo's own manifest: at most two
# directories deep (so `packages/api/package.json` in a monorepo still counts),
# and with no denied directory anywhere in the path.
def candidate_paths:
  [ .[]
    | select((split("/") | length) <= 3)
    | select((split("/") | .[:-1] | any(. as $d | DENY_DIRS | index($d))) | not)
  ];

. as $in
| ($in.paths // []) as $paths
| ($in.mise_tools // [] | map(normalize_tool) | unique) as $tools
| ($in.mise_tasks // []) as $tasks
| ($paths | candidate_paths) as $cands
| ([CONFIGS[] as $c | $paths[] | select(. == $c)] | first) as $config

# Rule 2 is unconditional, so this reads the RAW path list, not the filtered
# candidates — but only at the repository root, so a devcontainer inside a test
# fixture is not mistaken for the repo's own.
| ([ $paths[]
     | select(startswith(".devcontainer/") or . == ".devcontainer.json") ]
   | first) as $devcontainer

| ( [ $cands[]
      | . as $p
      | (split("/") | last) as $base
      | ( (NAME_MARKERS[$base] // empty | {tool: ., evidence: $p}),
          (EXT_MARKERS[] | . as $m | select($base | endswith($m.suffix))
                         | {tool: $m.tool, evidence: $p}) )
    ]
    # One row per ecosystem. Evidence preference: shallowest path, then a
    # primary manifest over a lockfile, then alphabetical for stable output.
    | sort_by([ (.evidence | split("/") | length),
                (if (.evidence | split("/") | last) as $b | PRIMARY_MARKERS | index($b)
                 then 0 else 1 end),
                .evidence ])
    | group_by(.tool) | map(.[0]) | sort_by(.tool)
  ) as $detected
| ([$detected[].tool] | unique) as $ecosystems
| ($ecosystems - $tools) as $unmanaged
| ([$ecosystems[] | select(. as $e | INSTALL_ECOSYSTEMS | index($e))]) as $needs_setup

# Violations, listed most severe first. Severity order is deliberate: the cell
# shows the first one, and "no toolchain at all" must outrank "toolchain pinned
# in the wrong filename".
| ( [ ( if $config == null and ($detected | length) > 0
        then {rule: 1, label: ($unmanaged | join(", ")),
              text: "no mise config; unpinned: \($unmanaged | join(", "))"}
        else empty end ),
      ( if $config != null and ($unmanaged | length) > 0
        then {rule: 1, label: ($unmanaged | join(", ")),
              text: "`\($config)` leaves \($unmanaged | join(", ")) unpinned"}
        else empty end ),
      ( if $devcontainer != null
        then {rule: 2, label: "devcontainer",
              text: "carries `\($devcontainer | split("/") | .[0])` — rule 2 forbids it"}
        else empty end ),
      ( if $config != null and ($needs_setup | length) > 0
           and (($tasks | index("setup")) | not)
        then {rule: 4, label: "no setup task",
              text: "`\($config)` defines no `setup` task, but \($needs_setup | join(", ")) needs a dependency install"}
        else empty end ),
      ( if $config != null and $config != CANONICAL_CONFIG
        then {rule: 1, label: "config location",
              text: "toolchain is pinned in `\($config)`, not the root `\(CANONICAL_CONFIG)` rule 1 requires"}
        else empty end )
    ] ) as $violations

| {
    repo: $in.repo,
    config: ($config // null),
    canonical: ($config == CANONICAL_CONFIG),
    detected: $detected,
    unmanaged: $unmanaged,
    devcontainer: ($devcontainer // null),
    violations: $violations,
    headline: ($violations | if length > 0 then .[0].label else null end),
    state: (
      if ($in.truncated // false) then "unknown"
      elif $config == null and ($detected | length) > 0 then "missing"
      elif ($violations | length) > 0 then "partial"
      elif $config != null or ($detected | length) > 0 then "ok"
      else "na"
      end
    )
  }
