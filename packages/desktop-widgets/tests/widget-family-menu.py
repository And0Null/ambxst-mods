#!/usr/bin/env python3
"""Content families: the menu's selector, the write path, and the map's honesty.

    map        the families the service offers per type == the ones the widget QMLs
               actually implement (parsed from the widget sources and from the service
               source, never copied from a third list)
    natural    the card size each family is applied at == the size the widget's own
               header declares for it, and every one of those sizes clears the gate the
               widget draws that family behind (the table and the widgets are read back
               out of their sources, so neither can drift alone)
    render     a temp layout with a group whose children carry their own families plus
               a hand-edited unknown one: the menu shows one SegmentedSwitch per
               childless entry and one per group child, each sitting on the file's
               family, none for a group's own family, and none for a family the mod
               does not know
    write      setFamily() on an entry and on a group child reaches the file: the entry's
               family and the size that family lives at change, a group child changes only
               what it draws, and every other field (anchors included) is left alone
    resize     picking a family SETS the card to that family's size in either direction:
               the minimal tier shrinks the calendar's square to the week strip, the
               detailed one grows it, the full one puts it back, and the same pick twice
               does not move it twice
    week       the calendar's minimal tier is a week and not a squeezed month: the panel
               asked at that card's inner size draws ONE row of days, its weekday letters
               fit, its title does not, and the week shown is the one holding today
    bad-index  an out-of-range entry or child index writes nothing at all

Every scenario runs against a THROWAWAY config directory (XDG_CONFIG_HOME is
redirected), so the user's real layout is never touched. --generation points the probe
at an older build, which is how a fix gets measured against the code it replaced.
"""

import argparse
import hashlib
import json
import os
import re
import shutil
import subprocess
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
MOD = HERE.parent

# A layout with every case the selector has to handle: a plain entry on a non-default
# family, a group (its own family means nothing; its children do), and a family no
# version of this mod knows (a hand edit that must survive untouched).
LAYOUT = {
    "design": "custom",
    "opacity": 0.42,
    "widgets": [
        {"type": "clock", "ax": "left", "ox": 40, "ay": "top", "oy": 40,
         "w": 280, "h": 190, "family": "compact", "enabled": True},
        {"type": "group", "direction": "column", "ax": "left", "ox": 40, "ay": "top",
         "oy": 260, "w": 320, "h": 640, "family": "full", "enabled": True,
         "children": [{"type": "weather", "family": "detailed"},
                      {"type": "system", "family": "compact"}]},
        {"type": "calendar", "ax": "right", "ox": 40, "ay": "top", "oy": 40,
         "w": 360, "h": 360, "family": "full", "enabled": True},
        {"type": "weather", "ax": "right", "ox": 40, "ay": "bottom", "oy": 40,
         "w": 280, "h": 150, "family": "weird-hand-edit", "enabled": True},
    ],
}

