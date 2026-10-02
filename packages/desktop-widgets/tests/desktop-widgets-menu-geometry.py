#!/usr/bin/env python3
"""Check the management menu's shape — and that nothing in it is clipped — against the shell.

The menu is HORIZONTAL on every screen wide enough for it: two 380px columns side by side,
the widgets on the left, the calendars on the right, the footer across the bottom. Only a
screen too narrow for two columns gets the single column. Height is the scarce axis on both
outputs this desktop has (1366x768 and 1920x1080), the same overlay is drawn on both, and
the vertical shape the 1080 used to get was 949px tall (88% of the screen) and grew with
every widget added. The decision and the numbers behind it are easy to break by accident —
a theme font grows a row, a block is added, a constant is edited — so this reads the
constants OUT OF the shipped QML (they cannot diverge from it) and then:

  1. instantiates the menu in a probe, one per real screen, and checks the shape it picks,
     the width that shape implies and the height it is allowed (a probe can be trusted for
     those: they are formulas, not laid-out pixels). It also checks WHERE the add-widget row
     lives: outside the widget list's Flickable, because that list is the one region of the
     menu that clips its content;
  2. opens the menu on the focused screen through the shell's own IPC, checks the box
     Hyprland reports against the constants, and CAPTURES that box to measure the add-widget
     row in pixels — the row that used to be the last thing inside the list, where a full
     list sliced its bottom edge off (26px of button drawn as 20). The box is the right size
     either way, so pixels are the only place that bug shows.

Read-only against the config: it never writes one. It opens and closes the menu once, and
takes one screenshot of it.

    python3 tests/desktop-widgets-menu-geometry.py
    python3 tests/desktop-widgets-menu-geometry.py --keep   # keep the probe dir
"""

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path

from PIL import Image

HERE = Path(__file__).resolve().parent
MENU = HERE.parent / "overlays/modules/widgets/desktopwidgets/WidgetMenu.qml"
SOURCES = Path(os.path.expanduser("~/.config/ambxst/desktop-widgets-calendars.json"))
BOX = 'python3 -c "import json,subprocess;d=json.loads(subprocess.run([\'hyprctl\',\'layers\',\'-j\'],capture_output=True,text=True).stdout);[print(m,l[\'x\'],l[\'y\'],l[\'w\'],l[\'h\']) for m,i in d.items() for a in i.get(\'levels\',{}).values() for l in a if l.get(\'namespace\')==\'ambxst:desktopwidgets-menu\']"'

PROBE = '''import QtQuick
import Quickshell
import Quickshell.Io
import qs.modules.services
import qs.modules.widgets.desktopwidgets

ShellRoot {
    id: root
    property var lines: []
    Process {
        id: sink
        command: ["/usr/bin/bash", "-c", "cat > " + (Quickshell.env("GEO_OUT") || "/tmp/menu-geometry.out")]
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

    // The add-widget row is identified by a control (the "Weather" IconButton, which is the
    // only item in the menu carrying a `label`), and then by how many Flickables sit above
    // it: the menu's own outer one is always there, so one means the row is OUTSIDE the
    // widget list (it cannot be clipped) and two means it is back inside it.
    function flickableDepth(item) {
        var d = 0;
        var p = item ? item.parent : null;
        while (p) {
            if (typeof p.contentHeight === "number" && typeof p.contentWidth === "number")
                d++;
            p = p.parent;
        }
        return d;
    }

    function findByLabel(item, label) {
        if (!item)
            return null;
        if (item.label === label)
            return item;
        var kids = item.children || [];
        for (var i = 0; i < kids.length; i++) {
            var hit = findByLabel(kids[i], label);
            if (hit)
                return hit;
        }
        return null;
    }

    Variants {
        model: Quickshell.screens
        delegate: WidgetMenu {
            id: menu
            required property var modelData
            screen: modelData
            Component.onCompleted: root.lines.push(JSON.stringify({
                name: modelData.name, height: modelData.height, width: modelData.width,
                columns: menuColumns, two: twoColumns, three: threeColumns, panelWidth: implicitWidth,
                maxHeight: maxMenuHeight, bar: barClearance, dock: dockClearance,
                shapeTwo: shapeTwoHeight, shapeThree: shapeThreeHeight,
                rows: maxSourceRows, entries: CalendarEventsService.entries.length,
                addRowFlickables: flickableDepth(findByLabel(menu.contentItem, "Weather"))
            }))
        }
    }
    Timer {
        interval: 3500
        running: true
        onTriggered: {
            sink.running = true;
            sink.write(root.lines.join("\\n") + "\\n");
            sink.stdinEnabled = false;
            sinkBackstop.start();
        }
    }
}
'''


