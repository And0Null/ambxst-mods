#!/usr/bin/env python3
"""Static guards for this mod's QML. No runtime, no environment needed.

Two bug classes that a behavioral test cannot see, both found the hard way:

1. ASSIGNMENT to a `root.<name>` the file never declares. QML only reports it
   as `Cannot assign to non-existent property "<name>"` at runtime, and only
   when the assigning code path runs -- so a callback the test never exercises
   (a Process's `onExited`) hides it completely.
   Assignment-only on purpose: reads of inherited members (the card's
   `root.open()`/`root.close()` from `BarPopup`) are legal.

2. `sh -c "exec <shell builtin> ..."`. `exec` replaces the process image, so it
   can only run an external file: `exec command -v mise` dies with
   `exec: command: not found` (exit 127). A probe built that way never
   succeeds, so the source reads as "not installed" and the card shows a false
   green check.

Usage: check-static.py <file.qml> [<file.qml> ...]
Exit 0 = clean; 1 = at least one finding.
"""

import re
import sys

DECL = re.compile(r"^\s*(?:readonly\s+|required\s+|default\s+)*property\s+[\w.]+\s+(\w+)", re.M)
FUNC = re.compile(r"^\s*function\s+(\w+)\s*\(", re.M)
ASSIGN = re.compile(r"\broot\.(\w+)\s*(?:\+\+|--|[-+*/]?=(?!=))")
STRING = re.compile(r'"((?:[^"\\]|\\.)*)"')
EXEC = re.compile(r"(?:^|[;&|]\s*|\(\s*)exec\s+([^\s;&|()]+)")

# Builtins of bash/dash: `exec <name>` cannot resolve any of them.
BUILTINS = {
    ".", ":", "[", "alias", "bg", "bind", "break", "builtin", "caller", "cd",
    "command", "compgen", "complete", "continue", "declare", "dirs", "disown",
    "echo", "enable", "eval", "exec", "exit", "export", "false", "fc", "fg",
    "getopts", "hash", "help", "history", "jobs", "kill", "let", "local",
    "logout", "mapfile", "popd", "printf", "pushd", "pwd", "read", "readarray",
    "return", "set", "shift", "shopt", "source", "suspend", "test", "times",
    "trap", "true", "type", "ulimit", "umask", "unalias", "unset", "wait",
}

# JS/JS-extension builtins that may legitimately appear on a QObject.
ALLOWED = {"toString", "valueOf"}


def line_of(src, pos):
    return src[:pos].count("\n") + 1


def check_root_assignments(src):
    declared = set(DECL.findall(src)) | set(FUNC.findall(src))
    findings = []
    for m in ASSIGN.finditer(src):
        if m.group(1) not in declared and m.group(1) not in ALLOWED:
            findings.append(
                (line_of(src, m.start()),
                 f"assigns root.{m.group(1)}, which the file does not declare")
            )
    return declared, findings


def check_exec_builtins(src):
    findings = []
    for lit in STRING.finditer(src):
        for m in EXEC.finditer(lit.group(1)):
            if m.group(1) in BUILTINS:
                findings.append(
                    (line_of(src, lit.start()),
                     f'shell command "exec {m.group(1)} ..." runs a shell builtin, '
                     f'which exec cannot do (exit 127)')
                )
    return findings


def main(argv):
    if len(argv) < 2:
        print("usage: check-static.py <file.qml> [...]", file=sys.stderr)
        return 2
    failures = 0
    for path in argv[1:]:
        src = open(path, encoding="utf-8").read()
        name = path.split("/")[-1]
        declared, findings = check_root_assignments(src)
        findings += check_exec_builtins(src)
        if findings:
            failures += len(findings)
            for line, msg in sorted(findings):
                print(f"FAIL {name}:{line}: {msg}")
        else:
            print(f"PASS {name}: {len(declared)} declarations, no undeclared root assignment, no exec-builtin probe")
    print("RESULT: ALL PASS" if failures == 0 else f"RESULT: {failures} FAILURE(S)")
    return 0 if failures == 0 else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
