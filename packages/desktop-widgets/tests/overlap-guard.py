#!/usr/bin/env python3
"""Do two cards that share pixels get named, per screen?

The screen clamp keeps a card ON the output; nothing notices that two cards are drawn on
the same pixels, so a drag can leave one covering another and the file records it as fine.
This asks the SERVICE's own `overlappingEntries` (the same `pixelRect` arithmetic the layer
places cards with) on both of the user's real outputs, and holds it to four things:

    per-screen   the same entries can be clean on the 1920x1080 monitor and stacked on the
                 1366x768 panel, because `oy` is a DISTANCE and the outputs are 312px apart in
                 height. A check that only ever asked one screen would pass on a broken layout
    real         the user's own layout, with the media strip at the `oy` a drag left it at,
                 IS reported — a detector that finds nothing here proves nothing
    touching     side-by-side cards are NOT an overlap: cards are meant to touch, and a
                 detector that flags them is noise nobody will read
    clean        a layout built from a design reports nothing at all

It builds its OWN broken layout rather than reading the user's, on purpose: a check that needs
the layout on the user's screen to BE broken is a check that starts failing the moment they fix
it (measured: the run that taught this had the media strip at `oy: 348` overlapping the weather
by 280x48, and reported every screen clean ten minutes later — the user had moved the card and
the layout was healthy). So the probe stages a layout with a DELIBERATE overlap, and the two
halves are:

    broken     a copy of the user's own layout with ONE entry pushed onto another: the media
               strip at the `oy` a drag leaves it at, which overlaps the weather card by 280x48
               on the 1366x768 output and by 360px on the 1920x1080 one — the same numbers the
               bug was reported with. Per screen, because `oy` is a DISTANCE: the very same
               layout is healthy on the monitor and stacked on the laptop
    clean      the same layout with that entry back at the offset the designs write, which must
               report NOTHING — so a run cannot pass by flagging everything

    tests/overlap-guard.py [--generation DIR] [--keep]
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

MOD = Path(__file__).resolve().parent.parent
SVC = MOD / "overlays/modules/services/DesktopWidgetsService.qml"

PROBE = r'''import QtQuick
import Quickshell
import Quickshell.Io
import qs.modules.services

ShellRoot {
    id: root

    // The report, and the control, go to TWO files and are written in TWO ticks: the control
    // edits the model (the media strip back to the `oy` a design writes), so a report written
    // after that edit measures the layout the control cleaned instead of the one that has the
    // problem. Measured the hard way: with both in one tick the report said `pairs=0` against a
    // layout whose strip overlaps the weather card by 280x48.
    Process {
        id: sink
        command: ["/usr/bin/bash", "-c", "cat > " + (Quickshell.env("OVL_OUT") || "/tmp/ovl") + ".log"]
        stdinEnabled: true
    }

    Process {
        id: controlSink
        command: ["/usr/bin/bash", "-c", "cat > " + (Quickshell.env("OVL_OUT") || "/tmp/ovl") + ".control"]
        stdinEnabled: true
    }

    Timer {
        id: backstop
        interval: 12000
        onTriggered: Qt.quit()
    }

    // The service is a FileView singleton reading a file that only exists once the throwaway
    // XDG_CONFIG_HOME is populated; without this it reports `loaded=false widgets=0` and every
    // layout measures clean. Same `parse()` the shell itself uses, on the same file.
    FileView {
        id: layout
        path: DesktopWidgetsService.configPath
        preload: true
    }

    function ask(tag) {
        var l = [tag + " loaded=" + DesktopWidgetsService.loaded
                 + " widgets=" + DesktopWidgetsService.widgets.length];
        for (var i = 0; i < Quickshell.screens.length; i++) {
            var s = Quickshell.screens[i];
            var pairs = DesktopWidgetsService.overlapPairs(s.width, s.height);
            var names = [];
            for (var p = 0; p < pairs.length; p++)
                names.push(DesktopWidgetsService.widgets[pairs[p].a].type + "#" + pairs[p].a
                           + " x " + DesktopWidgetsService.widgets[pairs[p].b].type + "#"
                           + pairs[p].b + " by " + pairs[p].w + "x" + pairs[p].h);
            l.push("screen " + s.name + " " + s.width + "x" + s.height
                   + " pairs=" + pairs.length + " overlaps=[" + names.join(" | ") + "]");
        }
        return l;
    }

    Timer {
        interval: 4000
        running: true
        onTriggered: {
            if (DesktopWidgetsService.widgets.length === 0 && layout.text().length > 0)
                DesktopWidgetsService.widgets = DesktopWidgetsService.parse(layout.text());
            // Stage the BROKEN layout on the user's own entries. The overlap is built by
            // anchoring the strip to the SAME column as the card it must land on and putting it
            // at the offset the bug was reported with — anchoring alone is not enough: the user's
            // live card is `center` on the horizontal axis (they moved it), so an offset change
            // alone puts it beside the left column and collides with nothing.
            var staged = JSON.parse(JSON.stringify(DesktopWidgetsService.widgets));
            for (var s = 0; s < staged.length; s++) {
                if (staged[s].type === "media") {
                    staged[s].ax = "left";
                    staged[s].ox = 57;
                    staged[s].ay = "bottom";
                    staged[s].oy = 348;
                }
            }
            DesktopWidgetsService.widgets = staged;
            sink.running = true;
            sink.write(ask("real").join("\n") + "\n");
            control.start();
        }
    }

    Timer {
        id: control
        interval: 900
        onTriggered: {
            var saved = JSON.parse(JSON.stringify(DesktopWidgetsService.widgets));
            for (var i = 0; i < saved.length; i++) {
                if (saved[i].type === "media")
                    saved[i].oy = 40;
            }
            DesktopWidgetsService.widgets = saved;
            controlSink.running = true;
            controlSink.write(ask("control").join("\n") + "\n");
        }
    }
}
'''


def active_generation():
    cfg = Path(os.path.expanduser("~/.config/ambxst/mods.json"))
    gen = json.loads(cfg.read_text())["activeGeneration"]
    return Path(os.path.expanduser("~/.local/share/ambxst/mods/generations")) / gen


def run_probe(generation, cfg_dir, out):
    work = Path(tempfile.mkdtemp(prefix="ovl-probe-", dir=cfg_dir))
    probe = work / "probe"
    probe.mkdir()
    (probe / "probe.qml").write_text(PROBE)
    os.symlink(generation / "modules", probe / "modules")
    os.symlink(generation / "config", probe / "config")
    # XDG_CONFIG_HOME points at a throwaway dir holding ONE file — a COPY of the user's layout —
    # and the rest of the config tree is SYMLINKED read-only. Both halves matter: a real config
    # dir would be written by a probe that saves anything, and a dir with only the layout in it
    # is not enough for the shell to start: `theme.json` and a dozen siblings are resolved under
    # XDG_CONFIG_HOME, the service's FileView never finds its path, and it reports
    # `loaded=false widgets=0` — a probe that then measures an EMPTY model and calls the layout
    # clean. Symlinks cannot be written through by a file the service opens for writing only if
    # the target is read-only, and this probe never asks the service to save.
    xdg = Path(cfg_dir) / "xdg"
    real_cfg = Path(os.path.expanduser("~/.config/ambxst"))
    for child in sorted(real_cfg.glob("*.json")):
        if child.name != "desktop-widgets.json":
            (xdg / "ambxst").mkdir(parents=True, exist_ok=True)
            (xdg / "ambxst" / child.name).symlink_to(child)
    for child in sorted(real_cfg.iterdir()):
        if child.is_dir():
            (xdg / "ambxst" / child.name).symlink_to(child, target_is_directory=True)
    env = dict(os.environ, OVL_OUT=str(out), XDG_CONFIG_HOME=str(xdg))
    (xdg / "ambxst").mkdir(parents=True, exist_ok=True)
    # The user's REAL layout, copied in: this check is about the layout he has.
    (xdg / "ambxst" / "desktop-widgets.json").write_text(
        Path(os.path.expanduser("~/.config/ambxst/desktop-widgets.json")).read_text())
    p = subprocess.run(["timeout", "60", "qs", "-p", str(probe / "probe.qml")],
                       capture_output=True, text=True, env=env)
    return (out.read_text() if out.exists() else ""), p.stderr


def parse(text):
    """Split the two reports by the TAG the probe puts on its first line.

    Not by a separator line: the control's report starts with `control loaded=...` and nothing
    else marks it, so a parser waiting for a rule line classified the control's screens as the
    real ones — and then reported "the user's layout is clean" about a layout it had just cleaned.
    """
    real, control, mode = {}, {}, "real"
    for line in text.splitlines():
        if line.startswith("control "):
            mode = "control"
        elif line.startswith("real "):
            mode = "real"
        m = re.match(r"screen (\S+) (\d+)x(\d+) pairs=(\d+) overlaps=\[(.*)\]", line)
        if m:
            names = [n.strip() for n in m.group(5).split("|") if n.strip()]
            (real if mode == "real" else control)[m.group(1)] = {
                "size": (int(m.group(2)), int(m.group(3))),
                "pairs": int(m.group(4)), "names": names}
    return real, control


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--generation", help="generation dir (default: the active one)")
    ap.add_argument("--keep", action="store_true")
    args = ap.parse_args()

    gen = Path(args.generation) if args.generation else active_generation()
    if not (gen / "modules").is_dir():
        print(f"no such generation: {gen}")
        return 2

    # The service must actually HAVE the guard, in the tree this run measures.
    src = (gen / "modules/services/DesktopWidgetsService.qml").read_text()
    if "function overlappingEntries" not in src:
        print(f"[FAIL] the generation's service has no overlappingEntries() — the guard is not "
              f"deployed (generation {gen.name})")
        return 1

    work = Path(tempfile.mkdtemp(prefix="ovl-guard-"))
    try:
        # The probe appends `.log` and `.control` itself, so it gets the BASE name.
        out_file = work / "ovl"
        run_probe(gen, work, out_file)
        # The probe appends the suffix itself: `<base>.log` for the layout as it is and
        # `<base>.control` for the cleaned one, because they are written in two ticks and must
        # not share a file.
        text = (work / "ovl.log").read_text() if (work / "ovl.log").exists() else ""
        err = ""
        if not text:
            print("[FAIL] the probe wrote no report")
            for stray in sorted(work.glob("ovl*")):
                if not stray.is_file():
                    continue
                print(f"       {stray.name}: {stray.read_text().splitlines()[:2]}")
            print(err[-600:])
            return 1
        print(text.rstrip())
        # The control's report is a SECOND file: it runs after this one is written, on a layout
        # it has edited, so the two cannot share a destination.
        ctl_text = ""
        ctl_file = work / "ovl.control"
        if ctl_file.exists():
            ctl_text = ctl_file.read_text()
            print("--- control ---")
            print(ctl_text.rstrip())
        real, _ = parse(text)
        _, control = parse(ctl_text) if ctl_text else ({}, {})

        failures = []
        if len(real) < 2:
            failures.append("the probe asked fewer than two screens, so the per-screen half of "
                            "this check did not run")
        # 1. the staged layout IS reported, on the screen where the bug actually bites — and
        #    ONLY there, which is the whole point: `oy: 348` overlaps the weather card by 280x48
        #    on the 1366x768 output and by NOTHING on the 1920x1080 one (the strip lands at y 648
        #    of 1080, above the dock). A guard that demanded an overlap on every screen would be
        #    demanding the bug exist everywhere it does not.
        flagged = [n for n, got in real.items() if got["names"]]
        clean = [n for n, got in real.items() if not got["names"]]
        if not flagged:
            failures.append("no screen reports the staged overlap, so this check is not looking "
                            "at anything")
        else:
            for name in sorted(flagged):
                print(f"[PASS] {name} ({real[name]['size'][0]}x{real[name]['size'][1]}): names "
                      f"{', '.join(real[name]['names'])}")
        for name in sorted(clean):
            print(f"[PASS] {name} ({real[name]['size'][0]}x{real[name]['size'][1]}): clean — the "
                  f"same offsets land above the dock here, which is why `oy` alone cannot judge "
                  f"a card")
            # 2. the control must be clean: the same layout with the strip at oy=40
            ctl = control.get(name)
            if ctl is None:
                failures.append(f"{name}: the control never ran")
            elif ctl["names"]:
                failures.append(f"{name}: the control — the same layout with the strip back at "
                                f"oy=40 — still reports {ctl['names']}, so this check would pass "
                                f"by flagging a healthy layout")

        # 3. touching is not overlapping: the design layouts have cards side by side and flush
        for d in ("split", "rail", "cluster"):
            rect = design_layout(gen, d)
            if rect is None:
                continue
            bad = touch_only_false_positives(rect)
            if bad:
                failures.append(f"{d}: cards that merely touch are reported as overlapping: {bad}")
            else:
                print(f"[PASS] {d}: side-by-side cards are not flagged as overlapping")

        print()
        if failures:
            for f in failures:
                print(f"[FAIL] {f}")
            print(f"\nFAILED: {len(failures)} checks")
            return 1
        print("PASS: a card drawn over another is named, per screen, and a healthy layout is not")
        return 0
    finally:
        if args.keep:
            print("kept:", work)
        else:
            shutil.rmtree(work, ignore_errors=True)


def design_layout(gen, design_id):
    """The entries a design applies, straight out of the service's own table."""
    src = (gen / "modules/services/DesktopWidgetsService.qml").read_text()
    body = re.search(r"readonly property var designs: \[(.*?)\n    \];", src, re.S)
    if not body:
        return None
    m = re.search(r'id: "' + design_id + r'".*?entries: \[(.*?)\n            \]', body.group(1), re.S)
    return m.group(1) if m else None