PROBE = '''import QtQuick
import Quickshell
import Quickshell.Io
import qs.modules.services
import qs.modules.widgets.desktopwidgets
import qs.modules.widgets.dashboard.widgets.calendar

ShellRoot {
    id: root

    property string scenario: Quickshell.env("FAM_SCENARIO") || "render"
    property var lines: []

    Process {
        id: sink
        command: ["/usr/bin/bash", "-c", "cat > " + (Quickshell.env("FAM_OUT") || "/tmp/widget-family.out")]
        stdinEnabled: true
        // Quit once the sink has DRAINED (see calendar-menu-writes.py): quitting on a fixed
        // delay is the same race with a longer fuse, and it hands the harness an empty log.
        onExited: Qt.quit()
    }

    WidgetMenu {
        id: menu
        screen: Quickshell.screens.length > 0 ? Quickshell.screens[0] : null
    }

    // Asked at the size the service's target implies, for the `gates` scenario: the widget
    // itself is the authority on whether a family draws at a given size.
    CalendarWidget { id: gateCal }

    // The dashboard's own panel, for the `week` scenario: it decides from its own height
    // how much of a week arrives, and its row count is what makes a strip a week.
    Calendar { id: weekPanel }

    // Every SegmentedSwitch the menu builds, in tree order. A QML Window has no
    // `children`, only Items do, so the walk starts at contentItem.
    function findSwitches(node) {
        if (!node)
            return [];
        var from = node.contentItem ? node.contentItem : node;
        var out = [];
        var kids = from.children ? from.children : [];
        for (var i = 0; i < kids.length; i++) {
            var k = kids[i];
            if (k && k.options !== undefined && k.picked !== undefined)
                out.push(k);
            out = out.concat(root.findSwitches(k));
        }
        return out;
    }

    function report() {
        var l = [];
        if (root.scenario === "render") {
            var found = root.findSwitches(menu);
            l.push("switches=" + found.length);
            for (var i = 0; i < found.length; i++) {
                var s = found[i];
                l.push("sw=" + s.options.join(",") + "|" + s.currentIndex + "|" + s.visible);
            }
        } else if (root.scenario === "open") {
            l.push("ok");
        } else if (root.scenario === "write") {
            l.push("before=" + JSON.stringify(DesktopWidgetsService.widgets));
            DesktopWidgetsService.setFamily(0, -1, "detailed");
            DesktopWidgetsService.setFamily(1, 1, "detailed");
            l.push("ok");
        } else if (root.scenario === "click") {
            l.push("before=" + JSON.stringify(DesktopWidgetsService.widgets));
            var open = root.findSwitches(menu).filter(function (s) { return s.visible; });
            if (!open.length) {
                l.push("no visible switch");
            } else {
                // The control's own signal, the path a tap runs: the FamilySwitch sizes its
                // highlight from the selected label and reports a pick as `picked(index)`
                // (the stock SegmentedSwitch was replaced for measuring its highlight before
                // the buttons existed). The tap's hit-testing is QML's own machinery.
                l.push("picking index=2");
                open[0].picked(2);
            }
        } else if (root.scenario === "resize") {
            l.push("before=" + JSON.stringify(DesktopWidgetsService.widgets));
            var at = function (i) { return DesktopWidgetsService.widgets[i].w + "x" + DesktopWidgetsService.widgets[i].h; };
            // The minimal tier SHRINKS the calendar's square...
            DesktopWidgetsService.setFamily(2, -1, "compact");
            l.push("compact=" + at(2));
            // ...the detailed one grows it...
            DesktopWidgetsService.setFamily(2, -1, "detailed");
            l.push("detailed=" + at(2));
            // ...and the full one puts it back. The second call must land on the same
            // size: the pick sets the size, it never accumulates.
            DesktopWidgetsService.setFamily(2, -1, "full");
            DesktopWidgetsService.setFamily(2, -1, "full");
            l.push("full=" + at(2));
            // A card taller than its family's size comes back to that size, and the
            // weather card here carries a family no version knows: it only changes family.
            DesktopWidgetsService.setFamily(3, -1, "compact");
            DesktopWidgetsService.setFamily(3, -1, "compact");
            DesktopWidgetsService.setFamily(0, -1, "detailed");
            l.push("ok");
        } else if (root.scenario === "week") {
            var wk = DesktopWidgetsService.naturalCard("calendar", "compact");
            var fi = DesktopWidgetsService.frameInset;
            var iw = wk.w - fi * 2, ih = wk.h - fi * 2;
            l.push("size=" + wk.w + "x" + wk.h + " inner=" + iw + "x" + ih);
            gateCal.family = "compact";
            gateCal.width = iw;
            gateCal.height = ih;
            l.push("widgetWeekMode=" + gateCal.weekMode);
            weekPanel.weekOnly = true;
            weekPanel.width = iw;
            weekPanel.height = ih;
            l.push("gridRows=" + weekPanel.gridRows);
            l.push("letters=" + weekPanel.showWeekLetters);
            l.push("title=" + weekPanel.showTitleRow);
            l.push("weekRow=" + weekPanel.weekRow + " currentWeekRow=" + weekPanel.currentWeekRow);
            var first = weekPanel.cellDate(weekPanel.weekRow, 0);
            var last = weekPanel.cellDate(weekPanel.weekRow, 6);
            var dow = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"];
            l.push("week=" + Qt.formatDateTime(first, "yyyy-MM-dd") + ".." + Qt.formatDateTime(last, "yyyy-MM-dd"));
            l.push("startsOn=" + dow[(first.getDay() + 6) % 7]);
            var now = new Date();
            l.push("todayInWeek=" + (now >= first && now < new Date(last.getTime() + 86400000)));
            // A taller card pays for the week's dates in the title row; the month restores
            // its six rows the moment the mode goes off.
            weekPanel.height = ih + 60;
            l.push("tallerTitle=" + weekPanel.showTitleRow);
            weekPanel.weekOnly = false;
            weekPanel.height = ih;
            l.push("monthRows=" + weekPanel.gridRows);
            // The month's title row is the month's, and the week gate must not take it
            // away: this is what a gate written as `weekOnly && ...` collapses by mistake.
            l.push("monthTitle=" + weekPanel.showTitleRow);
            l.push("ok");
        } else if (root.scenario === "gates") {
            var t = DesktopWidgetsService.familyTarget("calendar", "detailed");
            var inset = DesktopWidgetsService.frameInset;
            gateCal.family = "detailed";
            gateCal.width = t.w - inset * 2;
            gateCal.height = t.h - inset * 2;
            l.push("target=" + t.w + "x" + t.h + " inset=" + inset);
            l.push("showAgenda=" + gateCal.showAgenda);
            l.push("ok");
        } else if (root.scenario === "bad-index") {
            DesktopWidgetsService.setFamily(99, -1, "compact");
            DesktopWidgetsService.setFamily(-1, 0, "compact");
            DesktopWidgetsService.setFamily(0, 4, "compact");
            l.push("ok");
        }
        root.lines = l;
        sink.running = true;
        sink.write(l.join("\\n") + "\\n");
        leave.start();
    }

    Timer {
        id: leave
        interval: 1200
        onTriggered: Qt.quit()
    }

    Component.onCompleted: settle.start()

    Timer {
        id: settle
        interval: 1500
        onTriggered: root.report()
    }
}
'''


