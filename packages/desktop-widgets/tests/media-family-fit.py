#!/usr/bin/env python3
"""The media card's two families, measured from the pixels the real card draws.

    caret   the switcher caret beside the artist line is optically CENTRED on that line.
            A Row gives every child the Row's full height and aligns them by
            `verticalAlignment`, so without it the caret's 14px box sits on the Row's TOP
            edge beside an 18px text box: measured at -2.5px of ink off the line's centre,
            which reads as a caret stuck to the ceiling rather than centred.
    fit     the `detailed` card is as tall as what it draws. Its own header says the extra
            room is "the two extra rows, not a bigger cover", so dead space below the last
            row is a bug in the DECLARED size, not design — and it had 48px of it.
    qml     the two time labels read `Config.theme.monoFont`, and `Config` is the qs.config
            singleton: a file that uses it WITHOUT importing qs.config throws
            `ReferenceError: Config is not defined` on every card (measured live in the
            running shell's own qslog, twice per card) and the times silently fall back to
            the UI font.

Three things this harness must not do, all learned here the hard way:

  * measure WITHOUT a window. A `ShellRoot` that instantiates MediaWidget directly never
    lays it out: every Row reports `h0` and `childrenRect` collapses to 276 = 248 + 8 + 20,
    the artwork plus the title and nothing else. Only a windowed tree carries the truth.
  * pass size arguments to `grabToImage`. Quickshell's takes ONLY the callback; the Qt
    extras fail with "Too many arguments, ignoring 1" / "Could not find any constructor for
    QQmlSizeValueType" and write nothing. And `saveToFile` is not the way out either: the
    result carries a `url`, which is how the shell's own systray drag image gets one
    (SysTrayItem.qml, `Drag.imageSource = result.url`).
  * photograph the user's screens. The grab renders this tree into a PNG with no output
    involved, so nothing on any display is touched and no headless output is needed.

The caret is forced visible for the grab: it is `visible: canChoose`, and with one player
on the bus `canChoose` is false — so the thing under test would otherwise not exist.

    tests/media-family-fit.py [--keep] [--generation DIR]
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

import numpy as np
from PIL import Image

# Each family's card size minus WidgetFrame's 16 per side: the WIDGET box the tree lays out
# at. `CARD` is read back out of the shipped sources by `read_sizes()` — the harness never
# keeps its own copy of a number the widget and the service also declare.
INSET = 16
# The artwork's side: `artSide` is the widget's own width, so the top band is this tall and
# everything below it is text and controls.
ART = 248
# A caret one pixel off the line's centre is invisible; three is not.
CARET_TOL = 2
# Slack allowed below the last row. A Text's box is taller than its ink (the font's
# leading), so the last row's INK always stops a few px short of its own bottom.
FIT_TOL = 8

MOD = Path(__file__).resolve().parent.parent

PROBE = r'''import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.modules.services
import qs.modules.widgets.desktopwidgets

ShellRoot {
    id: root

    property var log: []
    property int pending: 0

    // ONE window for both cards, stacked: a second window only made the grabs race over
    // which surface was live (measured: the row's grab landed, the two card grabs never
    // fired). A layer-shell panel is handed exactly the size asked for, so nothing is
    // rescaled.
    //
    // The heights are the ones the SERVICE applies, read from its own table at run time —
    // NOT the numbers this harness would like. Hardcoding 425 made the `fit` check unable
    // to fail: with the old 500 declared, the widget was still instantiated at 425 and the
    // dead space never appeared (measured: reverting the declaration to 280x500 still
    // passed with 2px of slack). Asking the service is what makes the check honest, and it
    // is the same table `setFamily()` writes to the file.
    PanelWindow {
        id: win
        visible: true
        implicitWidth: 260
        implicitHeight: 880
        color: "transparent"
        anchors { top: true; left: true }

        MediaWidget {
            id: full
            x: 6
            y: 6
            width: 248
            height: DesktopWidgetsService.naturalCard("media", "full").h - 32
        }
        MediaWidget {
            id: det
            x: 6
            y: 400
            width: 248
            height: DesktopWidgetsService.naturalCard("media", "detailed").h - 32
            family: "detailed"
        }
    }

    Process {
        id: sink
        command: ["/usr/bin/bash", "-c", "cat > " + (Quickshell.env("FIT_OUT") || "/tmp/fit") + ".log"]
        stdinEnabled: true
        onExited: Qt.quit()
    }

    // The artist row: the content Column's child that holds the caret glyph.
    function artistRowOf(w) {
        var body = w.children ? w.children[0] : null;
        if (!body) return null;
        var kids = body.children || [];
        for (var i = 0; i < kids.length; i++) {
            var gc = kids[i].children || [];
            for (var j = 0; j < gc.length; j++) {
                if (gc[j].text !== undefined && String(gc[j].text).indexOf("") >= 0)
                    return kids[i];
            }
        }
        return null;
    }

    // The three grabs are CHAINED, not fired together: three concurrent grabs in one tick
    // deadlocked and none of their callbacks ever ran (measured: the configuration loaded
    // clean, the sink never fired, no PNG appeared). One at a time, each from the next
    // callback, and a watchdog that reports whatever is missing rather than hanging.
    function save(item, name, then) {
        root.pending++;
        // NO size arguments: Quickshell's grabToImage takes only the callback, and the Qt
        // extras fail with "Too many arguments, ignoring 1" and write nothing. The result's
        // `url` is an in-memory `itemgrabber:#N`, not a file, so the write happens HERE
        // with `saveToFile` — inside the shell, before it quits.
        item.grabToImage(function (result) {
            var dest = Quickshell.env("FIT_OUT") + "-" + name + ".png";
            var ok = result.saveToFile(dest);
            root.log.push((ok ? "saved " : "SAVE FAILED ") + name + " -> " + dest
                          + " (grab url " + result.url + ")");
            root.pending--;
            if (then)
                then();
        });
    }

    function flush() {
        // `sink` is the Process's id in THIS scope; `root.sink` does not exist (an id is
        // not a property of the parent), and reading it threw the TypeError that silently
        // ate every run.
        sink.running = true;
        sink.write(root.log.join("\n") + "\n");
        leave.start();
    }

    function run() {
        var l = [];
        l.push("canChoose=" + full.canChoose + " players=" + MprisController.filteredPlayers.length
               + " player=" + (full.player ? full.player.identity : "none"));
        // The heights the service asked for, so a `fit` failure names the number that is
        // actually wrong rather than the one the harness hoped for.
        l.push("instantiated: full " + Math.round(full.width) + "x" + Math.round(full.height)
               + ", detailed " + Math.round(det.width) + "x" + Math.round(det.height)
               + " (service declares "
               + DesktopWidgetsService.naturalCard("media", "detailed").h + " of card)");
        var row = artistRowOf(full);
        if (!row) {
            l.push("FATAL: the artist row (the one carrying the caret) was not found");
            root.log = l;
            flush();
            return;
        }
        l.push("artist row w" + Math.round(row.width) + " h" + Math.round(row.height)
               + " y" + Math.round(row.y) + " vAlign=" + row.verticalAlignment);
        var kids = row.children || [];
        for (var i = 0; i < kids.length; i++) {
            var k = kids[i];
            if (k.text === undefined) continue;
            l.push("  child w" + Math.round(k.width) + " h" + Math.round(k.height)
                   + " y" + Math.round(k.y) + " vAlign=" + k.verticalAlignment
                   + " text=" + JSON.stringify(String(k.text).slice(0, 12)));
            // Force the caret on: it is `visible: canChoose` and there is one player.
            if (String(k.text).indexOf("") >= 0)
                k.visible = true;
        }
        root.log = l;
        save(row, "artist", function () {
            save(full, "full", function () {
                save(det, "detailed", flush);
            });
        });
        // The watchdog: a grab that never calls back must still produce a log, or the run
        // ends with an empty file and the failure looks like a missing harness.
        watchdog.start();
    }

    Timer {
        id: watchdog
        interval: 4000
        onTriggered: {
            root.log.push("WATCHDOG: fired with " + root.pending + " grab(s) outstanding");
            flush();
        }
    }

    Timer { id: leave; interval: 700; onTriggered: Qt.quit() }
    Timer { id: settle; interval: 2200; onTriggered: root.run() }
    Component.onCompleted: settle.start()
}
'''


def read_sizes():
    """Each family's card size, from the widget's own header — the number the harness
    measures against. Parsed, never copied: `tests/widget-family-menu.py` pins the same
    declaration against the service's table, and a drift between the two fails that."""
    src = (MOD / "overlays/modules/widgets/desktopwidgets/MediaWidget.qml").read_text()
    head = src[:src.find("Item {")]
    out = {}
    for fam, w, h in re.findall(r"//\s+(full|detailed)\s+\((\d+)x(\d+)\)", head):
        out[fam] = (int(w), int(h))
    return out


