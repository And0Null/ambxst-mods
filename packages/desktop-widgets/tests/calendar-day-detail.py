#!/usr/bin/env python3
"""The day detail's two halves, checked against the real sources.

Half one is the SERVICE: three feeds (a Personal, a Work and a Family fixture) are
loaded through the same file the shell reads, and the questions the day detail depends on
are asked of `CalendarEventsService` itself:

  * the same event arriving from TWO feeds is ONE event (the merge's dedupe by UID), and
    the copy that survives is the first source's;
  * a day with events from three DIFFERENT calendars lists them all, in time order, each
    with its own calendar's colour and name;
  * two events that OVERLAP in time are both listed (the detail does not hide one);
  * two all-day events from two calendars share a day;
  * an all-day event that spans days shows on EVERY day it touches;
  * a day with nothing answers an empty list, never null;
  * the cell's dots are one per CALENDAR (capped at three), not one per event.

Half two is the WIDGET: the tiers that open the detail and what the detail draws.

The service half runs the probe with its OWN config dir: `XDG_CONFIG_HOME` points at a
temp dir whose `ambxst/` holds symlinks to every real config file EXCEPT the calendars
one, which is the harness's own (with the fixture paths). The theme, the layout and the
rest stay exactly what the user has, so the palette names in the assertions are real.

    python3 tests/calendar-day-detail.py
    python3 tests/calendar-day-detail.py --keep      # keep the probe dir
"""

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
FIXTURES = HERE / "fixtures"
MOD = HERE.parent
SERVICE = MOD / "overlays/modules/services/CalendarEventsService.qml"

# The three sources the harness loads, in file order: the FIRST one owns every UID it
# shares with a later source.
SOURCES = [
    ("Personal", "cyan", FIXTURES / "calendar-sample.ics"),
    ("Work", "green", FIXTURES / "calendar-work.ics"),
    ("Family", "magenta", FIXTURES / "calendar-family.ics"),
]

# 2026-09-24 in America/Bogota holds five events across the three calendars, two of which
# overlap in time; 09-25 two all-day ones; 09-23 an all-day plus a UTC-time one; 09-30 a
# single all-day one; 09-20 nothing at all.
DAY = "2026-09-24"
DAY_ROWS = [
    ("09:00", "Sprint planning", "green", "Work"),
    ("14:00", "Dentist", "cyan", "Personal"),
    ("14:30", "Client catch-up", "green", "Work"),
    ("16:00", "Code review", "green", "Work"),
    ("19:00", "Family dinner", "magenta", "Family"),
]