def sha(path):
    p = Path(path)
    if not p.exists():
        return "absent"
    return hashlib.sha256(p.read_bytes()).hexdigest()[:12]


def active_generation():
    cfg = Path(os.path.expanduser("~/.config/ambxst/mods.json"))
    gen = json.loads(cfg.read_text())["activeGeneration"]
    return Path(os.path.expanduser("~/.local/share/ambxst/mods/generations")) / gen


def service_map():
    """The families the service offers, parsed out of the service source."""
    src = (MOD / "overlays/modules/services/DesktopWidgetsService.qml").read_text()
    body = re.search(r"familyOptions:\s*\(\{(.*?)\n    \}\)", src, re.S)
    if not body:
        return None
    out = {}
    for type_name, list_src in re.findall(r"(\w+):\s*\[([^\]]*)\]", body.group(1)):
        out[type_name] = re.findall(r'"([^"]+)"', list_src)
    return out


def widget_families():
    """The families the widget QMLs implement: their default plus every === check."""
    out = {}
    for f in sorted((MOD / "overlays/modules/widgets/desktopwidgets").glob("*Widget.qml")):
        src = f.read_text()
        default = re.search(r'property string family:\s*"([^"]+)"', src)
        if not default:
            continue
        types = {default.group(1)}
        types.update(re.findall(r'family === "([a-z]+)"', src))
        out[f.name.replace("Widget.qml", "").lower()] = sorted(types)
    return out


def expected_switches():
    """What the menu must show for LAYOUT: (options, picked family, visible) per row."""
    fam = service_map() or {}
    out = []
    for e in LAYOUT["widgets"]:
        kids = e.get("children") or []
        if not kids:
            opts = fam.get(e["type"], ["full"])
            out.append((opts, e["family"], e["family"] in opts))
            continue
        # A group draws its children: its own family is not rendered anywhere.
        out.append((fam.get(e["type"], ["full"]), e["family"], False))
        for k in kids:
            out.append((fam.get(k["type"], ["full"]), k["family"], True))
    return out


