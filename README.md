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

## desktop-widgets — `and0null.desktop-widgets` (v1.2.1, staging)

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
- `calendar` — the dashboard's month-grid calendar, reused as-is.
- `weather` — current condition, temperature, wind and sunrise/sunset from
  Ambxst's WeatherService.
- `system` — CPU (with temperature), RAM and GPU usage as labelled bars.

### Layout file

The layout lives in `~/.config/ambxst/desktop-widgets.json`. Positions are
*fractions* of the screen while card sizes are intrinsic pixels, so one layout follows
every monitor: a card whose fractional position does not fit on a narrower output is
clamped back onto it (8px off the edge) instead of hanging off the screen, while cards
that do fit are drawn exactly where the fractions put them. `enabled: false` keeps
a widget (with its position) hidden instead of deleted:

```json
{
    "opacity": 0.42,
    "widgets": [
        { "type": "clock", "x": 0.04, "y": 0.06, "w": 280, "h": 190, "enabled": true },
        { "type": "calendar", "x": 0.68, "y": 0.72, "w": 360, "h": 360, "enabled": true },
        { "type": "group", "x": 0.04, "y": 0.7, "w": 300, "h": 240, "children": ["system", "weather"] }
    ]
}
```

The menu and the drag flow write every change back through the service (debounced
during drags, saved on drag end).

### Managing widgets

Open the management menu with `ambxst run desktop-widgets` (bind it to a key, e.g.
`SUPER+ALT+W`):

```lua
hl.bind("SUPER + ALT + W", hl.dsp.exec_cmd("ambxst run desktop-widgets"))
```

From there you can toggle each widget's visibility, remove it, add clock/calendar/
weather/system widgets, set the card opacity with a slider, reset to the default
layout or hit **Done**. `Esc` closes the menu.

To move widgets around, flip **Edit layout** on: cards get a highlighted border and
become draggable (open-hand cursor); drag them, then click **Done** to commit.

### Verification

The clamp is checked against real screens instead of by eye: capture the desktop with
the cards drawn and again with every entry set to `enabled: false`, then diff the two
PNGs — the differing pixels are exactly the cards, so their boxes can be measured. On a
1920x1080 output paired with a 1366x768 panel the measured boxes match
`x = min(entry.x · W, W − w − 8)` within 1px of antialiasing, and a card pushed to
`x: 0.95, y: 0.95` lands 8px off the corner of the narrow screen instead of 291px
outside it.

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
