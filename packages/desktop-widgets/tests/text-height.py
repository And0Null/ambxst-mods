#!/usr/bin/env python3
"""How tall the text inside a card really is — a number, straight from a capture.

Usage: text-height.py IMAGE X Y W H [THRESHOLD | --extent]

--extent reports how far the content reaches inside the rectangle: the first and last rows
that carry text, and the distance from each card edge. Text is found by local contrast
(a row whose brightest pixel stands out from that row's glass by 20 levels), which is
robust where an absolute threshold is not: the card's own glass can be brighter than a dim
line, and then a low threshold reads the whole card as text.

Pass THRESHOLD to look for dimmer lines. Careful: too low also catches the card's own
glass where the wallpaper behind it is bright (at 120 the whole card read as one band),
so the adaptive default is the one to use for text. Comparing the OFFSET of the first
band from the card's edge is the sensitive check for "same type size" — ink height alone
moves a pixel with the digits that happen to be on screen.

Prints, top to bottom, every band of bright pixels inside that rectangle. Each band is a
line of text, so the first band's height is the headline's cap height. This is how "the
text grew with the card" gets verified instead of eyeballed.
"""
import sys

import numpy as np
from PIL import Image


def bands(gray, x, y, w, h, threshold):
    crop = gray[y:y + h, x:x + w]
    rows = (crop > threshold).sum(axis=1)
    out, start = [], None
    for i, n in enumerate(rows):
        if n >= 2 and start is None:
            start = i
        elif n < 2 and start is not None:
            out.append((start + y, i - 1 + y))
            start = None
    if start is not None:
        out.append((start + y, h - 1 + y))
    return out


def main():
    path, (x, y, w, h) = sys.argv[1], tuple(int(v) for v in sys.argv[2:6])
    gray = np.asarray(Image.open(path).convert("L")).astype(int)

    if "--extent" in sys.argv:
        pad_x, pad_y = 8, 6                      # stay clear of the card's border hairline
        inner = gray[y + pad_y:y + h - pad_y, x + pad_x:x + w - pad_x]
        rows = np.where(inner.max(axis=1) - np.median(inner, axis=1) > 20)[0]
        print(f"{path.split('/')[-1]}  región x{x} y{y} {w}x{h}")
        if not len(rows):
            print("  sin texto")
        else:
            first, last = int(rows[0]) + y + pad_y, int(rows[-1]) + y + pad_y
            print(f"  el contenido va de y{first} a y{last} ({last - first + 1}px): "
                  f"{first - y}px del borde de arriba, {y + h - 1 - last}px del de abajo")
        return

    crop = gray[y:y + h, x:x + w]
    # the text is the brightest thing inside a card; the glass around it is dark
    threshold = int(sys.argv[6]) if len(sys.argv) > 6 else int(np.percentile(crop, 99)) - 10
    print(f"{path.split('/')[-1]}  región x{x} y{y} {w}x{h}  "
          f"(p50 {int(np.percentile(crop, 50))}, p99 {int(np.percentile(crop, 99))}, "
          f"umbral de tinta {threshold})")
    found = bands(gray, x, y, w, h, threshold)
    if not found:
        print("  sin texto")
    for i, (y0, y1) in enumerate(found):
        label = "renglón principal" if i == 0 else f"renglón {i + 1}"
        print(f"  {label}: y{y0}..{y1}  altura {y1 - y0 + 1}px  a {y0 - y}px del borde")


def extent(path, x, y, w, h, inset=4):
    """Vertical extent of anything with local contrast inside a card: text, whatever its
    brightness. The glass over a blurred wallpaper is smooth, so rows that are NOT smooth
    are ink — which is what makes this able to see the dim lines a brightness threshold
    misses. Rows within `inset` px of the card's edge are skipped: the card's own hairline
    border is a sharp edge too."""
    gray = np.asarray(Image.open(path).convert("L")).astype(float)
    crop = gray[y + inset:y + h - inset, x + inset:x + w - inset]
    # local contrast per row: how much neighbouring pixels differ
    contrast = np.abs(np.diff(crop, axis=1)).mean(axis=1)
    ink = contrast > max(2.0, contrast.max() * 0.12)
    rows = np.where(ink)[0]
    if not len(rows):
        print("  sin tinta detectable")
        return None
    first, last = rows[0] + inset, rows[-1] + inset
    print(f"  contenido: de y{y + first} a y{y + last} (alto {last - first + 1}px); "
          f"borde inferior de la tarjeta y{y + h}, margen interno y{y + h - 16}")
    return first, last


if __name__ == "__main__":
    if len(sys.argv) > 2 and sys.argv[2] == "--extent":
        extent(sys.argv[1], *(int(v) for v in sys.argv[3:7]))
    else:
        main()