def run_scenario(name, generation, workdir, keep):
    """Run one scenario in its own XDG_CONFIG_HOME; return the probe's detail."""
    xdg = Path(tempfile.mkdtemp(prefix=f"fam-{name}-", dir=workdir))
    conf = xdg / "ambxst"
    conf.mkdir(parents=True)
    target = conf / "desktop-widgets.json"
    target.write_text(json.dumps(LAYOUT, indent=2))
    before_sha = sha(target)
    before_mtime = target.stat().st_mtime_ns

    probe_dir = xdg / "probe"
    probe_dir.mkdir()
    (probe_dir / "probe.qml").write_text(PROBE)
    os.symlink(generation / "modules", probe_dir / "modules")
    os.symlink(generation / "config", probe_dir / "config")
    out = xdg / "out.txt"

    env = dict(os.environ, XDG_CONFIG_HOME=str(xdg), FAM_SCENARIO=name, FAM_OUT=str(out))
    proc = subprocess.run(["timeout", "60", "qs", "-p", str(probe_dir / "probe.qml")],
                          capture_output=True, text=True, env=env)
    log = out.read_text() if out.exists() else ""
    errors = [l for l in proc.stderr.splitlines()
              if "TypeError" in l or "ReferenceError" in l or "is not a function" in l]

    after = json.loads(target.read_text()) if target.exists() else None
    detail = {
        "log": log.strip(), "errors": errors[:3],
        "wrote": before_sha != sha(target) or before_mtime != target.stat().st_mtime_ns,
        "file": after, "path": target, "xdg": xdg,
    }
    if not keep:
        shutil.rmtree(xdg, ignore_errors=True)
    return detail


def check_map():
    fam, impl = service_map(), widget_families()
    why = []
    if fam is None:
        return False, ["familyOptions could not be parsed out of the service"]
    for t in impl:
        if t not in fam:
            why.append(f"{t} implements {impl[t]} but the menu offers nothing")
        elif sorted(fam[t]) != impl[t]:
            why.append(f"{t}: menu offers {sorted(fam[t])}, the widget draws {impl[t]}")
    for t in fam:
        if t not in impl and fam[t] != ["full"]:
            why.append(f"menu offers {fam[t]} for {t}, which has no widget QML")
    return (not why), why


def check_render(d):
    if d["errors"]:
        return False, [f"QML errors: {d['errors']}"]
    if not d["log"].startswith("switches="):
        return False, [f"the probe never reported: {d['log'][:200]!r}"]
    found = []
    for line in d["log"].splitlines()[1:]:
        opts, idx, vis = line[len("sw="):].split("|")
        found.append((opts.split(","), int(idx), vis == "true"))
    want = [(o, o.index(f) if f in o else 0, v) for o, f, v in expected_switches()]
    why = []
    if len(found) != len(want):
        why.append(f"{len(found)} switches in the menu, {len(want)} expected")
    if sorted(found, key=str) != sorted(want, key=str):
        why.append(f"menu shows {found}, file implies {want}")
    return (not why), why


def resize_to(entry, family, table):
    """A family pick sets the card to that family's size; a child has no card of its own."""
    entry["family"] = family
    size = (table.get(entry["type"]) or {}).get(family)
    if size:
        entry["w"], entry["h"] = size
    return entry


def check_write(d, want_entry, want_child):
    if d["errors"]:
        return False, [f"QML errors: {d['errors']}"]
    if not d["wrote"]:
        return False, ["setFamily() never reached the file"]
    before = None
    for line in d["log"].splitlines():
        if line.startswith("before="):
            before = json.loads(line[len("before="):])
    if before is None:
        return False, ["the probe never reported the model it started from"]
    table = service_natural_table() or {}
    exp = json.loads(json.dumps(before))
    resize_to(exp[0], want_entry, table)
    exp[1]["children"][1]["family"] = want_child
    if d["file"].get("widgets") != exp:
        got = d["file"].get("widgets") or []
        return False, ["the saved widgets are not the starting model with the two families changed "
                       "and the entry resized to its tier: "
                       + ", ".join(f"{g['type']} {g.get('w')}x{g.get('h')} {g['family']}" for g in got)]
    if d["file"].get("design") != LAYOUT["design"] or d["file"].get("opacity") != LAYOUT["opacity"]:
        return False, ["the save changed the design or the opacity"]
    return True, []


def check_open(d):
    if d["errors"]:
        return False, [f"QML errors: {d['errors']}"]
    if d["log"] != "ok":
        return False, [f"the probe did not run: {d['log'][:200]!r}"]
    if d["wrote"]:
        return False, ["opening the menu rewrote the layout file"]
    return True, []