PROBE = '''import QtQuick
import Quickshell
import Quickshell.Io
import qs.modules.services

ShellRoot {
    id: root
    property var lines: []
    property int waited: 0

    Process {
        id: sink
        command: ["/usr/bin/bash", "-c", "cat > " + (Quickshell.env("DETAIL_OUT") || "/tmp/detail.out")]
        stdinEnabled: true
        // Quit once the sink has DRAINED (see calendar-menu-writes.py): a same-tick quit
        // raced it and the log came back empty while the probe had done its work.
        onExited: Qt.quit()
    }

    // The sink never started, or cat died: leave anyway, so a stuck probe cannot hang the run.
    Timer {
        id: sinkBackstop
        interval: 8000
        onTriggered: Qt.quit()
    }

    function when(ms) {
        return Qt.formatDateTime(new Date(ms), "HH:mm");
    }

    function rowsOf(key) {
        var list = CalendarEventsService.eventsOn(key);
        var out = [];
        for (var i = 0; i < list.length; i++) {
            out.push({
                at: root.when(list[i].startMs),
                to: root.when(list[i].endMs),
                title: list[i].summary,
                place: list[i].location,
                allDay: list[i].allDay,
                color: list[i].colorName,
                source: list[i].sourceName
            });
        }
        return out;
    }

    function report() {
        var events = CalendarEventsService.events;
        var copies = 0;
        var first = null;
        for (var i = 0; i < events.length; i++) {
            if (events[i].uid === "standup-001@example.com") {
                copies++;
                if (first === null)
                    first = events[i];
            }
        }
        var names = [];
        for (var s = 0; s < CalendarEventsService.sources.length; s++)
            names.push(CalendarEventsService.sources[s].name);

        root.lines.push(JSON.stringify({ kind: "loaded", sources: names,
            entries: CalendarEventsService.entries.length,
            problems: CalendarEventsService.problems }));
        root.lines.push(JSON.stringify({ kind: "merged", events: events.length,
            copies: copies,
            summary: first ? first.summary : null,
            color: first ? first.colorName : null,
            source: first ? first.sourceName : null }));
        root.lines.push(JSON.stringify({ kind: "day", key: "DAYKEY", rows: root.rowsOf("DAYKEY") }));
        root.lines.push(JSON.stringify({ kind: "day", key: "2026-09-25",
            rows: root.rowsOf("2026-09-25") }));
        root.lines.push(JSON.stringify({ kind: "day", key: "2026-09-23",
            rows: root.rowsOf("2026-09-23") }));
        root.lines.push(JSON.stringify({ kind: "day", key: "2026-09-30",
            rows: root.rowsOf("2026-09-30") }));
        root.lines.push(JSON.stringify({ kind: "day", key: "2026-09-20",
            rows: root.rowsOf("2026-09-20") }));
        var from = new Date(2026, 8, 23).getTime();
        var dots = CalendarEventsService.daysWithEvents(from, from + 4 * 86400000);
        var keys = Object.keys(dots).sort();
        var shapes = [];
        for (var k = 0; k < keys.length; k++)
            shapes.push({ key: keys[k], colors: dots[keys[k]].length,
                unique: dots[keys[k]].filter(function (c, i, a) { return a.indexOf(c) === i; }).length });
        root.lines.push(JSON.stringify({ kind: "dots", days: shapes }));
    }

    Timer {
        interval: 400
        repeat: true
        running: true
        onTriggered: {
            root.waited++;
            var ready = CalendarEventsService.loaded && CalendarEventsService.events.length > 0;
            if (!ready && root.waited < 40)
                return;
            if (!ready) {
                root.lines.push(JSON.stringify({ kind: "stuck",
                    loaded: CalendarEventsService.loaded,
                    events: CalendarEventsService.events.length,
                    problems: CalendarEventsService.problems }));
            } else {
                root.report();
            }
            running = false;
            sink.running = true;
            sink.write(root.lines.join("\\n") + "\\n");
            sink.stdinEnabled = false;
            sinkBackstop.start();
        }
    }
}
'''


