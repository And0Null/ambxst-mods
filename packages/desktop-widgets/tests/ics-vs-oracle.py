#!/usr/bin/env python3
"""Cross-checks the SHIPPED ics.js against an independent implementation.

tests/ics-cases.js proves the parser against hand-written expectations on synthetic
input. This proves it on a realistic fixture against a DIFFERENT recurrence engine
(python-dateutil, via tests/expected-days.py), which is what catches a whole class of
error the hand-written suite cannot: both implementations being wrong the same way.

    TZ=America/Bogota python3 tests/ics-vs-oracle.py [file.ics] [from] [to]

Exits non-zero and prints the day-by-day difference when the two disagree.
"""

import importlib.util
import json
import os
import subprocess
import sys
from datetime import date, timedelta

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

spec = importlib.util.spec_from_file_location("oracle", os.path.join(HERE, "expected-days.py"))
assert spec is not None and spec.loader is not None, "tests/expected-days.py is missing"
oracle = importlib.util.module_from_spec(spec)
spec.loader.exec_module(oracle)


def oracle_days(path, frm, to):
    """{day: [titles]} from the independent reader + dateutil."""
    days = {}
    day = frm
    while day <= to:
        hits = []
        for ev in oracle.events(path):
            for occ, occ_end, _ in oracle.occurrences(ev):
                last = (occ_end - timedelta(microseconds=1)).date()
                if occ.date() <= day <= last:
                    hits.append(ev.get("summary", "?"))
        if hits:
            days[day.isoformat()] = sorted(hits)
        day += timedelta(days=1)
    return days


def js_days(path, frm, to):
    env = dict(os.environ, TZ="America/Bogota")
    out = subprocess.run(
        ["node", os.path.join(HERE, "ics-days.js"), path, frm.isoformat(), to.isoformat()],
        capture_output=True, text=True, env=env, check=True,
    )
    return json.loads(out.stdout)["days"]


def main():
    path = sys.argv[1] if len(sys.argv) > 1 else os.path.join(HERE, "fixtures", "calendar-sample.ics")
    frm = date.fromisoformat(sys.argv[2]) if len(sys.argv) > 2 else date.today()
    to = date.fromisoformat(sys.argv[3]) if len(sys.argv) > 3 else frm + timedelta(days=20)

    a, b = oracle_days(path, frm, to), js_days(path, frm, to)
    print(f"oracle (python + dateutil): {len(a)} days with events, {sum(len(v) for v in a.values())} entries")
    print(f"ics.js (shipped JS):        {len(b)} days with events, {sum(len(v) for v in b.values())} entries")

    bad = 0
    for day in sorted(set(a) | set(b)):
        if a.get(day) != b.get(day):
            bad += 1
            print(f"  DIFF {day}: oracle={a.get(day)} ics.js={b.get(day)}")
    if bad:
        print(f"RESULTADO: FAIL — {bad} dia(s) distinto(s)")
        return 1
    print("RESULTADO: PASS — los dos coinciden dia por dia")
    return 0


if __name__ == "__main__":
    sys.exit(main())
