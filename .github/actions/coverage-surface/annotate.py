#!/usr/bin/env python3
"""Turn diff-cover JSON into GitHub annotations + a one-line stats summary.

Reads a diff-cover `--format json:` report (argv[1]). For every changed line
with no coverage it prints a `::warning file=,line=::` annotation to STDERR,
which GitHub renders inline in the Files-changed diff. It prints one
`percent|changed_lines|uncovered_lines` line to STDOUT for the caller to parse.

Never raises: a malformed/empty report yields `100|0|0` and no annotations, so
a coverage hiccup stays non-gating (DEV-526 / ADR-0004).
"""
import json
import sys


def main() -> int:
    try:
        with open(sys.argv[1], encoding="utf-8") as fh:
            data = json.load(fh)
    except Exception:  # noqa: BLE001 — any parse failure degrades to no-op.
        print("100|0|0")
        return 0

    changed = data.get("num_changed_lines", 0)
    uncovered = data.get("total_num_violations", 0)
    pct = data.get("total_percent_covered", 100)

    for fname, stat in sorted(data.get("src_stats", {}).items()):
        for line in stat.get("violation_lines", []):
            # One physical line — GitHub's annotation parser is line-oriented.
            print(
                f"::warning file={fname},line={line},"
                f"title=Uncovered changed line::{fname}:{line} is changed by "
                "this PR but not covered by tests.",
                file=sys.stderr,
            )

    print(f"{pct}|{changed}|{uncovered}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