UI_PROBE = '''import QtQuick
import Quickshell
import Quickshell.Io
import qs.modules.services
import qs.modules.widgets.desktopwidgets
import qs.modules.widgets.dashboard.widgets.calendar

ShellRoot {
    id: root
    property var lines: []

    Process {
        id: sink
        command: ["/usr/bin/bash", "-c", "cat > " + (Quickshell.env("DETAIL_OUT") || "/tmp/detail.out")]
        stdinEnabled: true
        // Quit once the sink has DRAINED (see calendar-menu-writes.py): a same-tick quit
        // raced it and the log came back empty while the probe had done its work.
        onExited: Qt.quit()
    }

    // The sink never started, or cat died: leave anyway, so a stuck probe cannot hang the run.
    Timer {
        id: sinkBackstop
        interval: 8000
        onTriggered: Qt.quit()
    }

    // The panel in both shapes: the month grid and the week strip. The day a cell stands
    // for is the panel's own arithmetic, asked here instead of re-derived.
    Calendar { id: monthPanel }
    Calendar { id: weekPanel; weekOnly: true }

    // The widget as the layer builds it, in the two tiers that draw the grid.
    CalendarWidget { id: weekCard; family: "compact"; width: 248; height: 48 }
    CalendarWidget { id: monthCard; family: "full"; width: 248; height: 158 }
    CalendarWidget { id: detailCard; family: "detailed"; width: 520; height: 300 }

    // The surface itself, rendered on a real screen (the first one the probe sees).
    DayDetail { id: detail; screen: Quickshell.screens[0] }

    function selectionCount(panel) {
        var n = 0;
        for (var r = 0; r < 6; r++) {
            for (var c = 0; c < 7; c++) {
                if (panel.isSelected(r, c))
                    n++;
            }
        }
        return n;
    }

    function timesOf(key) {
        DesktopWidgetsService.openDay(key);
        var out = [];
        for (var i = 0; i < detail.rows.length; i++)
            out.push(detail.timeLabel(detail.rows[i]));
        return out;
    }

    function report() {
        var sep = monthPanel.keyFor(0, 0);
        var last = monthPanel.keyFor(5, 6);

        monthPanel.selectedDayKey = "";
        var none = root.selectionCount(monthPanel);
        monthPanel.selectedDayKey = sep;
        var one = root.selectionCount(monthPanel);
        monthPanel.selectedDayKey = "1999-01-01";
        var outside = root.selectionCount(monthPanel);
        monthPanel.selectedDayKey = "";

        root.lines.push(JSON.stringify({
            kind: "panel", monthFirst: sep, monthLast: last,
            row0: [monthPanel.keyFor(0, 0), monthPanel.keyFor(0, 1), monthPanel.keyFor(0, 6)],
            weekFirst: weekPanel.keyFor(weekPanel.weekRow, 0),
            weekLast: weekPanel.keyFor(weekPanel.weekRow, 6),
            weekRow: weekPanel.weekRow, weekRows: weekPanel.gridRows,
            monthRows: monthPanel.gridRows,
            selection: { withNone: none, withOne: one, withOutside: outside },
            agendas: [weekCard.showAgenda, monthCard.showAgenda, detailCard.showAgenda],
            clicksEnabled: [weekPanel.dayClicksEnabled, monthPanel.dayClicksEnabled]
        }));

        DesktopWidgetsService.closeDay();
        var starts = [DesktopWidgetsService.detailDayKey];
        DesktopWidgetsService.openDay("2026-09-24");
        starts.push(DesktopWidgetsService.detailDayKey);
        DesktopWidgetsService.openDay("2026-09-24");     // el mismo dia: cierra
        starts.push(DesktopWidgetsService.detailDayKey);
        DesktopWidgetsService.openDay("2026-09-25");
        starts.push(DesktopWidgetsService.detailDayKey);
        DesktopWidgetsService.closeDay();
        starts.push(DesktopWidgetsService.detailDayKey);
        DesktopWidgetsService.openDay("");
        starts.push(DesktopWidgetsService.detailDayKey);
        root.lines.push(JSON.stringify({ kind: "state", sequence: starts }));

        DesktopWidgetsService.openDay("2026-09-24");
        var rows = [];
        for (var i = 0; i < detail.rows.length; i++) {
            var e = detail.rows[i];
            rows.push({ title: e.summary, time: detail.timeLabel(e), color: e.colorName,
                        source: e.sourceName, place: e.location });
        }
        root.lines.push(JSON.stringify({ kind: "detail", day: "2026-09-24",
            open: detail.open, visible: detail.visible, width: detail.implicitWidth,
            height: Math.round(detail.implicitHeight), label: detail.dayLabel("2026-09-24"),
            meta: detail.metaOf(detail.rows[detail.rows.length - 1]), rows: rows }));

        root.lines.push(JSON.stringify({ kind: "detail", day: "2026-09-25",
            label: detail.dayLabel("2026-09-25"), meta: "", open: detail.open,
            rows: [], times: root.timesOf("2026-09-25") }));

        root.lines.push(JSON.stringify({ kind: "detail", day: "2026-09-20",
            label: detail.dayLabel("2026-09-20"), meta: "", open: detail.open,
            rows: [], times: root.timesOf("2026-09-20"), empty: detail.rows.length }));

        root.lines.push(JSON.stringify({ kind: "labels",
            allDay: detail.timeLabel({ allDay: true, startMs: 0, endMs: 0 }),
            timed: detail.timeLabel({ allDay: false, startMs: 0, endMs: 3600000 }),
            timedSingle: detail.timeLabel({ allDay: false, startMs: 0, endMs: 0 }),
            place: detail.metaOf({ location: "Office", sourceName: "Work" }),
            bare: detail.metaOf({ location: "", sourceName: "" }) }));

        DesktopWidgetsService.closeDay();
        root.lines.push(JSON.stringify({ kind: "closed", open: detail.open, key: DesktopWidgetsService.detailDayKey }));
    }

    Component.onCompleted: {
        // the feeds come from the same fake config the service half uses
        var wait = 0;
        var timer = Qt.createQmlObject("import QtQuick; Timer { interval: 400; repeat: true; running: true }", root);
        timer.triggered.connect(function () {
            wait++;
            var ready = CalendarEventsService.loaded && CalendarEventsService.events.length > 0;
            if (!ready && wait < 40)
                return;
            timer.stop();
            if (!ready) {
                root.lines.push(JSON.stringify({ kind: "stuck", events: CalendarEventsService.events.length }));
            } else {
                try {
                    root.report();
                } catch (e) {
                    root.lines.push(JSON.stringify({ kind: "error", message: String(e) }));
                }
            }
            sink.running = true;
            sink.write(root.lines.join("\\n") + "\\n");
            sink.stdinEnabled = false;
            sinkBackstop.start();
        });
    }
}
'''


