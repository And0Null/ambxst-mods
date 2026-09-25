#!/usr/bin/env python3
"""Capture the four widgets in their tiers side by side on a HEADLESS output.

Two rows of the same four cards: the top row at the families the designs place (clock,
weather and system at `full`, the calendar at `full`), the bottom row at each card's
`compact` — the tier the menu applies when you pick Minimal, which is also the size that
tier declares (280x80, and 280x112 for the calendar's week).

    family-size-preview.py            # the two rows above, into the default out dir

The user's own layout is backed up and restored byte-exact, and nothing is measured on
their screens: a Bottom-layer surface is invisible under any maximized window there, and
staging a design on the screen they are working on is exactly what this avoids. The two
traps this shares with tests/calendar-scale-preview.py (a headless output comes up at
scale 2; a fixed sleep catches the PREVIOUS layout) are handled the same way: force
scale 1 and wait for the screen to stop changing.
"""
import json
import os
import subprocess
import sys
import time

import numpy as np
from PIL import Image

CFG = os.path.expanduser("~/.config/ambxst/desktop-widgets.json")
OUTDIR = os.path.expanduser("~/.local/state/ambxst/family-size-preview")

GAP, LEFT, TOP = 32, 48, 48
ROWS = [
    ("full", [("clock", 280, 190), ("weather", 280, 190), ("system", 280, 190),
              ("calendar", 360, 360)]),
    ("compact", [("clock", 280, 80), ("weather", 280, 80), ("system", 280, 80),
                 ("calendar", 280, 112)]),
]
CROP_W, CROP_H = 1400, 620
OUTPUT_MODE = "1920x1080"


def sh(*a):
    return subprocess.run(a, capture_output=True, text=True).stdout


def monitors():
    return {m["name"]: m for m in json.loads(sh("hyprctl", "monitors", "-j"))}


def changed_fraction(a, b):
    """Share of pixels that differ. Never waits for identity: the bar clock ticks."""
    x = np.asarray(Image.open(a).convert("L")).astype(int)
    y = np.asarray(Image.open(b).convert("L")).astype(int)
    return float((np.abs(x - y) > 8).mean())


def settle(m, path, deadline=40):
    prev = None
    end = time.time() + deadline
    while time.time() < end:
        subprocess.run(["grim", "-g", f"{m['x']},{m['y']} {CROP_W}x{CROP_H}", path], check=True)
        if prev is not None and changed_fraction(prev, path) < 0.001:
            return
        prev = path + ".prev"
        subprocess.run(["cp", path, prev], check=True)
        time.sleep(0.7)
    raise SystemExit("the layout did not settle in 40s")


def force_scale1(out):
    for cmd in (["hyprctl", "output", out, "scale", "1"],
                ["hyprctl", "eval",
                 f'hl.monitor({{ output = "{out}", scale = 1, position = "auto" }})']):
        subprocess.run(cmd, capture_output=True, text=True)
        time.sleep(2.0)
        m = monitors().get(out)
        if m and m.get("scale") == 1:
            return m
    raise SystemExit(f"could not force scale 1 on {out}")


def throwaway_layout():
    """The two rows, anchored to the top-left of the output so the crop holds them."""
    cards, y = [], TOP
    for family, row in ROWS:
        x = LEFT
        for type_name, w, h in row:
            cards.append({"type": type_name, "ax": "left", "ox": x, "ay": "top", "oy": y,
                          "w": w, "h": h, "family": family,
                          "direction": "column", "enabled": True, "children": []})
            x += w + GAP
        y += max(h for _, _, h in row) + GAP
    return cards


def main():
    os.makedirs(OUTDIR, exist_ok=True)
    backup = os.path.join(OUTDIR, "layout-live.json")
    subprocess.run(["cp", CFG, backup], check=True)
    before_clients = sorted((c["class"], c["monitor"]) for c in
                            json.loads(sh("hyprctl", "clients", "-j")))
    known = set(monitors())
    sh("hyprctl", "output", "create", "headless")
    time.sleep(2.5)
    fresh = [n for n in monitors() if n not in known]
    if not fresh:
        raise SystemExit("the headless output did not appear")
    out = fresh[0]
    subprocess.run(["hyprctl", "output", out, "mode", OUTPUT_MODE], capture_output=True)
    time.sleep(1.5)
    print("previewing on", out, OUTPUT_MODE)
    m = force_scale1(out)

    live = json.load(open(backup))
    settle(m, os.path.join(OUTDIR, "before.png"))
    throwaway = dict(live)
    throwaway["widgets"] = throwaway_layout()
    json.dump(throwaway, open(CFG, "w"), indent=2)
    shot = os.path.join(OUTDIR, "tiers.png")
    settle(m, shot)

    moved = changed_fraction(os.path.join(OUTDIR, "before.png"), shot)
    if moved < 0.01:
        raise SystemExit(f"the throwaway layout did NOT take effect ({moved:.4%} changed)")

    subprocess.run(["cp", backup, CFG], check=True)
    settle(m, os.path.join(OUTDIR, "restored.png"))
    same = subprocess.run(["diff", "-q", backup, CFG]).returncode == 0
    after_clients = sorted((c["class"], c["monitor"]) for c in
                           json.loads(sh("hyprctl", "clients", "-j")))
    sh("hyprctl", "output", "remove", out)
    print(f"layout applied ({moved:.2%} changed), restored byte-exact: {same}")
    print("windows moved:", "none" if before_clients == after_clients else
          f"{before_clients} -> {after_clients}")
    print("capture:", shot)
    return 0 if same else 1


if __name__ == "__main__":
    sys.exit(main())
