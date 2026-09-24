#!/usr/bin/env python3
"""Static guard for the QML files in this mod.

Catches the bug class the behavioral test cannot see: an ASSIGNMENT to a
`root.<name>` that the file never declares. QML reports that as
`Cannot assign to non-existent property "<name>"` at runtime only, and only
when the code path that assigns it actually runs -- so a callback the test
never exercises (a Process's onExited) hides it completely.

Assignment-only on purpose: reads of inherited members (BarPopup's open/close
on the card) are legal and would false-positive, while an assignment to an
inherited property is not a pattern this mod uses.

Usage: check-root-refs.py <file.qml> [<file.qml> ...]
Exit 0 = every assignment target is declared; 1 = at least one is not.
"""

import re
import sys

DECL = re.compile(r"^\s*(?:readonly\s+|required\s+|default\s+)*property\s+[\w.]+\s+(\w+)", re.M)
FUNC = re.compile(r"^\s*function\s+(\w+)\s*\(", re.M)
ASSIGN = re.compile(r"\broot\.(\w+)\s*(?:\+\+|--|[-+*/]?=(?!=))")

# JS/JS-extension builtins that may legitimately appear on a QObject.
ALLOWED = {"toString", "valueOf"}


def check(path):
    src = open(path, encoding="utf-8").read()
    declared = set(DECL.findall(src)) | set(FUNC.findall(src))
    bad = []
    for m in ASSIGN.finditer(src):
        name = m.group(1)
        if name in declared or name in ALLOWED:
            continue
        line = src[: m.start()].count("\n") + 1
        bad.append((line, name))
    return declared, bad


def main(argv):
    if len(argv) < 2:
        print("usage: check-root-refs.py <file.qml> [...]", file=sys.stderr)
        return 2
    failures = 0
    for path in argv[1:]:
        declared, bad = check(path)
        name = path.split("/")[-1]
        if bad:
            failures += len(bad)
            for line, prop in bad:
                print(f"FAIL {name}:{line}: assigns root.{prop}, which the file does not declare")
        else:
            print(f"PASS {name}: {len(declared)} declarations, every root.<name> assignment resolves")
    print("RESULT: ALL PASS" if failures == 0 else f"RESULT: {failures} FAILURE(S)")
    return 0 if failures == 0 else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