def fake_config(keep_dir):
    """A config dir that IS the user's, except for the calendars file the harness owns."""
    d = Path(tempfile.mkdtemp(prefix="daydetail-", dir=os.environ.get("TMPDIR", "/tmp")))
    real = Path(os.path.expanduser("~/.config/ambxst"))
    fake = d / "ambxst"
    fake.mkdir(parents=True)
    for p in sorted(real.iterdir()):
        if p.name == "desktop-widgets-calendars.json" or p.name == "desktop-widgets.json":
            continue
        os.symlink(p, fake / p.name)
    # The layout is COPIED, not linked: a probe that writes it must not touch the user's.
    shutil.copy(real / "desktop-widgets.json", fake / "desktop-widgets.json")
    (fake / "desktop-widgets-calendars.json").write_text(json.dumps({
        "sources": [{"name": n, "color": c, "path": str(p), "enabled": True}
                    for n, c, p in SOURCES]}, indent=2))
    os.chmod(fake / "desktop-widgets-calendars.json", 0o600)
    return d


def run_probe(generation, keep, probe_text=None):
    d = Path(tempfile.mkdtemp(prefix="detailprobe-", dir=os.environ.get("TMPDIR", "/tmp")))
    cfg = fake_config(d)
    (d / "probe.qml").write_text(probe_text or PROBE.replace("DAYKEY", DAY))
    os.symlink(generation / "modules", d / "modules")
    os.symlink(generation / "config", d / "config")
    out = d / "out.txt"
    env = dict(os.environ, DETAIL_OUT=str(out), XDG_CONFIG_HOME=str(cfg))
    subprocess.run(["timeout", "60", "qs", "-p", str(d / "probe.qml")],
                   capture_output=True, text=True, env=env)
    lines = (out.read_text().splitlines() if out.exists() else [])
    data = [json.loads(l) for l in lines if l.startswith("{")]
    if keep:
        print("temp kept:", d)
    else:
        shutil.rmtree(d, ignore_errors=True)
    return data


def generation_dir():
    cfg = Path(os.path.expanduser("~/.config/ambxst/mods.json"))
    return Path(os.path.expanduser("~/.local/share/ambxst/mods/generations")) / \
        json.loads(cfg.read_text())["activeGeneration"]


