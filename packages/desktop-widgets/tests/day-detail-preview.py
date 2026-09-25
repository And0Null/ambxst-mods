#!/usr/bin/env python3
"""Capture the day detail as the user will see it, on a HEADLESS output.

Two states are captured, the two the feature is about: a day holding five events from
three different calendars (each with its own colour, two of them overlapping in time) and a
day with nothing, which says so.

Nothing of the user's is touched: the probe runs with its own `XDG_CONFIG_HOME` whose
`ambxst/` symlinks every real config file except the calendars one (which lists the three
fixtures), no layout file is written, and the capture happens on a headless output the
probe creates and removes.

    python3 tests/day-detail-preview.py            # both states
    python3 tests/day-detail-preview.py --state events
"""

import argparse
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
FIXTURES = HERE / "fixtures"
OUTDIR = Path(os.path.expanduser("~/.local/state/ambxst/day-detail-preview"))

SOURCES = [
    ("Personal", "cyan", FIXTURES / "calendar-sample.ics"),
    ("Trabajo", "green", FIXTURES / "calendar-work.ics"),
    ("Familia", "magenta", FIXTURES / "calendar-family.ics"),
]

# Strict where it matters: the two states the feature is about pin the exact count. The
# ring state only exists to photograph the outline, so it asserts nothing about counts.
WANT_EVENTS = {"events": 5, "empty": 0}
WANT_STRICT = {"events", "empty"}

STATES = {
    # the 5-event day: 09:00 work, 14:00 personal, 14:30 work (overlapping), 16:00 work,
    # 19:00 family
    "events": "2026-09-24",
    # nothing at all on it
    "empty": "2026-09-20",
    # not today, so the ring on the cell cannot be confused with the "today" pill
    "ring": "2026-09-21",
}

PROBE = '''import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.modules.services
import qs.modules.widgets.desktopwidgets

ShellRoot {
    id: root

    property var headless: Quickshell.screens.find(s => s.name.indexOf("HEADLESS") === 0)
    readonly property string day: Quickshell.env("DAY_DETAIL_DAY") || "2026-09-24"

    // The card, on the same layer namespace the real widgets use, so the glass renders the
    // way the desktop's own cards do.
    PanelWindow {
        id: cardLayer
        screen: root.headless
        visible: root.headless !== null
        color: "transparent"
        exclusionMode: ExclusionMode.Ignore
        WlrLayershell.layer: WlrLayer.Bottom
        WlrLayershell.namespace: "ambxst:desktopwidgets"

        anchors {
            top: true
            left: true
        }
        margins.top: 60
        margins.left: 60

        implicitWidth: 552
        implicitHeight: 332

        WidgetFrame {
            anchors.fill: parent

            CalendarWidget {
                anchors.fill: parent
                family: "detailed"
            }
        }
    }

    // The overlay itself, the surface a day tap opens.
    DayDetail {
        id: detail
        screen: root.headless
    }

    Process {
        id: sink
        command: ["/usr/bin/bash", "-c", "cat > " + (Quickshell.env("DAY_DETAIL_OUT") || "/tmp/daydetail.out")]
        stdinEnabled: true
    }

    Component.onCompleted: {
        DesktopWidgetsService.openDay(root.day);
        sink.running = true;
        var timer = Qt.createQmlObject("import QtQuick; Timer { interval: 500; repeat: true; running: true }", root);
        timer.triggered.connect(function () {
            var ready = root.headless !== null && CalendarEventsService.loaded;
            var names = [];
            for (var i = 0; i < Quickshell.screens.length; i++)
                names.push(Quickshell.screens[i].name);
            // The values go out through a FILE, not through a terminal, and on EVERY tick: a
            // probe that never becomes ready has to say why, not just stay silent.
            sink.write(JSON.stringify({
                ready: ready,
                screen: root.headless ? root.headless.name : null,
                screens: names,
                day: root.day,
                loaded: CalendarEventsService.loaded,
                key: DesktopWidgetsService.detailDayKey,
                events: CalendarEventsService.eventsOn(root.day).length,
                sources: CalendarEventsService.sources.length,
                problems: CalendarEventsService.problems
            }) + "\\n");
            if (ready)
                timer.stop();
        });
    }
}
'''


def sh(*a):
    return subprocess.run(a, capture_output=True, text=True).stdout


def monitors():
    return {m["name"]: m for m in json.loads(sh("hyprctl", "monitors", "-j"))}


def fake_config():
    d = Path(tempfile.mkdtemp(prefix="daydetail-cfg-", dir=os.environ.get("TMPDIR", "/tmp")))
    real = Path(os.path.expanduser("~/.config/ambxst"))
    fake = d / "ambxst"
    fake.mkdir(parents=True)
    for p in sorted(real.iterdir()):
        if p.name == "desktop-widgets-calendars.json":
            continue
        os.symlink(p, fake / p.name)
    (fake / "desktop-widgets-calendars.json").write_text(json.dumps({
        "sources": [{"name": n, "color": c, "path": str(p), "enabled": True}
                    for n, c, p in SOURCES]}, indent=2))
    os.chmod(fake / "desktop-widgets-calendars.json", 0o600)
    return d


