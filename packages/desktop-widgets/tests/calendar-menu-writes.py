#!/usr/bin/env python3
"""Drive the calendar sources file through the management menu and the service.

This exists because the menu could once wipe every calendar just by being opened: the
source row's Switch fires `toggled` when the binding assigns `checked` on delegate
creation, which called setSourceEnabled() -> save() with whatever `entries` held at that
instant. With the file not read yet (or unparseable) that list is empty, and the write
replaced the user's whole file with nothing.

Every scenario runs against a THROWAWAY config directory (XDG_CONFIG_HOME is redirected),
so nothing here can touch ~/.config/ambxst. Requires a running generation:

    python3 tests/calendar-menu-writes.py            # the active generation
    python3 tests/calendar-menu-writes.py --keep     # leave the temp dirs behind
"""

import argparse
import hashlib
import json
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
FIXTURE = "~/.local/share/ambxst/calendar/sample.ics"
GOOD_FILE = {
    "sources": [
        {"name": "Sample", "color": "cyan", "path": FIXTURE, "enabled": True},
    ]
}
BROKEN_FILE = '{ this was never JSON, and someone has calendars in here'

PROBE = '''import QtQuick
import Quickshell
import Quickshell.Io
import qs.modules.services
import qs.modules.widgets.desktopwidgets

// The probe the harness drives. It instantiates the management menu exactly the way the
// shell does - one per screen - and then performs one service edit, so both halves of the
// write path are exercised in the same process.
ShellRoot {
    id: root

    property string scenario: Quickshell.env("CAL_SCENARIO") || "open"
    property var lines: []

    Process {
        id: sink
        command: ["/usr/bin/bash", "-c", "cat > " + (Quickshell.env("CAL_OUT") || "/tmp/cal-menu-writes.out")]
        stdinEnabled: true
        // Quit once the sink has DRAINED. Quitting on the next tick raced it: the scenario's
        // work landed on disk while the log came back empty, at random, and the harness then
        // reported "the service never finished reading the file" against a healthy mod.
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
        }
    }

    // A menu this probe can drive directly, so the scenario "ui-add" goes through the REAL
    // path: typing into the two fields and pressing Add, not calling the service behind the
    // menu's back. The fields are found by walking the object tree: they are the only
    // objects in there that carry a placeholderText.
    WidgetMenu {
        id: driven
        screen: Quickshell.screens.length > 0 ? Quickshell.screens[0] : null
    }

    // `children` exists on Items, not on the Window itself, so the walk starts at its
    // contentItem and goes down the visual tree.
    function findFields(node) {
        if (!node)
            return [];
        var from = node.contentItem ? node.contentItem : node;
        var out = [];
        var kids = from.children ? from.children : [];
        for (var i = 0; i < kids.length; i++) {
            var k = kids[i];
            if (k.placeholderText === "Name" || k.placeholderText === "Link or .ics path")
                out.push(k);
            out = out.concat(root.findFields(k));
        }
        return out;
    }

    Timer {
        interval: 3500
        running: true
        onTriggered: {
            var S = CalendarEventsService;
            var l = [];
            l.push("scenario=" + root.scenario);
            l.push("config=" + S.configPath);
            l.push("loaded=" + S.loaded + " broken=" + S.fileBroken + " entries=" + S.entries.length);
            l.push("saveError='" + S.saveError + "'");
            var newPath = Quickshell.env("CAL_TMP") + "/facu.ics";
            if (root.scenario === "add" || root.scenario === "broken-add")
                l.push("result='" + S.addSource("Facu", newPath, "blue") + "'");
            else if (root.scenario === "ui-add") {
                var fields = root.findFields(driven);
                var nameField = fields.filter(function (f) { return f.placeholderText === "Name"; })[0];
                var linkField = fields.filter(function (f) { return f.placeholderText === "Link or .ics path"; })[0];
                l.push("campos=" + fields.length);
                if (nameField && linkField) {
                    nameField.text = "Facu";
                    linkField.text = newPath;
                    driven.addNow();
                    l.push("result='" + driven.addError + "'");
                    l.push("campos tras agregar='" + nameField.text + "|" + linkField.text + "'");
                } else {
                    l.push("result='NO ENCONTRO LOS CAMPOS'");
                }
            }
            else if (root.scenario === "dup")
                l.push("result='" + S.addSource("Otro", "~/.local/share/ambxst/calendar/sample.ics", "blue") + "'");
            else if (root.scenario === "toggle")
                l.push("result='" + (S.setSourceEnabled(0, false), "toggled") + "'");
            else if (root.scenario === "remove")
                l.push("result='" + (S.removeSource(0), "removed") + "'");
            root.lines = l;
            settle.start();
        }
    }

    // The write is asynchronous: give it a moment so the harness reads a settled file.
    Timer {
        id: settle
        interval: 1500
        onTriggered: {
            var l = root.lines.slice();
            l.push("entriesAfter=" + JSON.stringify(CalendarEventsService.entries.map(function (e) { return e.name + ":" + e.color + ":" + e.enabled; })));
            l.push("isSaving=" + CalendarEventsService.isSaving);
            sink.running = true;
            sink.write(l.join("\\n") + "\\n");
            sink.stdinEnabled = false;
            sinkBackstop.start();
        }
    }
}
'''