def check(data):
    why = []
    got = {}
    for d in data:
        got.setdefault(d["kind"], []).append(d)
    if "stuck" in got:
        why.append(f"the service never loaded its sources: {got['stuck'][0]}")
        return False, why
    loaded = got.get("loaded", [{}])[0]
    if sorted(loaded.get("sources") or []) != sorted(n for n, _, _ in SOURCES):
        why.append(f"the probe loaded {loaded.get('sources')}, not the three fixtures")
    if loaded.get("problems"):
        why.append(f"the sources reported problems: {loaded['problems']}")

    merged = got.get("merged", [{}])[0]
    want_total = 14   # 8 in the sample (a VTODO is not an event) + 4 work + 2 family - 1 shared
    if merged.get("events") != want_total:
        why.append(f"the merge holds {merged.get('events')} events, expected {want_total}")
    if merged.get("copies") != 1:
        why.append(f"the shared UID survives {merged.get('copies')} times, expected once")
    if merged.get("summary") != "Weekly team meeting":
        why.append(f"the surviving copy is {merged.get('summary')!r}, expected the first source's")
    if merged.get("source") != "Personal":
        why.append(f"the surviving copy belongs to {merged.get('source')!r}, expected Personal")

    days = {d["key"]: d["rows"] for d in got.get("day", [])}
    rows = days.get(DAY) or []
    if len(rows) != len(DAY_ROWS):
        why.append(f"{DAY} lists {len(rows)} events, expected {len(DAY_ROWS)}: "
                   + ", ".join(r.get("title", "?") for r in rows))
    else:
        for row, (want_at, want_title, want_color, want_source) in zip(rows, DAY_ROWS):
            if row["at"] != want_at or row["title"] != want_title:
                why.append(f"{DAY} row {row['at']} {row['title']!r}, expected "
                           f"{want_at} {want_title!r}")
            if row["color"] != want_color or row["source"] != want_source:
                why.append(f"{want_title!r} came from {row['color']}/{row['source']}, "
                           f"expected {want_color}/{want_source}")
    if days.get("2026-09-20") != []:
        why.append(f"a day with nothing answered {days.get('2026-09-20')!r}, expected []")
    two = days.get("2026-09-25") or []
    if len(two) != 2 or not all(r["allDay"] for r in two):
        why.append(f"2026-09-25 should hold two all-day events from two calendars, got "
                   + ", ".join(f"{r['title']}({r['allDay']})" for r in two))
    if len({r["source"] for r in two}) != 2:
        why.append("the two all-day events do not come from two different calendars")
    span = days.get("2026-09-23") or []
    if not any(r["title"] == "Day off" and r["allDay"] for r in span):
        why.append("the all-day event that starts 09-23 is missing from that day")
    if not any(r["at"] == "17:00" for r in span):
        why.append("the UTC-time event is not on 09-23 at 17:00 local")
    if len(days.get("2026-09-30") or []) != 1:
        why.append("2026-09-30 should hold the single family all-day event")

    dots = {d["key"]: d for d in got.get("dots", [{}])[0].get("days", [])}
    three = dots.get(DAY)
    if not three or three.get("unique") != 3:
        why.append(f"the cell for {DAY} shows {three and three.get('unique')} distinct colours, "
                   "expected one per calendar (three)")
    for key, d in dots.items():
        if d["colors"] > 3:
            why.append(f"the cell for {key} carries {d['colors']} dots; the cell caps at three")
    return (not why), why