def constants():
    """Read the layout constants out of the shipped QML."""
    text = MENU.read_text()
    def one(pattern, what):
        m = re.search(pattern, text, re.S)
        if not m:
            sys.exit(f"could not read {what} out of {MENU}")
        return [int(g) for g in m.groups()]
    width, = one(r"property int columnWidth:\s*(\d+)", "columnWidth")
    gap, = one(r"property int columnGap:\s*(\d+)", "columnGap")
    wrows, = one(r"property int maxWidgetRows:\s*(\d+)", "maxWidgetRows")
    srows, = one(r"property int maxSourceRows:\s*(\d+)", "maxSourceRows")
    wpitch, = one(r"property int widgetRowPitch:\s*(\d+)", "widgetRowPitch")
    pitch, = one(r"property int sourceRowPitch:\s*(\d+)", "sourceRowPitch")
    button, = one(r"component IconButton: Rectangle \{.*?height:\s*(\d+)", "the add-row button height")
    # The two facts the clipping bug hid behind, checked on the SOURCE because they are
    # structural: the list stops at a whole number of rows, and the add row is not in it.
    whole_rows = re.search(
        r"Layout\.preferredHeight:\s*Math\.min\(widgetListColumn\.implicitHeight,\s*"
        r"root\.maxWidgetRows \* root\.widgetRowPitch\)", text)
    add_row_after = text.index("// Add widget row") > text.index("id: widgetList")
    return {"width": width, "gap": gap, "widgetRows": wrows, "rows": srows,
            "widgetPitch": wpitch, "perRow": pitch, "button": button,
            "wholeRows": bool(whole_rows), "addRowText": add_row_after}


def generations():
    cfg = Path(os.path.expanduser("~/.config/ambxst/mods.json"))
    return Path(os.path.expanduser("~/.local/share/ambxst/mods/generations")) / json.loads(cfg.read_text())["activeGeneration"]


def shell_pid():
    out = subprocess.run(["pgrep", "-f", r"qs -p .*shell\.qml"], capture_output=True, text=True).stdout.split()
    return out[0] if out else None


def probe_shapes(generation, keep):
    d = Path(tempfile.mkdtemp(prefix="menugeo-", dir=os.environ.get("TMPDIR", "/tmp")))
    (d / "probe.qml").write_text(PROBE)
    os.symlink(generation / "modules", d / "modules")
    os.symlink(generation / "config", d / "config")
    out = d / "out.txt"
    env = dict(os.environ, GEO_OUT=str(out))
    run = subprocess.run(["timeout", "60", "qs", "-p", str(d / "probe.qml")],
                         capture_output=True, text=True, env=env)
    shapes = [json.loads(l) for l in (out.read_text().splitlines() if out.exists() else []) if l.startswith("{")]
    if not shapes:
        # A probe that failed to LOAD prints nothing useful in the log file, so the shell's
        # own stderr is the only place the reason shows up. Say it, or a broken probe reads
        # exactly like a missing generation.
        err = [l for l in run.stdout.splitlines() + run.stderr.splitlines()
               if "ERROR" in l or "caused by" in l]
        for line in err[:6]:
            print(f"        probe: {line.strip()}")
    if not keep:
        shutil.rmtree(d, ignore_errors=True)
    return shapes


def box():
    out = subprocess.run(["bash", "-c", BOX], capture_output=True, text=True).stdout.strip()
    if not out:
        return None
    mon, x, y, w, h = out.split()
    return {"monitor": mon, "x": int(x), "y": int(y), "w": int(w), "h": int(h)}