def sha(path):
    p = Path(path)
    if not p.exists():
        return "absent"
    return hashlib.sha256(p.read_bytes()).hexdigest()[:12]


def mode(path):
    p = Path(path)
    return "absent" if not p.exists() else oct(p.stat().st_mode & 0o777)[2:]


def active_generation():
    cfg = Path(os.path.expanduser("~/.config/ambxst/mods.json"))
    gen = json.loads(cfg.read_text())["activeGeneration"]
    return Path(os.path.expanduser("~/.local/share/ambxst/mods/generations")) / gen


def run_scenario(name, generation, workdir, initial, keep):
    """Run one scenario in its own XDG_CONFIG_HOME; return (ok, details)."""
    xdg = Path(tempfile.mkdtemp(prefix=f"calw-{name}-", dir=workdir))
    tmp = Path(tempfile.mkdtemp(prefix=f"caltmp-{name}-", dir=workdir))
    (tmp / "facu.ics").write_text("BEGIN:VCALENDAR\nEND:VCALENDAR\n")
    conf_dir = xdg / "ambxst"
    conf_dir.mkdir(parents=True)
    target = conf_dir / "desktop-widgets-calendars.json"
    if initial is not None:
        target.write_text(initial)
        target.chmod(0o600)
    before_sha, before_mode = sha(target), mode(target)
    before_mtime = target.stat().st_mtime_ns if target.exists() else 0

    probe_dir = xdg / "probe"
    probe_dir.mkdir()
    (probe_dir / "probe.qml").write_text(PROBE)
    os.symlink(generation / "modules", probe_dir / "modules")
    os.symlink(generation / "config", probe_dir / "config")
    out = xdg / "out.txt"

    env = dict(os.environ, XDG_CONFIG_HOME=str(xdg), CAL_SCENARIO=name,
               CAL_OUT=str(out), CAL_TMP=str(tmp))
    proc = subprocess.run(["timeout", "60", "qs", "-p", str(probe_dir / "probe.qml")],
                          capture_output=True, text=True, env=env)
    log = out.read_text() if out.exists() else ""
    errors = [l for l in proc.stderr.splitlines()
              if "TypeError" in l or "ReferenceError" in l or "is not a function" in l]

    after_sha, after_mode = sha(target), mode(target)
    after_mtime = target.stat().st_mtime_ns if target.exists() else 0
    wrote = before_sha != after_sha or before_mtime != after_mtime
    detail = {
        "log": log.strip(), "errors": errors[:3],
        "before": f"{before_sha}/{before_mode}", "after": f"{after_sha}/{after_mode}",
        "wrote": wrote,
        "content": target.read_text().strip() if target.exists() else "(no file)",
    }
    if not keep:
        shutil.rmtree(xdg, ignore_errors=True)
        shutil.rmtree(tmp, ignore_errors=True)
    return detail


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--generation", help="generation dir (default: the active one)")
    ap.add_argument("--keep", action="store_true", help="keep the temp dirs")
    ap.add_argument("--only", help="run one scenario by name")
    args = ap.parse_args()

    generation = Path(args.generation).resolve() if args.generation else active_generation()
    if not (generation / "modules").is_dir():
        sys.exit(f"no generation at {generation}")
    workdir = os.environ.get("TMPDIR", "/tmp")
    print(f"generation: {generation.name}")

    good = json.dumps(GOOD_FILE, indent=2)
    # name -> (initial file, expectations)
    scenarios = {
        # Opening the menu must not write anything, in every state of the file.
        "open":          (good,     {"wrote": False}),
        "open-nofile":   (None,     {"wrote": False, "exists": False}),
        # A real edit still writes, and leaves the other sources alone.
        "add":           (good,     {"wrote": True, "sources": 2, "keeps": "Sample", "mode": "600"}),
        # The same add, through the menu's own fields and Add button, which must also clear
        # the fields so the next calendar starts blank.
        "ui-add":        (good,     {"wrote": True, "sources": 2, "keeps": "Sample", "mode": "600",
                                     "log": "campos tras agregar='|'"}),
        "toggle":        (good,     {"wrote": True, "only": "enabled"}),
        "remove":        (good,     {"wrote": True, "sources": 0}),
        # A duplicate is refused, and refusing writes nothing.
        "dup":           (good,     {"wrote": False, "says": "already in the list"}),
        # An unparseable file is never overwritten: that is the data-loss path.
        "broken-add":    (BROKEN_FILE, {"wrote": False, "says": "will not be overwritten", "mode": "600"}),
    }

    if args.only:
        scenarios = {k: v for k, v in scenarios.items() if k == args.only}
        if not scenarios:
            sys.exit(f"no such scenario: {args.only}")

    failures = []
    for name, (initial, expect) in scenarios.items():
        d = run_scenario(name, generation, workdir, initial, args.keep)
        ok = True
        why = []
        if d["errors"]:
            ok, why = False, why + [f"QML errors: {d['errors']}"]
        if "loaded=true" not in d["log"]:
            ok, why = False, why + ["the service never finished reading the file"]
        if expect.get("wrote") is not None and d["wrote"] != expect["wrote"]:
            ok = False
            why.append(f"wrote={d['wrote']} but expected {expect['wrote']} ({d['before']} -> {d['after']})")
        if expect.get("exists") is False and d["after"] != "absent/absent":
            ok = False
            why.append(f"a file appeared: {d['after']}")
        if "sources" in expect:
            try:
                got = len(json.loads(d["content"])["sources"])
            except Exception as e:
                got = f"unreadable ({e})"
            if got != expect["sources"]:
                ok = False
                why.append(f"{got} sources on disk, expected {expect['sources']}")
        if "keeps" in expect and expect["keeps"] not in d["content"]:
            ok, why = False, why + [f"lost the {expect['keeps']} source"]
        if "says" in expect and expect["says"] not in d["log"]:
            ok, why = False, why + [f"the refusal was not reported (no {expect['says']!r})"]
        if "log" in expect and expect["log"] not in d["log"]:
            ok, why = False, why + [f"the log does not show {expect['log']!r}"]
        if "mode" in expect and d["after"].split("/")[1] != expect["mode"]:
            ok, why = False, why + [f"mode {d['after'].split('/')[1]}, expected {expect['mode']}"]
        if "only" in expect:
            try:
                src = json.loads(d["content"])["sources"][0]
                if src.get(expect["only"]) is not False:
                    ok, why = False, why + [f"{expect['only']} did not change in the file"]
                if src.get("path") != FIXTURE or src.get("name") != "Sample":
                    ok, why = False, why + ["the toggle rewrote other fields"]
            except Exception as e:
                ok, why = False, why + [f"unreadable: {e}"]

        print(f"[{'PASS' if ok else 'FAIL'}] {name}")
        if not ok:
            for w in why:
                print(f"        {w}")
            failures.append(name)
        for line in d["log"].splitlines():
            print(f"        | {line}")
        if not ok and d["content"]:
            print(f"        file: {d['content'][:200]}")
        if d["errors"]:
            print(f"        stderr: {d['errors']}")

    print()
    if failures:
        print(f"FAILED: {', '.join(failures)}")
        sys.exit(1)
    print(f"PASS: {len(scenarios)} scenarios, the sources file only changes when asked")


if __name__ == "__main__":
    main()