def ui_check(data):
    """The panel's contract, the state machine and what the surface draws."""
    why = []
    got = {}
    for d in data:
        got.setdefault(d["kind"], []).append(d)
    if "stuck" in got:
        why.append(f"the feeds never loaded: {got['stuck'][0]}")
        return False, why
    if "error" in got:
        why.append("the probe threw: " + got["error"][0]["message"])
        return False, why
    panel = (got.get("panel") or [{}])[0]

    # the panel's own arithmetic, in both shapes
    import datetime as dt
    today = dt.date.today()
    first = today.replace(day=1)
    offset = (first.weekday() + 0) % 7          # Monday = 0, and the grid starts on Monday
    want_first = (first - dt.timedelta(days=offset)).isoformat()
    want_last = (first - dt.timedelta(days=offset) + dt.timedelta(days=41)).isoformat()
    if panel.get("monthFirst") != want_first:
        why.append(f"the month's first cell is {panel.get('monthFirst')}, expected {want_first}")
    if panel.get("monthLast") != want_last:
        why.append(f"the month's last cell is {panel.get('monthLast')}, expected {want_last}")
    monday = (today - dt.timedelta(days=today.weekday())).isoformat()
    sunday = (today - dt.timedelta(days=today.weekday()) + dt.timedelta(days=6)).isoformat()
    if panel.get("weekFirst") != monday or panel.get("weekLast") != sunday:
        why.append(f"the week tier reads {panel.get('weekFirst')}..{panel.get('weekLast')}, "
                   f"expected {monday}..{sunday}")
    if panel.get("weekRows") != 1 or panel.get("monthRows") != 6:
        why.append(f"the panels draw {panel.get('monthRows')}/{panel.get('weekRows')} rows "
                   "(month/week), expected 6 and 1")
    sel = panel.get("selection") or {}
    if sel.get("withNone") != 0:
        why.append(f"{sel.get('withNone')} cells ring with nothing selected")
    if sel.get("withOne") != 1:
        why.append(f"{sel.get('withOne')} cells ring for one selected day, expected exactly one")
    if sel.get("withOutside") != 0:
        why.append(f"{sel.get('withOutside')} cells ring for a day outside the grid")
    if panel.get("agendas") != [False, False, True]:
        why.append(f"the cards draw the agenda as {panel.get('agendas')}, expected "
                   "[week no, month no, detailed yes]")
    if not all(panel.get("clicksEnabled") or []):
        why.append("day clicks are disabled outside edit mode")

    # the state machine
    seq = (got.get("state") or [{}])[0].get("sequence") or []
    want = ["", "2026-09-24", "", "2026-09-25", "", ""]
    if seq != want:
        why.append(f"the day state goes {seq}, expected {want}")

    # the surface
    details = {d["day"]: d for d in got.get("detail", [])}
    five = details.get("2026-09-24") or {}
    rows = five.get("rows") or []
    if not five.get("open") or not five.get("visible"):
        why.append("the surface is not open/visible with a day set")
    if five.get("width") != 360:
        why.append(f"the surface is {five.get('width')} wide, expected 360")
    if len(rows) != len(DAY_ROWS):
        why.append(f"the surface lists {len(rows)} events for {DAY}, expected {len(DAY_ROWS)}")
    else:
        for row, (want_at, want_title, want_color, want_source) in zip(rows, DAY_ROWS):
            if row["title"] != want_title or row["color"] != want_color or row["source"] != want_source:
                why.append(f"the surface draws {row['title']!r}/{row['color']}/{row['source']}, "
                           f"expected {want_title!r}/{want_color}/{want_source}")
            if not row["time"].startswith(want_at):
                why.append(f"{want_title!r} is drawn at {row['time']!r}, expected to start {want_at}")
    if five.get("meta") != "Grandma's place  ·  Family":
        why.append(f"the last row's meta line is {five.get('meta')!r}, expected place and calendar")
    if (details.get("2026-09-25") or {}).get("times") != ["All day", "All day"]:
        why.append(f"the all-day day reads {(details.get('2026-09-25') or {}).get('times')}, "
                   "expected two All day rows")
    if (details.get("2026-09-20") or {}).get("empty") != 0:
        why.append("a day with nothing does not answer an empty list")
    labels = (got.get("labels") or [{}])[0]
    if labels.get("allDay") != "All day":
        why.append(f"an all-day event is labelled {labels.get('allDay')!r}")
    ranged = labels.get("timed") or ""
    if ranged.count("-") != 1 or len(ranged) != 11:
        why.append(f"two different ends are not drawn as a range: {ranged!r}")
    if labels.get("timedSingle") != ranged.split("-")[0]:
        why.append(f"an event with no real end is not drawn as its start alone: "
                   f"{labels.get('timedSingle')!r} vs {ranged!r}")
    if labels.get("place") != "Office  ·  Work":
        why.append(f"the meta line joins place and calendar as {labels.get('place')!r}")
    if labels.get("bare") != "":
        why.append(f"an event with no place and no calendar shows {labels.get('bare')!r}")

    # the day label, relative to today: never a hardcoded "Today"
    for key, d in details.items():
        got_label = d.get("label") or ""
        day = dt.date.fromisoformat(key)
        diff = (day - today).days
        want_label = {0: "Today", 1: "Tomorrow", -1: "Yesterday"}.get(diff)
        if want_label and got_label != want_label:
            why.append(f"{key} is labelled {got_label!r}, expected {want_label!r}")
        if not want_label and dt.date.fromisoformat(key).strftime("%d") not in got_label:
            why.append(f"{key} is labelled {got_label!r}, expected the date in words")
    if (got.get("closed") or [{}])[0].get("open"):
        why.append("the surface stays open after closeDay()")
    return (not why), why


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--keep", action="store_true")
    ap.add_argument("--generation", default=None)
    args = ap.parse_args()
    gen = Path(args.generation) if args.generation else generation_dir()
    print("generation:", gen.name)
    failed = 0
    data = run_probe(gen, args.keep)
    if not data:
        print("[FAIL] service: the probe produced nothing")
        failed += 1
    else:
        ok, why = check(data)
        print(f"[{'PASS' if ok else 'FAIL'}] service and day model")
        for w in why:
            print("      " + w)
        failed += 0 if ok else 1

    ui = run_probe(gen, args.keep, UI_PROBE)
    if not ui:
        print("[FAIL] panel and surface: the probe produced nothing")
        failed += 1
    else:
        ok, why = ui_check(ui)
        print(f"[{'PASS' if ok else 'FAIL'}] panel, state and surface")
        for w in why:
            print("      " + w)
        failed += 0 if ok else 1
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
