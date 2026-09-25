#!/usr/bin/env python3
"""Check the management menu's two shapes against the running shell.

The menu is one column of 380 on a tall screen and two columns side by side on a short one,
where a single column would not fit. Both the decision and the numbers behind it are easy to
break by accident — a theme font grows a row, a block is added, a constant is edited — so
this reads the constants OUT OF the shipped QML (they cannot diverge from it) and then:

  1. instantiates the menu in a probe, one per real screen, and checks the shape it picks,
     the width that shape implies and the height it is allowed (a probe can be trusted for
     those: they are formulas, not laid-out pixels);
  2. opens the menu on the focused screen through the shell's own IPC and checks the box
     Hyprland reports for it against the constants — the numbers that ARE about pixels.

Read-only: it never writes a config. It does open and close the menu once.

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
    Variants {
        model: Quickshell.screens
        delegate: WidgetMenu {
            required property var modelData
            screen: modelData
            Component.onCompleted: root.lines.push(JSON.stringify({
                name: modelData.name, height: modelData.height, width: modelData.width,
                columns: menuColumns, two: twoColumns, panelWidth: implicitWidth,
                maxHeight: maxMenuHeight, rows: maxSourceRows, entries: CalendarEventsService.entries.length
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
        m = re.search(pattern, text)
        if not m:
            sys.exit(f"could not read {what} out of {MENU}")
        return [int(g) for g in m.groups()]
    width, = one(r"property int columnWidth:\s*(\d+)", "columnWidth")
    gap, = one(r"property int columnGap:\s*(\d+)", "columnGap")
    base, per_row = one(r"property int oneColumnHeight:\s*(\d+)\s*\+\s*Math\.max\([^)]*\)\s*\*\s*(\d+)", "oneColumnHeight")
    rows_two, rows_one = one(r"property int maxSourceRows:.*?\?\s*(\d+)\s*:\s*(\d+)", "maxSourceRows")
    return {"width": width, "gap": gap, "base": base, "perRow": per_row,
            "rowsTwo": rows_two, "rowsOne": rows_one}


def generations():
    cfg = Path(os.path.expanduser("~/.config/ambxst/mods.json"))
    return Path(os.path.expanduser("~/.local/share/ambxst/mods/generations")) / json.loads(cfg.read_text())["activeGeneration"]


def shell_pid():
    out = subprocess.run(["pgrep", "-f", r"qs -p .*shell.qml"], capture_output=True, text=True).stdout.split()
    return out[0] if out else None


def probe_shapes(generation, keep):
    d = Path(tempfile.mkdtemp(prefix="menugeo-", dir=os.environ.get("TMPDIR", "/tmp")))
    (d / "probe.qml").write_text(PROBE)
    os.symlink(generation / "modules", d / "modules")
    os.symlink(generation / "config", d / "config")
    out = d / "out.txt"
    env = dict(os.environ, GEO_OUT=str(out))
    subprocess.run(["timeout", "60", "qs", "-p", str(d / "probe.qml")],
                   capture_output=True, text=True, env=env)
    shapes = [json.loads(l) for l in (out.read_text().splitlines() if out.exists() else []) if l.startswith("{")]
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


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--keep", action="store_true", help="keep the probe dir")
    args = ap.parse_args()

    k = constants()
    generation = generations()
    print(f"generation: {generation.name}")
    print(f"constants: column {k['width']}px, gap {k['gap']}px, one column {k['base']}px "
          f"+{k['perRow']}/row, rows {k['rowsOne']} (one column) / {k['rowsTwo']} (two)")

    entries = len(json.loads(SOURCES.read_text())["sources"]) if SOURCES.exists() else 0
    drawn = min(entries, k["rowsOne"])
    print(f"sources in the file: {entries} (one column would draw {drawn})")

    shapes = probe_shapes(generation, args.keep)
    if not shapes:
        sys.exit("the probe produced nothing - is a shell generation installed?")

    failures = []
    two_panel = k["width"] * 2 + k["gap"] + 32
    one_panel = k["width"] + 32
    for s in sorted(shapes, key=lambda s: s["height"]):
        fits = s["height"] - 24
        expected_one = k["base"] + max(0, drawn - 1) * k["perRow"]
        expect_two = fits < expected_one
        ok, why = True, []
        if s["two"] != expect_two:
            ok, why = False, why + [f"picked {'two columns' if s['two'] else 'one column'}; "
                                    f"a one-column {expected_one}px does not fit {fits}px so it should be "
                                    f"{'two' if expect_two else 'one'}"]
        if s["columns"] != (2 if expect_two else 1):
            ok, why = False, why + [f"menuColumns={s['columns']}"]
        want_width = two_panel if expect_two else one_panel
        if s["panelWidth"] != want_width:
            ok, why = False, why + [f"panel width {s['panelWidth']}, expected {want_width}"]
        if s["maxHeight"] != max(240, s["height"] - 24):
            ok, why = False, why + [f"max height {s['maxHeight']} on a {s['height']}px screen"]
        if s["rows"] != (k["rowsTwo"] if expect_two else k["rowsOne"]):
            ok, why = False, why + [f"draws {s['rows']} calendar rows"]
        print(f"[{'PASS' if ok else 'FAIL'}] {s['name']} ({s['width']}x{s['height']}): "
              f"{'two columns' if expect_two else 'one column'}, panel {want_width}px, "
              f"cap {s['maxHeight']}px, rows {s['rows']}")
        for w in why:
            print(f"        {w}")
        if not ok:
            failures.append(s["name"])

    # One column on the tallest screen must still hold the maximum number of rows: otherwise
    # the two shapes would both need the scrollbar the design exists to avoid.
    tallest = max(shapes, key=lambda s: s["height"])
    worst = k["base"] + max(0, min(k["rowsOne"], 6) - 1) * k["perRow"]
    if not tallest["two"] and worst > max(240, tallest["height"] - 24):
        failures.append(tallest["name"])
        print(f"[FAIL] {tallest['name']}: a full one-column menu ({worst}px) would not fit "
              f"{max(240, tallest['height'] - 24)}px - the cap would start scrolling")

    # The live number: the box Hyprland reports for the panel the shell actually draws.
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
            short = opened["w"] == two_panel
            if not short and opened["w"] != one_panel:
                failures.append("live")
                print(f"[FAIL] the live panel is {opened['w']}px wide, which is neither shape")
            elif short:
                cap = max(240, next(s["height"] for s in shapes if s["two"]) - 24)
                ok = opened["h"] <= cap
                print(f"[{'PASS' if ok else 'FAIL'}] live {opened['monitor']}: two columns, "
                      f"{opened['w']}x{opened['h']} (the short screen allows {cap}px of height)")
                if not ok:
                    failures.append("live")
                    print("        the two-column shape does not fit - it would scroll")
            else:
                want = min(k["base"] + max(0, drawn - 1) * k["perRow"],
                           max(240, next(s["height"] for s in shapes if not s["two"]) - 24))
                ok = opened["h"] == want
                print(f"[{'PASS' if ok else 'FAIL'}] live {opened['monitor']}: one column, "
                      f"{opened['w']}x{opened['h']} (expected {want}px for {entries} source(s))")
                if not ok:
                    failures.append("live")
                    print("        the measured height does not match the constants - a row grew")
            if before is None:
                live_box(pid, False)

    print()
    if failures:
        print(f"FAILED: {', '.join(failures)}")
        sys.exit(1)
    print("PASS: the menu picks the shape the screen needs, and the shape fits")


if __name__ == "__main__":
    main()