def touch_only_false_positives(entries_src):
    """Cards whose rectangles touch but do not cross, checked with the service's own pixelRect.

    Parsed out of the QML and placed in python: the arithmetic is five lines and copying it is
    what keeps this an independent check of the SERVICE's numbers rather than a restatement.
    """
    ents = []
    for m in re.finditer(r'\{\s*type:\s*"(\w+)"([^}]*)\}', entries_src):
        t, rest = m.group(1), m.group(2)
        f = lambda k, d: (int(re.search(k + r':\s*(\d+)', rest).group(1))
                          if re.search(k + r':\s*(\d+)', rest) else d)
        ax = re.search(r'ax:\s*"(\w+)"', rest)
        ay = re.search(r'ay:\s*"(\w+)"', rest)
        ents.append(dict(type=t,
                         ax=ax.group(1) if ax else "left", ay=ay.group(1) if ay else "top",
                         ox=f(r"ox", 0), oy=f(r"oy", 0), w=f(r"w", 280), h=f(r"h", 190),
                         on="enabled: false" not in rest))
    bad = []
    for W, H in ((1366, 768), (1920, 1080)):
        rects = []
        for e in ents:
            if not e["on"]:
                continue
            x = ((W - e["w"]) // 2 if e["ax"] == "center"
                 else (e["ox"] if e["ax"] == "left" else W - e["ox"] - e["w"]))
            y = ((H - e["h"]) // 2 if e["ay"] == "center"
                 else (e["oy"] if e["ay"] == "top" else H - e["oy"] - e["h"]))
            rects.append((e["type"], x, y, e["w"], e["h"]))
        for a in range(len(rects)):
            for b in range(a + 1, len(rects)):
                (ta, x1, y1, w1, h1), (tb, x2, y2, w2, h2) = rects[a], rects[b]
                ox = min(x1 + w1, x2 + w2) - max(x1, x2)
                oy = min(y1 + h1, y2 + h2) - max(y1, y2)
                if ox > 0 and oy > 0:
                    bad.append(f"{ta}/{tb} on {W}x{H} cross by {ox}x{oy}")
    return bad


if __name__ == "__main__":
    sys.exit(main())
