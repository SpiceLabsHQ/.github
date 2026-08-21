#!/usr/bin/env python3
"""Edit a Renovate config in place, touching ONLY the part being changed and
leaving every other byte of the file untouched (DEV-1178, DEV-1182).

WHY NOT jq: jq re-renders the whole document in its own style, expanding every
array to multi-line. Prettier keeps short arrays inline, so a jq round-trip
rewrites lines the caller never meant to touch and fails `prettier --check` in
any repo that lints JSON — observed on SpiceLabsHQ/Atelier#262 and Lumen-BI#382.
It also made the diff dishonest: one semantic line became sixteen changed ones.

So jq still READS these configs (computing state, reporting enabledManagers);
this is what WRITES them.

Reads the original config on stdin, writes the edited config to stdout.
Exits 2 if the input is not parseable JSON — callers already route json5 and
commented configs to manual handling.

    renovate-extends-edit.py <preset-ref>      # add the preset to `extends`
    renovate-extends-edit.py --remove-key KEY  # delete a top-level key
"""

import json
import re
import sys

# `extends` entries the preset already provides, dropped when we rewrite so the
# config does not invite the "which one wins?" question this effort exists to
# remove.
REDUNDANT = ("config:recommended",)

OPENERS = {"[": "]", "{": "}"}


def find_value_span(text, start, brackets_only=True):
    """Return (start, end) of the JSON value beginning at or after `start`.

    Scans with string awareness so a bracket or comma inside a string literal —
    for example in a `matchPackageNames` glob or a versioning regex — cannot be
    mistaken for structure.
    """
    i = start
    while i < len(text) and text[i].isspace():
        i += 1
    if i >= len(text):
        return None

    if text[i] in OPENERS:
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
            elif ch in OPENERS:
                depth += 1
            elif ch in OPENERS.values():
                depth -= 1
                if depth == 0:
                    return (i, j + 1)
        return None

    if brackets_only:
        return None  # not an array/object value; refuse rather than guess

    # A scalar: run to the next structural comma or closing brace.
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
        elif ch in (",", "}"):
            # Trim trailing whitespace: the scan stops ON the delimiter, so a
            # value at the end of a line would otherwise carry the newline
            # before the closing brace into the removed span.
            k = j
            while k > i and text[k - 1].isspace():
                k -= 1
            return (i, k)
    return None


def render(entries, multiline, indent):
    """Render an extends array in the style the original used."""
    if not multiline:
        return "[" + ", ".join(json.dumps(e) for e in entries) + "]"
    inner = indent + "  "
    body = (",\n").join(inner + json.dumps(e) for e in entries)
    return "[\n" + body + "\n" + indent + "]"


def remove_key(text, key):
    """Splice out a top-level key, its value, and the adjoining comma.

    Which comma is swallowed depends on position: a trailing member takes the
    comma BEFORE it, any other member takes the comma after. Getting this wrong
    produces either a dangling comma or a missing one, so both cases are covered
    by fixtures.
    """
    m = re.search(r'"%s"\s*:\s*' % re.escape(key), text)
    if not m:
        return text  # nothing to do; caller treats this as a no-op

    span = find_value_span(text, m.end(), brackets_only=False)
    if span is None:
        return None
    start, end = m.start(), span[1]

    j = end
    while j < len(text) and text[j] in " \t":
        j += 1
    if j < len(text) and text[j] == ",":
        # Not the last member: take the comma after, plus the newline and indent
        # that preceded this key so no blank line is left behind.
        end = j + 1
        line_start = text.rfind("\n", 0, start)
        if line_start != -1 and text[line_start + 1 : start].strip() == "":
            start = line_start
    else:
        # Last member: take the comma before it, and everything between.
        k = start - 1
        while k >= 0 and text[k] in " \t\n":
            k -= 1
        if k >= 0 and text[k] == ",":
            start = k
        else:
            # The ONLY member: there is no comma to absorb, so take the newline
            # and indent before it instead. Without this the object is left
            # holding a bare whitespace line — valid JSON, so the re-parse guard
            # below passes it, but exactly the shape `prettier --check` rejects,
            # which is the failure this tool exists to prevent.
            line_start = text.rfind("\n", 0, start)
            if line_start != -1 and text[line_start + 1 : start].strip() == "":
                start = line_start

    result = text[:start] + text[end:]

    # Removing the last remaining key leaves `{\n}`, which still fails
    # `prettier --check`. An empty object has exactly one correct rendering, so
    # collapse it rather than emit something this tool exists to prevent.
    try:
        if json.loads(result) == {}:
            return "{}"
    except ValueError:
        pass
    return result


def add_preset(text, preset):
    try:
        doc = json.loads(text)
    except ValueError:
        sys.stderr.write("input is not parseable JSON\n")
        return None
    if not isinstance(doc, dict):
        sys.stderr.write("input is not a JSON object\n")
        return None

    current = doc.get("extends") or []
    if not isinstance(current, list):
        sys.stderr.write("`extends` is not an array\n")
        return None

    entries = [preset] + [e for e in current if e != preset and e not in REDUNDANT]

    key = re.search(r'"extends"\s*:\s*', text)
    if key:
        span = find_value_span(text, key.end())
        if span is None:
            sys.stderr.write("could not locate the extends array\n")
            return None
        lo, hi = span
        original = text[lo:hi]
        # Indentation of the line the key sits on, so a multi-line array keeps
        # its shape instead of being re-indented.
        line_start = text.rfind("\n", 0, key.start()) + 1
        indent = re.match(r"[ \t]*", text[line_start:]).group(0)
        return text[:lo] + render(entries, "\n" in original, indent) + text[hi:]

    # No `extends` key at all: insert one as the first member, matching the
    # indentation the file already uses for its keys.
    brace = text.find("{")
    if brace == -1:
        sys.stderr.write("no JSON object found\n")
        return None
    existing_key = re.search(r'\n([ \t]*)"', text[brace:])
    indent = existing_key.group(1) if existing_key else "  "
    insertion = "\n" + indent + '"extends": ' + render(entries, False, indent)
    rest = text[brace + 1 :]
    if re.match(r"\s*\}", rest):
        return text[: brace + 1] + insertion + "\n" + rest.lstrip()
    return text[: brace + 1] + insertion + "," + rest


def main():
    text = sys.stdin.read()

    if sys.argv[1] == "--remove-key":
        try:
            json.loads(text)
        except ValueError:
            sys.stderr.write("input is not parseable JSON\n")
            return 2
        out = remove_key(text, sys.argv[2])
        if out is None:
            sys.stderr.write("could not locate the key's value\n")
            return 2
        # The result must still be valid JSON — a comma handled wrongly would
        # otherwise ship a broken config to 9 repos.
        try:
            json.loads(out)
        except ValueError:
            sys.stderr.write("removal produced invalid JSON; refusing\n")
            return 2
        sys.stdout.write(out)
        return 0

    out = add_preset(text, sys.argv[1])
    if out is None:
        return 2
    sys.stdout.write(out)
    return 0


if __name__ == "__main__":
    sys.exit(main())
