# mise toolchain-compliance decision for one repo (org CI audit).
#
# Pure function: no network, no shell. `scripts/org-ci-audit.sh` gathers the
# facts (git tree + parsed mise config) and pipes them through here, so the
# judgment call — "is this repo out of compliance, or does it simply have
# nothing for mise to manage?" — is testable without hitting the API.
#
# INPUT (one JSON object on stdin):
#   { repo:       "Lumen-BI",
#     truncated:  false,          # git tree came back truncated (facts unusable)
#     paths:      ["mise.toml", "package.json", ...],
#     mise_tools: ["node", "php"] # keys of the config's [tools] table
#   }
#
# OUTPUT:
#   { state:     "ok"|"partial"|"missing"|"na"|"unknown",
#     config:    "mise.toml"|null,
#     detected:  [{tool, evidence}],   # ecosystems mise could pin
#     unmanaged: ["node"]              # detected, but absent from [tools]
#   }
#
# THE POINT OF `na`: most of the org is docs, PowerShell, or markdown with no
# language runtime at all. A repo with nothing for mise to manage is NOT out of
# compliance and must never appear in the gap list — otherwise the dashboard
# cries wolf and stops being read. `missing`/`partial` are reserved for repos
# that demonstrably have a runtime (a `package.json`, a `go.mod`) that nothing
# is pinning.

# Root-level config files mise actually loads. `.tool-versions` counts: mise
# reads asdf's format natively, so a repo pinning that way is not unmanaged.
def CONFIGS: [
  "mise.toml", ".mise.toml", "mise/config.toml", ".mise/config.toml",
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

# Marker suffix -> tool, for ecosystems identified by file extension.
# Where several markers prove the same ecosystem, cite the one a human would
# open. "unpinned node, see package-lock.json" reads like a tooling artifact;
# "see package.json" reads like the actual claim.
def PRIMARY_MARKERS: [
  "package.json", "composer.json", "pyproject.toml", "requirements.txt",
  "go.mod", "Cargo.toml", "Gemfile", "pom.xml", "deno.json", "global.json"
];

def EXT_MARKERS: [
  {suffix: ".tf",     tool: "terraform"},
  {suffix: ".csproj", tool: "dotnet"},
  {suffix: ".fsproj", tool: "dotnet"}
];

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
| ($paths | candidate_paths) as $cands
| ([CONFIGS[] as $c | $paths[] | select(. == $c)] | first) as $config
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
| ([$detected[].tool] | unique - $tools) as $unmanaged
| {
    repo: $in.repo,
    config: ($config // null),
    detected: $detected,
    unmanaged: $unmanaged,
    state: (
      if ($in.truncated // false) then "unknown"
      elif $config == null then (if ($detected | length) == 0 then "na" else "missing" end)
      elif ($unmanaged | length) > 0 then "partial"
      else "ok"
      end
    )
  }