def active_generation():
    cfg = Path(os.path.expanduser("~/.config/ambxst/mods.json"))
    gen = json.loads(cfg.read_text())["activeGeneration"]
    return Path(os.path.expanduser("~/.local/share/ambxst/mods/generations")) / gen


def ink_bands(mask, axis=0):
    counts = mask.sum(axis=axis)
    bands, cur = [], None
    for i, n in enumerate(counts):
        if n:
            if cur is None:
                cur = [i, i]
            else:
                cur[1] = i
        elif cur:
            bands.append(tuple(cur))
            cur = None
    if cur:
        bands.append(tuple(cur))
    return bands


def load_gray(path):
    return np.asarray(Image.open(path).convert("L")).astype(float)


def check_caret(png):
    """The caret's ink centre against the artist text's ink centre, in the row's pixels."""
    gray = load_gray(png)
    thr = gray.max() * 0.35
    runs = ink_bands(gray > thr, axis=0)
    if len(runs) < 2:
        return None, [f"the row's grab shows {len(runs)} ink run(s); expected the artist "
                      f"text and the caret side by side"]

    def mid(x0, x1):
        sub = gray[:, x0:x1 + 1] > thr
        ys = np.nonzero(sub.any(axis=1))[0]
        return (ys.min() + ys.max()) / 2, int(ys.max() - ys.min() + 1)

    # The LAST run is the caret: it is the row's last Text child.
    tm, th = mid(*runs[-2])
    cm, ch = mid(*runs[-1])
    delta = cm - tm
    why = []
    if abs(delta) > CARET_TOL:
        why.append(f"the caret's ink sits {delta:+.1f}px off the artist line's centre "
                   f"(text {th}px tall, caret {ch}px tall, tolerance {CARET_TOL}px): it "
                   f"reads as a caret stuck to one side, not centred")
    return delta, why