def check_click(d, want_first):
    if d["errors"]:
        return False, [f"QML errors: {d['errors']}"]
    if "picking index=2" not in d["log"]:
        return False, [f"the probe never clicked an option button: {d['log'][:200]!r}"]
    before = None
    for line in d["log"].splitlines():
        if line.startswith("before="):
            before = json.loads(line[len("before="):])
    if before is None:
        return False, ["the probe never reported the model it started from"]
    exp = json.loads(json.dumps(before))
    resize_to(exp[0], want_first, service_natural_table() or {})
    if d["file"].get("widgets") != exp:
        got = d["file"].get("widgets") or []
        return False, ["the click did not land as a family change and its size on the first widget: "
                       f"{got[0]['w']}x{got[0]['h']} {got[0]['family']}" if got else
                       "the click did not land as a family change on the first widget"]
    return True, []


def service_natural_table():
    """The service's own natural-card table, parsed out of the service source."""
    src = (MOD / "overlays/modules/services/DesktopWidgetsService.qml").read_text()
    body = re.search(r"naturalCards:\s*\(\{(.*?)\n    \}\)", src, re.S)
    if not body:
        return None
    out = {}
    for line in body.group(1).splitlines():
        m = re.match(r"\s*(\w+):\s*\{(.*)\},?\s*$", line)
        if not m:
            continue
        out[m.group(1)] = {f: (int(w), int(h)) for f, w, h in
                           re.findall(r"(\w+):\s*\{\s*w:\s*(\d+),\s*h:\s*(\d+)\s*\}", m.group(2))}
    return out


def widget_natural():
    """What each widget's own header says its families' cards are: 'compact  (280x80)'."""
    out = {}
    for f in sorted((MOD / "overlays/modules/widgets/desktopwidgets").glob("*Widget.qml")):
        src = f.read_text()
        fams = {fam: (int(w), int(h)) for fam, w, h in
                re.findall(r"^//\s+(compact|full|detailed)\s+\((\d+)x(\d+)\)", src, re.M)}
        if fams:
            out[f.name.replace("Widget.qml", "").lower()] = fams
    return out


def frame_inset():
    m = re.search(r"frameInset:\s*(\d+)",
                  (MOD / "overlays/modules/services/DesktopWidgetsService.qml").read_text())
    return int(m.group(1)) if m else None


def check_natural():
    """The size the menu applies is the one the widget declares, and it clears the gate."""
    table, declared, fam = service_natural_table(), widget_natural(), service_map() or {}
    inset = frame_inset()
    why = []
    if not table:
        return False, ["the service's naturalCards table could not be parsed"]
    if inset is None:
        return False, ["the frame inset could not be read out of the service"]
    if not declared:
        return False, ["no widget declares its families' card sizes in its header"]
    for t, fams in declared.items():
        if t not in table:
            why.append(f"{t} declares {fams} but the service applies no size for it")
        elif table[t] != fams:
            why.append(f"{t}: the service applies {table[t]}, the widget declares {fams}")
    for t, options in fam.items():
        for f in options:
            if f not in (table.get(t) or {}):
                why.append(f"the menu offers {t}/{f} with no card size behind it")
    for t, fams in table.items():
        for f, (w, h) in fams.items():
            gate = service_gate(t, f)
            if not gate:
                continue
            gw, gh = gate
            if gw and w < gw + inset * 2:
                why.append(f"{t}/{f} is {w} wide: its gate needs {gw} of widget, {gw + inset * 2} of card")
            if gh and h < gh + inset * 2:
                why.append(f"{t}/{f} is {h} tall: its gate needs {gh} of widget, {gh + inset * 2} of card")
    return (not why), why


