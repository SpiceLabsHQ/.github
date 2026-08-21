#!/usr/bin/env python3
"""Add the shared org preset to a Renovate config's `extends`, editing ONLY that
value and leaving every other byte of the file untouched (DEV-1178).

WHY NOT jq: jq re-renders the whole document in its own style, expanding every
array to multi-line. Prettier keeps short arrays inline, so a jq round-trip
rewrites lines the sweep never meant to touch and fails `prettier --check` in any
repo that lints JSON — observed on SpiceLabsHQ/Atelier#262 and Lumen-BI#382. It
also made the diff dishonest: one semantic line became sixteen changed ones.

So jq still READS these configs (computing state, reporting enabledManagers);
this is what WRITES them.

Reads the original config on stdin, writes the edited config to stdout.
Exits 2 if the input is not parseable JSON — callers already route json5 and
commented configs to manual handling.

    renovate-extends-edit.py <preset-ref>
"""

import json
import re
import sys

# `extends` entries the preset already provides, dropped when we rewrite so the
# config does not invite the "which one wins?" question this effort exists to
# remove.
REDUNDANT = ("config:recommended",)


def find_value_span(text, start):
    """Return (start, end) of the bracketed value beginning at or after `start`.

    Scans with string awareness so a `[` or `]` inside a string literal — for
    example in a `matchPackageNames` glob or a versioning regex — cannot be
    mistaken for structure.
    """
    i = start
    while i < len(text) and text[i] not in "[":
        if not text[i].isspace():
            return None  # not an array value; refuse rather than guess
        i += 1
    if i >= len(text):
        return None

    depth = 0
    in_string = False
    escaped = False
    for j in range(i, len(text)):
        ch = text[j]
        if in_string:
            if escaped:
                escaped = False
            elif ch == "\\":
                escaped = True
            elif ch == '"':
                in_string = False
            continue
        if ch == '"':
            in_string = True
        elif ch == "[":
            depth += 1
        elif ch == "]":
            depth -= 1
            if depth == 0:
                return (i, j + 1)
    return None


def render(entries, multiline, indent):
    """Render an extends array in the style the original used."""
    if not multiline:
        return "[" + ", ".join(json.dumps(e) for e in entries) + "]"
    inner = indent + "  "
    body = (",\n").join(inner + json.dumps(e) for e in entries)
    return "[\n" + body + "\n" + indent + "]"


def main():
    preset = sys.argv[1]
    text = sys.stdin.read()

    try:
        doc = json.loads(text)
    except ValueError:
        sys.stderr.write("input is not parseable JSON\n")
        return 2
    if not isinstance(doc, dict):
        sys.stderr.write("input is not a JSON object\n")
        return 2

    current = doc.get("extends") or []
    if not isinstance(current, list):
        sys.stderr.write("`extends` is not an array\n")
        return 2

    entries = [preset] + [e for e in current if e != preset and e not in REDUNDANT]

    key = re.search(r'"extends"\s*:\s*', text)
    if key:
        span = find_value_span(text, key.end())
        if span is None:
            sys.stderr.write("could not locate the extends array\n")
            return 2
        lo, hi = span
        original = text[lo:hi]
        # Indentation of the line the key sits on, so a multi-line array keeps
        # its shape instead of being re-indented.
        line_start = text.rfind("\n", 0, key.start()) + 1
        indent = re.match(r"[ \t]*", text[line_start:]).group(0)
        sys.stdout.write(text[:lo] + render(entries, "\n" in original, indent) + text[hi:])
        return 0

    # No `extends` key at all: insert one as the first member, matching the
    # indentation the file already uses for its keys.
    brace = text.find("{")
    if brace == -1:
        sys.stderr.write("no JSON object found\n")
        return 2
    existing_key = re.search(r'\n([ \t]*)"', text[brace:])
    indent = existing_key.group(1) if existing_key else "  "
    insertion = "\n" + indent + '"extends": ' + render(entries, False, indent)
    rest = text[brace + 1 :]
    # A comma is only needed when another key follows.
    if re.match(r"\s*\}", rest):
        sys.stdout.write(text[: brace + 1] + insertion + "\n" + text[brace + 1 :].lstrip())
    else:
        sys.stdout.write(text[: brace + 1] + insertion + "," + rest)
    return 0


if __name__ == "__main__":
    sys.exit(main())
