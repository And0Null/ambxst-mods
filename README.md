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

- **You installed an old release under the `and00pium.` id** (the repo was renamed
  to `And0Null` and the mod id became `and0null.pkg-launcher`). Ambxst refuses the
  id change on update — `ambxst mods update` prints `Error: updated package changed
  its id`. Reinstall from the new URL instead:

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

## desktop-widgets — `and0null.desktop-widgets` (v1.1.0)

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
*fractions* of the screen, so one layout fits every monitor; `enabled: false` keeps
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

## License

MIT — see [LICENSE](LICENSE).