def check_fit(png, label):
    """How much of the card below its last row is empty.

    The card's height comes from the GRAB, not from a number passed in: the probe
    instantiates each family at the size the service applies, so the image height IS the
    declared card's widget height. Reading it from the PNG is what keeps this check from
    passing on a hardcoded expectation.

    Rows come from LOCAL CONTRAST, not a brightness threshold: the card is translucent
    glass over a blurred wallpaper, so the glass itself can outshine a dim label and a
    fixed threshold reads the whole card as content (measured: at 120 the detailed card
    came back as one band edge to edge).
    """
    gray = load_gray(png)
    h = gray.shape[0]
    crop = gray[ART + 4:, :]                      # skip the artwork
    contrast = np.abs(np.diff(crop, axis=1)).mean(axis=1)
    ink = contrast > max(2.0, contrast.max() * 0.12)
    nz = np.nonzero(ink)[0]
    if not len(nz):
        return None, [f"{label}: nothing below the artwork to measure"]
    slack = (h - 1) - (int(nz[-1]) + ART + 4)
    why = []
    if slack > FIT_TOL:
        why.append(f"{label}: {slack}px of empty card below the last row in a widget "
                   f"{h}px tall (tolerance {FIT_TOL}px) — the declared card is taller than "
                   f"what it draws")
    return slack, why


def check_qml(stderr):
    """This card must load clean: no ReferenceError from a missing import."""
    hits = [l for l in stderr.splitlines()
            if "MediaWidget.qml" in l and re.search(r"ReferenceError|TypeError", l)]
    why = []
    if hits:
        why.append(f"{len(hits)} QML error(s) while the card loads, first: "
                   f"{hits[0].strip()[:140]}")
    return len(hits), why