def capture(state, day, out, want_events):
    raw = out.with_name(out.stem + "-full.png")
    known = set(monitors())
    if not known:
        raise SystemExit("could not read the monitor list; refusing to touch anything")
    sh("hyprctl", "output", "create", "headless")
    time.sleep(2.5)
    fresh = [n for n in monitors() if n not in known]
    print("outputs:", {n: (m["width"], m["height"], m["scale"]) for n, m in monitors().items()})
    # A real output must never be chosen: the mode/scale below would land on the user's
    # screens. Only a name that appeared AFTER the create is accepted.
    out_name = next((n for n in fresh if n.startswith("HEADLESS")), None)
    if not out_name:
        raise SystemExit(f"no new HEADLESS output appeared (fresh: {fresh})")
    try:
        subprocess.run(["hyprctl", "output", out_name, "mode", "1920x1080"], capture_output=True)
        time.sleep(1.0)
        # A fresh headless output comes up at scale 2, and the first form does not always
        # take: force it, then CHECK it (a capture written in logical coordinates would
        # otherwise return a 2x image of the wrong region).
        assert out_name.startswith("HEADLESS"), f"refusing to touch {out_name}"
        for cmd in (["hyprctl", "output", out_name, "scale", "1"],
                    ["hyprctl", "eval",
                     f'hl.monitor({{ output = "{out_name}", scale = 1, position = "auto" }})']):
            subprocess.run(cmd, capture_output=True)
            time.sleep(2.0)
            if monitors().get(out_name, {}).get("scale") == 1:
                break
        m = monitors()[out_name]
        if m.get("scale") != 1:
            raise SystemExit(f"{out_name} is at scale {m.get('scale')}, expected 1")

        cfg = fake_config()
        d = Path(tempfile.mkdtemp(prefix="daydetail-probe-", dir=os.environ.get("TMPDIR", "/tmp")))
        (d / "probe.qml").write_text(PROBE)
        gen = Path(os.path.expanduser("~/.local/share/ambxst/mods/generations")) / \
            json.loads(Path(os.path.expanduser("~/.config/ambxst/mods.json")).read_text())["activeGeneration"]
        os.symlink(gen / "modules", d / "modules")
        os.symlink(gen / "config", d / "config")
        state_file = d / "state.json"
        # The probe needs to know where to report BEFORE it starts: setting it after Popen
        # sent its state to the default path and the capture then timed out waiting.
        env = dict(os.environ, XDG_CONFIG_HOME=str(cfg), DAY_DETAIL_DAY=day,
                   DAY_DETAIL_OUT=str(state_file))
        # Kept, not discarded: a probe that dies before reporting is the usual failure and
        # its stderr is the only thing that says why.
        proc = subprocess.Popen(["qs", "-p", str(d / "probe.qml")], env=env,
                                stdout=open(d / "probe.out", "w"),
                                stderr=open(d / "probe.err", "w"))
        try:
            deadline = time.time() + 25
            state = None
            while time.time() < deadline:
                if state_file.exists() and state_file.read_text().strip():
                    try:
                        last = json.loads(state_file.read_text().strip().splitlines()[-1])
                        if last.get("ready"):
                            state = last
                            break
                    except ValueError:
                        pass
                time.sleep(0.5)
            if not state:
                last = state_file.read_text().strip().splitlines()[-1] if state_file.exists() else "(nothing)"
                raise SystemExit("the probe never became ready; last report: " + last)
            if state["screen"] != out_name:
                raise SystemExit(f"the probe drew on {state['screen']}, not on {out_name}")
            # The strict states pin the count; the ring state only exists for the photo.
            if want_events is not None and state["events"] != want_events:
                raise SystemExit(f"the probe holds {state['events']} events for {day}, "
                                 f"expected {want_events}")
            print("  probe state: " + json.dumps(state))
            # Ask the compositor what actually landed on that output: a surface that never
            # reached the screen looks exactly like one that drew nothing.
            layers = json.loads(sh("hyprctl", "layers", "-j"))

            def walk(node):
                if isinstance(node, dict):
                    if "namespace" in node and "w" in node:
                        yield node
                    else:
                        for v in node.values():
                            yield from walk(v)
                elif isinstance(node, list):
                    for v in node:
                        yield from walk(v)

            for it in walk(layers):
                ns = str(it.get("namespace", ""))
                mon = it.get("monitor")
                if ns.startswith("ambxst") or "daydetail" in ns:
                    print(f"  layer: {ns} {it.get('w')}x{it.get('h')} at {it.get('x')},{it.get('y')} "
                          f"on {mon!r} (target {out_name!r})")
            time.sleep(2.0)
            # By OUTPUT, not by coordinates: a crop in global coordinates landed on a real
            # monitor once, and grim's -o cannot be off-target.
            subprocess.run(["grim", "-o", out_name, str(raw)], check=True)
            from PIL import Image
            im = Image.open(raw)
            if (im.width, im.height) != (m["width"], m["height"]):
                raise SystemExit(f"captured {im.width}x{im.height}, expected the output's "
                                 f"{m['width']}x{m['height']}")
            im.crop((0, 0, min(1240, im.width), min(780, im.height))).save(out)
        finally:
            proc.terminate()
            proc.wait(timeout=10)
            shutil.rmtree(d, ignore_errors=True)
            shutil.rmtree(cfg, ignore_errors=True)
        return out
    finally:
        sh("hyprctl", "output", "remove", out_name)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--state", choices=sorted(STATES), default=None)
    args = ap.parse_args()
    OUTDIR.mkdir(parents=True, exist_ok=True)
    states = [args.state] if args.state else sorted(STATES)
    for state in states:
        shot = OUTDIR / f"day-detail-{state}.png"
        capture(state, STATES[state], shot, WANT_EVENTS.get(state))
        print(f"{state}: {shot}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