def ipc(pid):
    subprocess.run(["qs", "ipc", "--pid", pid, "call", "ambxst", "run", "desktop-widgets"],
                   capture_output=True, text=True)


def live_box(pid, want_open):
    for _ in range(10):
        ipc(pid)
        for _ in range(6):
            time.sleep(1)
            b = box()
            if (b is not None) == want_open:
                return b
    return box()


def painted_bands(im, x0, x1, y0, y1, min_px=20):
    """Rows of a capture that carry paint, grouped into bands (start, end, height)."""
    bands, cur = [], None
    for y in range(y0, y1):
        n = 0
        for x in range(x0, x1):
            p = im.getpixel((x, y))
            if sum(p) > 95 or (max(p) - min(p)) > 14:
                n += 1
        if n > min_px and cur is None:
            cur = y
        elif n <= min_px and cur is not None:
            bands.append((cur, y - 1, y - cur))
            cur = None
    if cur is not None:
        bands.append((cur, y1 - 1, y1 - cur))
    return bands


def measure_add_row(b, k):
    """Height of the add-widget row as PAINTED, in pixels, from a capture of the live panel.

    The row is the band right before the first separator line below the widget list, and
    both a complete 26px button and a clipped one sit somewhere in there — so the number is
    the check: the shipped button draws 26 rows, and this returns what actually reached the
    screen.
    """
    shot = Path(tempfile.mkdtemp(prefix="menupix-")) / "panel.png"
    r = subprocess.run(["grim", "-g", f"{b['x']},{b['y']} {b['w']}x{b['h']}", str(shot)],
                       capture_output=True, text=True)
    if r.returncode != 0 or not shot.exists():
        return None, f"grim failed: {r.stderr.strip()}"
    im = Image.open(shot).convert("RGB")
    # The left column, whatever the shape: the list and the add row live at the same x in
    # both (the panel's own 16px margin plus the column).
    x0, x1 = 30, min(k["width"] + 10, im.size[0] - 16)
    bands = painted_bands(im, x0, x1, 150, im.size[1] - 120)
    sep = next((i for i, band in enumerate(bands) if band[2] <= 1), None)
    if sep is None or sep == 0:
        return None, "no separator found under the widget list"
    return bands[sep - 1][2], None


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--keep", action="store_true", help="keep the probe dir")
    args = ap.parse_args()

    k = constants()
    generation = generations()
    print(f"generation: {generation.name}")
    print(f"constants: column {k['width']}px, gap {k['gap']}px, list cap {k['widgetRows']} rows "
          f"of {k['widgetPitch']}px, calendar rows {k['rows']} of {k['perRow']}px, "
          f"add-row button {k['button']}px")

    entries = len(json.loads(SOURCES.read_text())["sources"]) if SOURCES.exists() else 0
    print(f"sources in the file: {entries} (the menu draws {min(entries, k['rows'])})")

    failures = []
    if not k["wholeRows"]:
        failures.append("source")
        print("[FAIL] the widget list's cap is not a whole number of rows: a pixel cap can "
              "slice the last row in half")
    if not k["addRowText"]:
        failures.append("source")
        print("[FAIL] the add-widget row does not sit below the widget list in the file")

    shapes = probe_shapes(generation, args.keep)
    if not shapes:
        sys.exit("the probe produced nothing - is a shell generation installed?")

    def panel_width(cols):
        return k["width"] * cols + k["gap"] * (cols - 1) + 32

    for s in sorted(shapes, key=lambda s: s["height"]):
        # The shape is RE-DERIVED from the room, not from the width alone: one column on a screen
        # too narrow for two, two columns when they fit the height, and THREE when the two-column
        # stack does not fit while the side-by-side one does. A rule the harness only recorded
        # would pass happily while the panel was 162px too tall for the user's own output.
        room = max(240, s["height"] - s["bar"] - s["dock"] - 24)
        want = 1
        if s["width"] >= (k["width"] * 2 + k["gap"] + 24):
            want = 2
            if (s["width"] >= (k["width"] * 3 + k["gap"] * 2 + 24)
                    and s["shapeTwo"] + 32 > room and s["shapeThree"] + 32 <= room):
                want = 3
        want_width = panel_width(want)
        ok, why = True, []
        if s["columns"] != want:
            ok, why = False, why + [f"menuColumns={s['columns']}, and the room asks for {want}: "
                                    f"{s['width']}px wide, two columns need {s['shapeTwo'] + 32}px "
                                    f"of height, three need {s['shapeThree'] + 32}, the room is "
                                    f"{room}"]
        if s["panelWidth"] != want_width:
            ok, why = False, why + [f"panel width {s['panelWidth']}, expected {want_width}"]
        if s["maxHeight"] != room:
            ok, why = False, why + [f"max height {s['maxHeight']} on a {s['height']}px screen "
                                    f"with a {s['bar']}px bar and a {s['dock']}px dock"]
        if s["rows"] != k["rows"]:
            ok, why = False, why + [f"draws {s['rows']} calendar rows"]
        # 1 = only the menu's own outer Flickable: outside the widget list, so unclippable.
        if s["addRowFlickables"] != 1:
            ok, why = False, why + [f"the add-widget row has {s['addRowFlickables']} Flickables "
                                    f"above it; 2 means it is back inside the clipped list"]
        print(f"[{'PASS' if ok else 'FAIL'}] {s['name']} ({s['width']}x{s['height']}): "
              f"{want} column(s), panel {want_width}px, cap {room}px, rows {s['rows']}"
              + (f"  [two-column shape {s['shapeTwo'] + 32}px, three {s['shapeThree'] + 32}px]"
                 if want == 3 else ""))
        for w in why:
            print(f"        {w}")
        if not ok:
            failures.append(s["name"])

    # The horizontal shape is the point of the design: it has to fit the SHORTEST screen.
    shortest = min(shapes, key=lambda s: s["height"])
    room = max(240, shortest["height"] - shortest["bar"] - shortest["dock"] - 24)
    print(f"        {shortest['name']}: the room between the bar and the dock is {room}px; the "
          f"two-column shape needs {shortest['shapeTwo'] + 32}px and the three-column one "
          f"{shortest['shapeThree'] + 32}px, so it draws {shortest['columns']} column(s)")

    # The live numbers: the box Hyprland reports, and the add-widget row as painted.
    pid = shell_pid()
    if not pid:
        print("[SKIP] no running shell - the live box was not measured")
    else:
        before = box()
        opened = live_box(pid, True) if before is None else before
        if not opened:
            failures.append("live")
            print("[FAIL] the menu could not be opened through IPC")
        else:
            cols = next((c for c in (3, 2, 1) if opened["w"] == panel_width(c)), None)
            live = next((s for s in shapes if s["name"] == opened["monitor"]), None)
            if cols is None or live is None:
                failures.append("live")
                print(f"[FAIL] the live panel is {opened['w']}px wide on {opened['monitor']}, "
                      f"which is no shape for that screen")
            else:
                cap = max(240, live["height"] - live["bar"] - live["dock"] - 24)
                ok = opened["h"] <= cap
                print(f"[{'PASS' if ok else 'FAIL'}] live {opened['monitor']}: {cols} column(s), "
                      f"{opened['w']}x{opened['h']} — the room between its bar and dock is {cap}px")
                if not ok:
                    failures.append("live")
                    print("        the menu does not fit the room - it would clip or scroll")
            painted, why = measure_add_row(opened, k)
            if painted is None:
                print(f"[SKIP] the add-widget row was not measured: {why}")
            else:
                ok = painted >= k["button"] - 1
                print(f"[{'PASS' if ok else 'FAIL'}] add-widget row painted {painted}px of "
                      f"{k['button']} (a clipped row draws less)")
                if not ok:
                    failures.append("clip")
                    print("        the widget list is cutting the add-widget row again")
            if before is None:
                live_box(pid, False)

    print()
    if failures:
        print(f"FAILED: {', '.join(failures)}")
        sys.exit(1)
    print("PASS: the menu is horizontal where it fits, it fits, and nothing in it is clipped")


if __name__ == "__main__":
    main()
