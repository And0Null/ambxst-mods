#!/usr/bin/env python3
"""Independent oracle for the ICS parser: what days have events, and which.

This is a SECOND implementation, on purpose. It reads an .ics with its own small
reader and expands recurrences with python-dateutil (a different recurrence
engine than the JavaScript one in overlays/.../ics.js), so comparing the two
catches the errors a self-consistent test suite cannot: the JS tests carry
expectations written by hand for synthetic input, this one runs over a realistic
Google-shaped fixture and says which LOCAL days carry events.

    TZ=America/Bogota python3 tests/expected-days.py [file.ics] [from] [to]

Defaults to tests/fixtures/calendar-sample.ics, from today, for 21 days.
Prints one line per day that has events, then the agenda order.
"""

import os
import sys
from datetime import date, datetime, timedelta, timezone

from dateutil.rrule import rrulestr

LOCAL = timezone(timedelta(hours=-5))  # America/Bogota has no DST


def unfold(text):
    return text.replace("\r\n", "\n").replace("\n ", "").replace("\n\t", "").split("\n")


def unescape(value):
    out, i = [], 0
    while i < len(value):
        if value[i] == "\\" and i + 1 < len(value):
            nxt = value[i + 1]
            out.append({"n": "\n", "N": "\n", ",": ",", ";": ";", "\\": "\\"}.get(nxt, nxt))
            i += 2
        else:
            out.append(value[i])
            i += 1
    return "".join(out)


def split_prop(line):
    # NAME;PARAM=..;PARAM=..:VALUE
    head, _, value = line.partition(":")
    parts = head.split(";")
    params = {}
    for p in parts[1:]:
        k, _, v = p.partition("=")
        params[k.upper()] = v
    return parts[0].upper(), params, value


def parse_dt(value, params, all_day_hint=False):
    """-> (datetime, all_day)"""
    if params.get("VALUE") == "DATE" or (len(value) == 8 and value.isdigit()):
        return datetime.strptime(value[:8], "%Y%m%d").replace(tzinfo=LOCAL), True
    fmt = "%Y%m%dT%H%M%S"
    dt = datetime.strptime(value[:15], fmt)
    if value.endswith("Z"):
        return dt.replace(tzinfo=timezone.utc).astimezone(LOCAL), False
    return dt.replace(tzinfo=LOCAL), all_day_hint


def parse_duration(value):
    # P1D / P2W / PT1H30M / PT45M
    import re

    m = re.match(r"P(?:(\d+)W)?(?:(\d+)D)?(?:T(?:(\d+)H)?(?:(\d+)M)?)?$", value)
    if not m:
        return None
    w, d, h, mi = (int(x) if x else 0 for x in m.groups())
    return timedelta(weeks=w, days=d, hours=h, minutes=mi)


def events(path):
    lines = unfold(open(path, encoding="utf-8").read())
    out: list = []
    cur: dict = {}
    in_vevent = False
    skip_depth = 0
    for line in lines:
        if line == "BEGIN:VEVENT":
            in_vevent, cur, skip_depth = True, {"exdates": [], "rdates": []}, 0
            continue
        if line.startswith("BEGIN:") and in_vevent:
            skip_depth += 1  # VALARM and friends
            continue
        if line.startswith("END:") and in_vevent:
            if line == "END:VEVENT":
                out.append(cur)
                in_vevent = False
            else:
                skip_depth -= 1
            continue
        if not in_vevent or skip_depth:
            continue
        name, params, value = split_prop(line)
        if name == "DTSTART":
            cur["start"], cur["all_day"] = parse_dt(value, params)
        elif name == "DTEND":
            cur["end"] = parse_dt(value, params)[0]
        elif name == "DURATION":
            cur["duration"] = parse_duration(value)
        elif name == "RRULE":
            cur["rrule"] = value
        elif name == "EXDATE":
            for chunk in value.split(","):
                cur["exdates"].append(parse_dt(chunk, params)[0])
        elif name == "RDATE":
            for chunk in value.split(","):
                cur["rdates"].append(parse_dt(chunk, params)[0])
        elif name == "SUMMARY":
            cur["summary"] = unescape(value)
        elif name == "UID":
            cur["uid"] = value
    return out


def occurrences(ev):
    start, end = ev["start"], ev.get("end")
    all_day = ev.get("all_day", False)
    if end is None:
        end = start + (ev.get("duration") or (timedelta(days=1) if all_day else timedelta(hours=1)))
    if "rrule" not in ev:
        return [(start, end, False)]
    rule = rrulestr(ev["rrule"], dtstart=start)
    ex = set(ev["exdates"])
    out = []
    for occ in rule:
        if occ in ex:
            continue
        out.append((occ, occ + (end - start), True))
    for extra in ev["rdates"]:
        out.append((extra, extra + (end - start), True))
    return out


def main():
    path = sys.argv[1] if len(sys.argv) > 1 else os.path.join(
        os.path.dirname(__file__), "fixtures", "calendar-sample.ics"
    )
    today = date.today()
    frm = date.fromisoformat(sys.argv[2]) if len(sys.argv) > 2 else today
    to = date.fromisoformat(sys.argv[3]) if len(sys.argv) > 3 else frm + timedelta(days=20)

    print(f"# oracle over {os.path.basename(path)}: {frm} .. {to} (TZ={os.environ.get('TZ')})")
    day = frm
    agenda = []
    while day <= to:
        hits = []
        for ev in events(path):
            for occ, occ_end, _ in occurrences(ev):
                last = (occ_end - timedelta(microseconds=1)).date()
                if occ.date() <= day <= last:
                    hits.append(ev.get("summary", "?"))
        if hits:
            print(f"{day} {'(today)' if day == today else '        '} {len(hits)}x  " + " | ".join(sorted(hits)))
        agenda.append((day, hits))
        day += timedelta(days=1)

    print("\n# agenda order from the first day with events:")
    for day, hits in agenda:
        for title in sorted(hits):
            print(f"  {day} {title}")


if __name__ == "__main__":
    main()