def check_resize(d):
    """A pick sets the card's size: the minimal shrinks it, the detailed grows it."""
    if d["errors"]:
        return False, [f"QML errors: {d['errors']}"]
    before = None
    log = {}
    for line in d["log"].splitlines():
        if line.startswith("before="):
            before = json.loads(line[len("before="):])
        elif "=" in line:
            k, v = line.split("=", 1)
            log[k] = v
    if before is None:
        return False, ["the probe never reported the model it started from"]
    if (before[2]["w"], before[2]["h"]) != (360, 360) or before[3]["h"] != 150:
        return False, ["the scenario did not start from the layout it assumes"]
    table = service_natural_table() or {}
    cal = table.get("calendar", {})
    clock, weather = table.get("clock", {}), table.get("weather", {})
    want = {
        "compact": f'{cal.get("compact", ("?", "?"))[0]}x{cal.get("compact", ("?", "?"))[1]}',
        "detailed": f'{cal.get("detailed", ("?", "?"))[0]}x{cal.get("detailed", ("?", "?"))[1]}',
        "full": f'{cal.get("full", ("?", "?"))[0]}x{cal.get("full", ("?", "?"))[1]}',
    }
    why = []
    for step, size in want.items():
        if log.get(step) != size:
            why.append(f"the {step} pick left the calendar at {log.get(step)}, the table says {size}")
    exp = json.loads(json.dumps(before))
    exp[2]["family"] = "full"
    exp[2]["w"], exp[2]["h"] = cal.get("full", (exp[2]["w"], exp[2]["h"]))
    exp[3]["family"] = "compact"
    exp[3]["w"], exp[3]["h"] = weather.get("compact", (exp[3]["w"], exp[3]["h"]))
    exp[0]["family"] = "detailed"
    exp[0]["w"], exp[0]["h"] = clock.get("detailed", (exp[0]["w"], exp[0]["h"]))
    if d["file"].get("widgets") != exp:
        got = d["file"].get("widgets") or []
        return False, why + [
            "the saved layout is not the starting one with the three sizes applied: "
            + ", ".join(f"{g['type']} {g['w']}x{g['h']} {g['family']}" for g in got)]
    if d["file"].get("design") != LAYOUT["design"]:
        why.append("the save changed the design")
    return (not why), why


def check_week(d):
    """The minimal tier is a week: one row of the same cells, the letters when they fit."""
    why = []
    if d["errors"]:
        why.append(f"QML errors: {d['errors']}")
    log = {}
    for line in d["log"].splitlines():
        if "=" in line and not line.startswith("before="):
            k, v = line.split("=", 1)
            log[k] = v
    table = service_natural_table() or {}
    size = table.get("calendar", {}).get("compact")
    inset = frame_inset()
    if not size or inset is None:
        return False, ["the calendar's minimal size is not in the service's table"]
    want_size = f"{size[0]}x{size[1]} inner={size[0] - inset * 2}x{size[1] - inset * 2}"
    if log.get("size") != want_size:
        why.append(f"the week tier was asked at {log.get('size')!r}, the table says {want_size}")
    if log.get("widgetWeekMode") != "true":
        why.append("the calendar widget does not put the panel into week mode for `compact`")
    if log.get("gridRows") != "1":
        why.append(f"the week tier draws {log.get('gridRows')} rows of days, not 1")
    if log.get("letters") != "true":
        why.append("the weekday letters do not fit at the minimal card's own height")
    if log.get("title") != "false":
        why.append("the week's dates are drawn at a height that cannot pay for them")
    if log.get("startsOn") != "Mon":
        why.append(f"the week shown does not start on Monday: {log.get('startsOn')} from {log.get('week')}")
    if log.get("todayInWeek") != "true":
        why.append(f"the week shown ({log.get('week')}) is not the one holding today")
    if log.get("tallerTitle") != "true":
        why.append("a taller week strip never gains the week's dates in its title row")
    if log.get("monthRows") != "6":
        why.append("turning the week off did not restore the month's six rows")
    if log.get("monthTitle") != "true":
        why.append("the month view lost its title row: the week gate collapsed it "
                   f"(showTitleRow={log.get('monthTitle')!r} with the week off)")
    if "ok" not in d["log"].splitlines():
        why.append("the probe did not run")
    return (not why), why


def service_gate(type_name, family):
    """The service's own gate numbers, parsed out of the service source."""
    src = (MOD / "overlays/modules/services/DesktopWidgetsService.qml").read_text()
    m = re.search(type_name + r":\s*\{\s*" + family + r":\s*\{\s*w:\s*(\d+),\s*h:\s*(\d+)\s*\}\s*\}", src)
    return None if not m else (int(m.group(1)), int(m.group(2)))