def resolve_tree(args):
    """Which tree this run measures.

    `--generation DIR` measures a BUILT generation; the default is the active one. Neither
    is right while the fix is still only in the repo, so `--repo` stages the repo's own
    overlays over a copy of the active generation: the mod's files come from the working
    tree and everything else (the theme, the shell's own modules) from the generation, which
    is what a reload would run. Reading the repo files straight would not work: they import
    `qs.modules.theme` and `qs.config`, which live in the generation.
    """
    if args.repo:
        live = active_generation()
        stage = Path(tempfile.mkdtemp(prefix="media-fit-tree-"))
        # Copy into a FRESH directory, not over the generation: `copytree` with
        # `dirs_exist_ok` merges but did NOT overwrite an existing file here, so a stale
        # MediaWidget.qml survived and the run measured the wrong tree (it kept failing on
        # a line the repo had already fixed). Copy the generation, then FORCE the mod's
        # files over it.
        staged = stage / "gen"
        shutil.copytree(live, staged, symlinks=True)
        modules = staged / "modules"
        n = 0
        for src in sorted((MOD / "overlays" / "modules").rglob("*")):
            if src.is_dir():
                continue
            rel = src.relative_to(MOD / "overlays" / "modules")
            dst = modules / rel
            dst.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(src, dst)          # always the repo's bytes
            n += 1
        print(f"staged {n} mod file(s) from the repo over generation {live.name} "
              f"(module root: {modules})")
        return staged
    gen = Path(args.generation) if args.generation else active_generation()
    if not (gen / "modules").is_dir():
        print(f"no such generation: {gen}")
        return None
    return gen


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--generation", help="generation dir (default: the active one)")
    ap.add_argument("--repo", action="store_true",
                    help="measure the working tree: the repo's overlays staged over the "
                         "active generation, so a fix that is not deployed yet can be "
                         "measured without a reload")
    ap.add_argument("--keep", action="store_true", help="keep the temp dirs")
    args = ap.parse_args()

    tree = resolve_tree(args)
    if tree is None:
        return 2
    gen = tree if (tree / "modules").is_dir() else tree.parent
    modules = (tree / "modules") if (tree / "modules").is_dir() else tree

    sizes = read_sizes()
    if "full" not in sizes or "detailed" not in sizes:
        print(f"MediaWidget.qml's header declares {sorted(sizes)}, not both families")
        return 2
    print(f"declared card sizes: full {sizes['full'][0]}x{sizes['full'][1]}, "
          f"detailed {sizes['detailed'][0]}x{sizes['detailed'][1]}")

    work = Path(tempfile.mkdtemp(prefix="media-fit-"))
    failures = 0
    try:
        probe = work / "probe"
        probe.mkdir()
        (probe / "probe.qml").write_text(PROBE)
        os.symlink(modules, probe / "modules")
        os.symlink(gen / "config", probe / "config")
        out = work / "fit"
        env = dict(os.environ, FIT_OUT=str(out))
        p = subprocess.run(["timeout", "90", "qs", "-p", str(probe / "probe.qml")],
                           capture_output=True, text=True, env=env)

        log = out.with_suffix(".log")
        urls = {}
        if log.exists():
            print(log.read_text().rstrip())
            # The grabs report `itemgrabber:#N`, an in-memory Quickshell URL and NOT a
            # file on disk, so the bytes have to be written out by the shell itself:
            # `Quickshell.Io` has no copy helper for it, and the shell is quitting by the
            # time Python looks. Instead the probe saves each result through
            # `result.saveToFile` after the callback — that IS supported, and it is the
            # file write that has to happen inside the shell.
            for line in log.read_text().splitlines():
                m = re.match(r"saved (\S+) -> (\S+)", line.strip())
                if m and os.path.exists(m.group(2)):
                    urls[m.group(1)] = m.group(2)

        print()
        checks = [
            ("caret", lambda: check_caret(urls["artist"]) if "artist" in urls
                      else (None, ["the artist row's grab never landed"])),
            ("fit-full", lambda: check_fit(urls["full"], "full")
             if "full" in urls else (None, ["the full card's grab never landed"])),
            ("fit-detailed", lambda: check_fit(urls["detailed"], "detailed")
             if "detailed" in urls
             else (None, ["the detailed card's grab never landed"])),
            ("qml-clean", lambda: check_qml(p.stderr)),
        ]
        for name, fn in checks:
            value, why = fn()
            print(f"[{'PASS' if not why else 'FAIL'}] {name}"
                  + (f"  (measured {value})" if value is not None else ""))
            for w in why:
                print(f"       {w}")
            failures += 0 if not why else 1

        if failures:
            print(f"\nFAILED: {failures} of {len(checks)} checks")
            return 1
        print(f"\nPASS: {len(checks)} checks — the caret is centred, both cards fit what "
              f"they draw, and the card loads clean")
        return 0
    finally:
        if args.keep:
            print("kept:", work)
        else:
            shutil.rmtree(work, ignore_errors=True)


if __name__ == "__main__":
    sys.exit(main())