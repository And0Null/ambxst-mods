# Ambxst mods

Mods for the [Ambxst](https://github.com/Axenide/Ambxst) desktop shell (1.3+). Each
mod lives under `packages/<name>/` and installs straight from this repo — no clone
needed:

```bash
ambxst mods install https://github.com/And0Null/ambxst-mods/tree/main/packages/<name>
ambxst mods enable <mod-id>
```

The manager keeps the source URL, so `ambxst mods update <mod-id>` picks up new commits
later.

---

## pkg-launcher — `and0null.pkg-launcher` (v1.6.0)

A pacseek-style package launcher for Ambxst: type to search the sync repos (`pacman`)
and the AUR live, browse what you already have installed, and hand install/remove/update
off to an interactive terminal where your chosen AUR helper owns the sudo prompt and the
progress output.

```bash
ambxst mods install https://github.com/And0Null/ambxst-mods/tree/main/packages/pkg-launcher
ambxst mods enable and0null.pkg-launcher
```

### AUR helper: paru or yay (Settings)

The AUR side runs through whichever helper you pick — **paru** (default) or **yay**.
Pick it in **Ambxst Settings → Mods → Package launcher → AUR helper**, no config files
to edit:

1. Open Ambxst Settings, find the Package launcher mod, set **AUR helper** to `paru`
   or `yay`.
2. The setting needs a shell restart to take effect — run `ambxst reload` (Ambxst will
   also tell you a rebuild/restart is needed).
3. If the chosen binary is not installed, the launcher says so on open
   (`<helper> not found — AUR disabled`) and keeps the `pacman` repo search working;
   install/remove/update-all are blocked until you install the helper.

Requirements: `pacman`, plus the helper you select (`paru` or `yay`).

Open it with `ambxst run pkg-launcher`. There is **no default keybind** — bind it
yourself, e.g. `SUPER+SHIFT+P`:

```lua
hl.bind("SUPER + SHIFT + P", hl.dsp.exec_cmd("ambxst run pkg-launcher"))
```

Or launch it from any app launcher/menu — drop the
`extras/Package Launcher.desktop` into `~/.local/share/applications/`.

### Troubleshooting

- **Keybind does nothing / `ambxst run pkg-launcher` is not a known command** —
  the mod registers its command at shell build time. Make sure it's enabled and
  the shell was rebuilt after installing:

  ```bash
  ambxst mods enable and0null.pkg-launcher
  ambxst reload
  ```

- **You installed an old release** (published when the GitHub username was
  `AndoNull` and the mod id was `and00pium.pkg-launcher`). Both the repo URL and
  the mod id have since changed — username is now `And0Null` (zero, not "o") and
  the id is `and0null.pkg-launcher`. Ambxst treats the id as the mod's identity and
  refuses the change on update — `ambxst mods update` prints
  `Error: updated package changed its id`. Reinstall from the new URL instead:

  ```bash
  ambxst mods remove and00pium.pkg-launcher
  ambxst mods install https://github.com/And0Null/ambxst-mods/tree/main/packages/pkg-launcher
  ambxst mods enable and0null.pkg-launcher
  ambxst reload
  ```

### Screenshots

Search with the details pane (here a repo package that's already installed):

![Search](screenshots/search.png)

Empty query browses your installed packages:

![Installed](screenshots/installed.png)

AUR variants, with votes / popularity / maintainer / deps:

![AUR](screenshots/aur.png)

### Features

- **Live search** across repos + AUR: repo results show instantly, AUR results merge in
  when they arrive (the query is passed as an argument, never interpolated into a shell
  string).
- **Relevance ordering**: exact name → name starts with the term → name contains it →
  description-only matches. Alphabetical within each band.
- **Details pane** for the selection: download/installed size and deps for repo
  packages; votes, popularity, maintainer and out-of-date flag for AUR packages; URL.
  Fetched lazily with `<helper> -Si` (debounced).
- **Installed / update state**: `✓ instalado` badges, and `↑ <new-version>` when an
  upgrade is pending (`pacman -Qu` + `<helper> -Qua`, refreshed on every open).
- **Keyboard first**: `↵` install · `Ctrl+D` remove · `Ctrl+U` update all (`<helper> -Syu`)
  · arrows navigate · `Esc` closes. Install/remove run in your terminal; the launcher
  never touches sudo itself.
- **Empty query browses your installed packages** (explicit ones, repos + AUR).

### Requirements

`pacman`, plus the AUR helper selected in the mod's **Settings** (`paru`, the default,
or `yay`). If the selected helper is missing, the launcher disables the AUR side with a
clear message until you install it.

### Optional extras (`extras/`)

- **`Package Launcher.desktop`** — drop it in `~/.local/share/applications/` to launch
  the mod from any app launcher/menu (replace `<user>` with your username, then
  `update-desktop-database ~/.local/share/applications`).
- **`pkg-icon-sync`** — an app icon that **follows your wallpaper**: it renders the
  Phosphor "cube" glyph on a `primary` tile with the `overPrimary` glyph, straight from
  `~/.cache/ambxst/colors.json`. It writes a content-addressed icon (to defeat the icon
  caches) and repoints the `.desktop`. Point a matugen post_hook at it and the icon
  updates with every theme change:

  ```toml
  [templates.pkg-icon]
  input_path = "~/.cache/ambxst/colors.json"
  output_path = "~/.cache/narciss/pkg-icon-stamp"
  post_hook = "sleep 2; $HOME/.local/bin/pkg-icon-sync >/dev/null 2>&1"
  ```

  (needs `python3` with `Pillow` and the Phosphor font.)

---

## desktop-widgets — `and0null.desktop-widgets` (v1.8.0, staging)

> **Not published yet.** This mod is still in `staging/` (gitignored), so the install
> command below does not resolve until it moves to `packages/`.

Widgets on your desktop, not in the dashboard: a clock, a month calendar, a weather
card and a system card (CPU/temp/RAM, and GPU when detected) floating in liquid-glass
cards on an input-transparent **Bottom layer** — above the wallpaper, under every
window, like desktop icons. They step aside while a fullscreen window owns the
output, and a management menu adds/removes widgets, sets their opacity and toggles a
drag-to-move edit mode.

```bash
ambxst mods install https://github.com/And0Null/ambxst-mods/tree/main/packages/desktop-widgets
ambxst mods enable and0null.desktop-widgets
```

### Widget types

- `clock` — big time, long date, year.
- `calendar` — the month grid, and a week strip in the compact family. The month
  arithmetic is the dashboard calendar's (`layout.js`, reused); the grid itself is this
  mod's, so the cells are what scales with the card.
- `weather` — current condition, temperature, wind and sunrise/sunset from
  Ambxst's WeatherService.
- `system` — CPU (with temperature), RAM and GPU usage as labelled bars.

### Content families

A card can ask for three amounts of information through `family`: `compact`, `full`
(default) or `detailed`. They are three amounts of content, never the same thing made
smaller — the height you give the card decides how much of it arrives.

| widget | `compact` | `full` | `detailed` |
|---|---|---|---|
| `clock` | time and short date, one line | time, long date, year | + seconds and where the day sits (`Week 38 · Day 260`) |
| `weather` | symbol, temperature, condition, one line | condition, today's range, wind, sun times | + the next six days as a strip |
| `system` | CPU, RAM and GPU percentages, one line | the labelled bars: CPU with its temperature, RAM used/total, GPU usage | + the GPU's temperature, the CPU history as a sparkline, and the disk line on cards tall enough to pay for it |
| `calendar` | the week in progress: seven day cells, today highlighted, the ISO week number beside them | the month grid: month and year with the two month arrows, the weekday row, six weeks of days, today highlighted and its week tinted | + the ISO week and the day of the year, on cards tall enough to pay for the line |

**The type scale.** A card's size drives the type size. At a family's normal card size
(280x80 for `compact`, 280x190 for the stacked ones, 360x360 for the calendar) the widget
renders its base sizes — a card that already looked right keeps looking the same — and a
taller card spends the extra height on **bigger text** instead of on more empty glass. Two
limits keep that honest: the type is never shrunk below its base size, and it never grows
past the width its longest line needs, so a date never elides out of the card. Very tall
cards stop growing at that width cap.

The calendar is the exception that proves the rule: a seven-column grid cannot elide a
column the way a line of text can, so its cells are fitted to **both** axes by
`WidgetType.blockScale()` — the same ceiling, but a grid on a card smaller than its normal
one shrinks (the cells stay square and the whole month stays visible) instead of hanging
out of the glass. Both rules live in `WidgetType.js`; `tests/type-scale.js` fails if a
widget ships a private copy of either.

Rows that only exist in `detailed` (the forecast strip, the sparkline, the disk line, the
calendar's date line) are dropped when the card is too short for them once the type is
scaled, instead of being squeezed in.

### Layout file

The layout lives in `~/.config/ambxst/desktop-widgets.json`. A card's position is an
**anchor**: which edge it sticks to on each axis, plus its distance to that edge in
pixels. Sizes and distances are intrinsic, so the layout — the gaps between cards and
the margins to the screen edge — is the same on every resolution, on one monitor or
several, and a 4K output does not spread the widgets apart. `enabled: false` keeps a
widget (with its position) hidden instead of deleted:

```json
{
    "design": "custom",
    "opacity": 0.42,
    "widgets": [
        { "type": "clock", "ax": "left", "ox": 57, "ay": "top", "oy": 88, "w": 280, "h": 190, "enabled": true, "family": "full" },
        { "type": "calendar", "ax": "center", "ox": 0, "ay": "bottom", "oy": 100, "w": 360, "h": 360, "enabled": true, "family": "full" },
        { "type": "group", "direction": "row", "ax": "left", "ox": 40, "ay": "top", "oy": 48, "w": 810, "h": 222,
          "children": [{ "type": "system", "family": "full" }, "weather", "clock"] }
    ]
}
```

`ax` is `left`/`right`/`center` and `ay` is `top`/`bottom`/`center`, with `ox`/`oy` as
pixels from those edges; `center` ignores the offset and pins the card to the middle of
the output, which is what keeps it centred at any resolution. A `group` entry lays its
`children` out as a `column` (default) or a `row`. `family` — per entry and per group
child — is carried through the file for future widget variants; nothing reads it yet, but
saving a layout never drops it. The top-level `design` field records which design the
layout came from, or `custom` once it has been edited by hand. A file that still stores
screen *fractions* (`x`/`y`) is converted once, using the biggest connected output as the
reference, so the placement you already had is preserved; the first change you make
rewrites the file in the new shape.

The menu and the drag flow write every change back through the service (debounced
during drags, saved on drag end). A drop stores the nearest edge on each axis, keeping
the side the card already had while it lands in the dead zone around the middle (half a
card wide), so nudging a centred card cannot flip its anchor and move it on another
output. Pixel distances mean the same thing everywhere, so dragging on one monitor can
no longer change where a card sits on the other.

On a screen too small for the layout's own distances (under ~740px tall for the
calendar here) a card is clamped back on screen instead of hanging off the edge, and two
cards can then touch: the arrangement takes the room it takes, and there is no scale
that fits all of it everywhere.

### Managing widgets

Open the management menu with `ambxst run desktop-widgets` (bind it to a key, e.g.
`SUPER+ALT+W`):

```lua
hl.bind("SUPER + ALT + W", hl.dsp.exec_cmd("ambxst run desktop-widgets"))
```

From there you can toggle each widget's visibility, remove it, add clock/calendar/
weather/system widgets, set the card opacity with a slider, reset to the default
layout or hit **Done**. `Esc` closes the menu.

The calendar's two arrows move it a month at a time, and clicking the month name returns
to the month in progress — the widget outlives the menu that opened it, so a shifted month
would otherwise be a dead end. On the desktop, in the month grid, the week today sits in
is tinted and the days from the neighbouring months are dimmed.

To move widgets around, flip **Edit layout** on: cards get a highlighted border and
become draggable (open-hand cursor); drag them, then click **Done** to commit.

While you drag, the card snaps to the edges and centres of the other cards (and to a
40px screen margin) once it is within 6px, and a 1px guide line shows what it lined up
with. That is the only way to get two cards exactly on the same line — hand-placed
cards look hand-placed. Because the snap is stored as an anchor, two aligned cards stay
aligned at every resolution.

### Designs

The arrangement comes from a **design**, applied in one click from the picker at the top
of the menu: `Split` (four cards in the corners — the default), `Rail` (a column plus the
calendar), `Studio` (one card holding clock, weather and system, plus the calendar),
`Row` (the same three side by side), `Cluster` (a tight 2x2 block), `Minimal` (clock and
calendar) and `Center` (a centred pair, top and bottom). Each button draws a real
miniature of its design — the entries are placed with the same anchor arithmetic the
desktop uses, on a 1920x1080 reference, then scaled down — so a preview cannot show
something applying the design would not do.

Designs are plain data (`DesktopWidgetsService.designs`), and every one of them has to
obey rules that are checked against pixels rather than eyeballed:

- **Fits the smallest desktop** (1366x768 here): a card that does not fit gets clamped and
  overlaps its neighbour, so no design may rely on the clamp.
- **Clears the bar**, which draws over the output and measured hides the first 45px: a
  card's top starts at 48 at the earliest.
- **Clears the dock**, which is not part of the widget layer: on a 768-tall output it
  covers the last 71 rows of the middle ~520 columns, so a card overlapping that band has
  to end above it.
- **No overlaps**, and a group card must leave each child at least 200x150 to render in.

**Align** lines up the layout you already have, in one click: per axis and anchor side,
cards whose offsets differ by up to 40px are treated as an accident and share the
largest offset (so nothing moves closer to the screen edge), while cards further apart
are a deliberate stack or another column and keep their own offsets.

The **Card opacity** slider is the cards' own alpha: how much of the wallpaper shows
through the glass. It fades the text along with the frame, and the glass's *colour* is
not set here — that comes from the shell palette (`colors.json`).

### Verification

Measured, not eyeballed: capture the output twice — cards drawn, then every entry set
to `enabled: false` — and diff the two PNGs, because the differing pixels are exactly
the cards, so their boxes can be measured. A headless output makes a repeatable bench
(`hyprctl output create headless`, set its mode, capture its region, remove it). The
same layout on it:

| output | clock | weather | system (right margin) | calendar (right margin) |
|---|---|---|---|---|
| 1366x768 | 57,88 | 65,323 — 45px gap | 1007 (79px) | 960 (46px) |
| 1920x1080 | 57,88 | 65,323 — 45px gap | 1561 (79px) | 1514 (46px) |
| 2560x1440 | 57,88 | 65,323 — 45px gap | 2201 (79px) | 2154 (46px) |

Every box matched the predicted anchor within 1px of antialiasing and the two left cards
keep their 45px gap on all three. The same measurement taken on the previous
fraction-based layout overlapped those two cards by 22px on the 1366x768 panel and
pushed the calendar 71px off its right edge.

---

## Notes

- **Tested on base commit** `af9f8ad4` (listed in the manifest). Ambxst updates can move
  the patched lines.
- **Patches.** This mod patches `modules/services/Visibilities.qml`,
  `modules/services/GlobalShortcuts.qml` and `shell.qml`. Two mods inserting at
  *different* anchors compose; two hunks that share context lines do not, even when both
  only insert. That is why the Visibilities module name is registered at runtime by the
  service instead of being appended to `moduleNames` with a patch — pkg-launcher already
  inserts there.

## system-updates — `and0null.system-updates` (v1.1.0)

A compact bar button that shows pending system updates (pacman + AUR + flatpak), and
only appears when there is something to do. Left-click opens a management card with a
row per source (state, re-scan, on/off, update), **Scan all** / **Update all**, and a
"show when up to date" option. Right-click forces a full re-check.

```bash
ambxst mods install https://github.com/And0Null/ambxst-mods/tree/main/packages/system-updates
ambxst mods enable and0null.system-updates
```

### The card

```
pacman   12   ↻   [ On ]  [ Update ]
AUR       3   ↻   [ On ]  [ Update ]
flatpak   ✓   ↻   [ On ]  [ Off  ]
[   Scan all   ]  [   Update all   ]
Show in bar when up to date        [ On ]
```

- **Per source**: re-scan just that source, include it in the automatic scans, or update
  it alone.
- **Scan all / Update all** cover every enabled source.
- **Show in bar when up to date**: off (default) hides the button when everything is up
  to date; on keeps it with a green check.

### Behavior

- Scans shortly after the shell starts, then every `refreshMinutes` (default 30 —
  change it in **Ambxst Settings → Mods → System updates**, along with
  `externalOnly`).
- Each source reports its own state: `off` when not scanned, `!` on failure, `–` when it
  has never been scanned, the number when updates are pending, `✓` when it is up to
  date. A failed or never-scanned source is never shown as up to date.
- The updater runs in your terminal as a tracked child process, so the counts are
  re-scanned when the terminal actually closes — not after a guessed delay. While an
  update runs, further update clicks are ignored.
- A local `pacman -Qu` poll notices updates applied outside the mod and refreshes the
  counts.

### Requirements

`pacman` and `checkupdates` (pacman-contrib). The AUR row needs `paru` (preferred) or
`yay`; the flatpak row appears only when flatpak is installed. Sources you do not use can
be switched off in the card.

### Verification

`tests/run.sh` runs a behavioral test of the service against the real source under
Quickshell, covering the per-source state machine and the update guard. It is
falsifiable: breaking `sourceState()` fails the run. The mod was also loaded from a
built generation on Ambxst 1.3.3 (`af9f8ad4`) with no QML errors or warnings.

### Notes

- Patch surface: **`modules/bar/BarContent.qml` only** (two insertions, for the
  horizontal and vertical bar). The card reuses Ambxst's own `BarPopup`, so no
  `Visibilities.qml` patch is needed.
- The patch inserts at `@@ -520` / `@@ -727`; other mods that insert elsewhere in
  `BarContent.qml` (e.g. desktop-widgets at `@@ -1016`) compose cleanly. Two hunks
  sharing context lines would not.

## License

MIT — see [LICENSE](LICENSE).