def check_gates(d):
    """Growth targets are the widgets' own gates plus the frame, not chosen numbers."""
    why = []
    if d["errors"]:
        why.append(f"QML errors: {d['errors']}")
    frame = re.search(r"anchors\.margins:\s*(\d+)",
                      (MOD / "overlays/modules/widgets/desktopwidgets/WidgetFrame.qml").read_text())
    inset = re.search(r"frameInset:\s*(\d+)",
                      (MOD / "overlays/modules/services/DesktopWidgetsService.qml").read_text())
    if not frame or not inset:
        why.append("could not read the frame inset from WidgetFrame.qml / the service")
    elif frame.group(1) != inset.group(1):
        why.append(f"WidgetFrame insets {frame.group(1)}px, the service assumes {inset.group(1)}px")
    cal = (MOD / "overlays/modules/widgets/desktopwidgets/CalendarWidget.qml").read_text()
    cal_gate = re.search(r"width >= (\d+) && root\.height >= (\d+)", cal)
    svc_cal = service_gate("calendar", "detailed")
    if not cal_gate or not svc_cal:
        why.append("could not read the calendar's agenda gate from CalendarWidget.qml / the service")
    elif (int(cal_gate.group(1)), int(cal_gate.group(2))) != svc_cal:
        why.append(f"the agenda draws at {cal_gate.group(1)}x{cal_gate.group(2)}, the service grows for {svc_cal}")
    wea = (MOD / "overlays/modules/widgets/desktopwidgets/WeatherWidget.qml").read_text()
    block = re.search(r"blockHeight:\s*(\d+)", wea)
    strip = re.search(r"stripHeight:\s*(\d+)", wea)
    svc_w = service_gate("weather", "detailed")
    if not block or not strip or not svc_w:
        why.append("could not read the weather's strip gate from WeatherWidget.qml / the service")
    else:
        if int(block.group(1)) + int(strip.group(1)) != svc_w[1]:
            why.append(f"the strip needs {int(block.group(1)) + int(strip.group(1))}px of height, the service grows for {svc_w[1]}")
        if svc_w[0] != 0:
            why.append("the service constrains the weather's width, but showStrip has no width gate")
    if "showAgenda=true" not in d["log"]:
        why.append(f"at the service's own target the calendar still hides its agenda: {d['log'][:160]!r}")
    if "ok" not in d["log"].splitlines():
        why.append("the probe did not run")
    return (not why), why


def check_bad_index(d):
    if d["errors"]:
        return False, [f"QML errors: {d['errors']}"]
    if d["log"] != "ok":
        return False, [f"the probe did not run: {d['log'][:200]!r}"]
    if d["wrote"]:
        return False, ["an out-of-range index wrote the layout file"]
    return True, []


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--generation", help="generation dir (default: the active one)")
    ap.add_argument("--keep", action="store_true", help="keep the temp dirs")
    ap.add_argument("--only", help="run one scenario by name")
    ap.add_argument("--list", action="store_true", help="list scenarios and exit")
    args = ap.parse_args()

    scenarios = ["map", "natural", "open", "render", "write", "resize", "week", "gates",
                 "click", "bad-index"]
    if args.list:
        print("\n".join(scenarios))
        return 0
    if args.only:
        scenarios = [s for s in scenarios if s == args.only]

    generation = Path(args.generation) if args.generation else active_generation()
    if not (generation / "modules").is_dir():
        print(f"no such generation: {generation}")
        return 2
    print(f"generation: {generation.name}\n")

    workdir = tempfile.mkdtemp(prefix="fam-work-")
    failures = 0
    for name in scenarios:
        if name == "map":
            ok, why = check_map()
        elif name == "natural":
            ok, why = check_natural()
        else:
            d = run_scenario(name, generation, workdir, args.keep)
            if name == "render":
                ok, why = check_render(d)
            elif name == "write":
                ok, why = check_write(d, "detailed", "detailed")
            elif name == "open":
                ok, why = check_open(d)
            elif name == "resize":
                ok, why = check_resize(d)
            elif name == "week":
                ok, why = check_week(d)
            elif name == "gates":
                ok, why = check_gates(d)
            elif name == "click":
                ok, why = check_click(d, "detailed")
            else:
                ok, why = check_bad_index(d)
        print(f"[{'PASS' if ok else 'FAIL'}] {name}")
        for w in why:
            print(f"       {w}")
        failures += 0 if ok else 1

    if args.keep:
        print(f"\ntemp dirs kept under {workdir}\n")
    else:
        shutil.rmtree(workdir, ignore_errors=True)
    if failures:
        print(f"FAILED: {failures} of {len(scenarios)} scenarios")
        return 1
    print(f"PASS: {len(scenarios)} scenarios, the selector offers exactly the modes the widgets draw")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
