#!/usr/bin/env python3
"""Capture the desktop calendar at two card sizes on a headless output, for judging its scale.

Renders a throwaway layout (one 360x360 calendar card, one 540x540) on a headless
output, captures it, then restores the live layout byte-exact and removes the output.
Nothing is measured on the user's own screens: a Bottom-layer surface is invisible under
any maximized window there, and it would be staged on the screen they are using.

    calendar-scale-preview.py            # 360 vs 540, into the default out dir
    calendar-scale-preview.py 360 720    # other sizes
    calendar-scale-preview.py 720x400:detailed   # one card, one family

Two traps this script exists to avoid, both of which produced a useless image once:

- A headless output comes up with `scale = 2`, so a capture geometry written in logical
  coordinates silently returns a 2x image of the wrong region. Force `scale = 1` and check
  the monitor actually reports the size asked for.
- A fixed sleep lies. The shell re-reads the layout file when it feels like it, so a 3s
  wait can catch the PREVIOUS layout twice and the image then shows cards that were never
  placed. Wait for the screen to stop changing instead, and assert that the capture did
  change before trusting it.
"""
import json
import os
import subprocess
import sys
import time

import numpy as np
from PIL import Image

CFG = os.path.expanduser("~/.config/ambxst/desktop-widgets.json")
OUTDIR = os.path.expanduser("~/.local/state/ambxst/cal-scale-preview")
CROP_W, CROP_H = 1100, 760          # holds a 540 card at x440 plus its own margin
GAP, TOP = 48, 48                   # the same offsets the throwaway layout uses


def sh(*a):
    return subprocess.run(a, capture_output=True, text=True).stdout


def monitors():
    return {m["name"]: m for m in json.loads(sh("hyprctl", "monitors", "-j"))}


def changed_fraction(a, b):
    """Share of pixels that differ. Never waits for identity: the bar clock ticks."""
    x = np.asarray(Image.open(a).convert("L")).astype(int)
    y = np.asarray(Image.open(b).convert("L")).astype(int)
    return float((np.abs(x - y) > 8).mean())


def settle(m, path, deadline=30):
    """Capture until two shots in a row are identical enough that nothing moved."""
    prev = None
    end = time.time() + deadline
    while time.time() < end:
        subprocess.run(["grim", "-g", f"{m['x']},{m['y']} {CROP_W}x{CROP_H}", path],
                       check=True)
        if prev is not None and changed_fraction(prev, path) < 0.001:
            return
        prev = path + ".prev"
        subprocess.run(["cp", path, prev], check=True)
        time.sleep(0.7)
    raise SystemExit("the layout did not settle in 30s")


def force_scale1(out):
    """A headless output defaults to scale 2; force 1 so logical == physical pixels."""
    for cmd in (["hyprctl", "output", out, "scale", "1"],
                ["hyprctl", "eval",
                 f'hl.monitor({{ output = "{out}", scale = 1, position = "auto" }})']):
        subprocess.run(cmd, capture_output=True, text=True)
        time.sleep(2.0)
        m = monitors().get(out)
        if m and m.get("scale") == 1:
            return m
    raise SystemExit(f"could not force scale 1 on {out}")


def parse_spec(arg):
    """`720x400:detailed`, `540`, or `540:compact` — a card size and the family to ask for."""
    family = "full"
    if ":" in arg:
        arg, family = arg.split(":", 1)
    if "x" in arg:
        w, h = (int(v) for v in arg.split("x", 1))
    else:
        w = h = int(arg)
    return w, h, family


def main():
    specs = [parse_spec(v) for v in sys.argv[1:]] or [(360, 360, "full"), (540, 540, "full")]
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
    print("previewing on", out)
    m = force_scale1(out)

    live = json.load(open(backup))
    settle(m, os.path.join(OUTDIR, "before.png"))

    throwaway = dict(live)
    cards, ox = [], GAP
    for w, h, family in specs:
        cards.append({"type": "calendar", "ax": "left", "ox": ox, "ay": "top",
                      "oy": TOP, "w": w, "h": h, "family": family,
                      "direction": "column", "enabled": True, "children": []})
        ox += w + GAP
    throwaway["widgets"] = cards
    json.dump(throwaway, open(CFG, "w"), indent=2)
    shot = os.path.join(OUTDIR, "cards.png")
    settle(m, shot)

    # A layout change is thousands of pixels. If the capture barely moved, the file was
    # ignored (or the shell wrote its own state back) and the image must not be trusted.
    moved = changed_fraction(os.path.join(OUTDIR, "before.png"), shot)
    if moved < 0.01:
        raise SystemExit(f"the throwaway layout did NOT take effect "
                         f"(only {moved:.4%} of the screen changed) — image is not usable")
    print(f"throwaway layout applied ({moved:.2%} of the screen changed)")

    subprocess.run(["cp", backup, CFG], check=True)
    settle(m, os.path.join(OUTDIR, "restored.png"))
    same = subprocess.run(["diff", "-q", backup, CFG]).returncode == 0
    print("layout restored byte-exact:", same)
    after_clients = sorted((c["class"], c["monitor"]) for c in
                           json.loads(sh("hyprctl", "clients", "-j")))
    print("windows moved:", "none" if before_clients == after_clients else
          f"{before_clients} -> {after_clients}")
    sh("hyprctl", "output", "remove", out)
    print("capture:", shot)
    return 0 if same else 1


if __name__ == "__main__":
    sys.exit(main())
