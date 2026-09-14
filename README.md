# Ambxst mods

Mods for the [Ambxst](https://github.com/Axenide/Ambxst) desktop shell (1.3+). Each
mod lives under `packages/<name>/` and installs straight from this repo — no clone
needed:

```bash
ambxst mods install https://github.com/AndoNull/ambxst-mods/tree/main/packages/<name>
ambxst mods enable <mod-id>
```

The manager keeps the source URL, so `ambxst mods update <mod-id>` picks up new commits
later.

---

## pkg-launcher — `and00pium.pkg-launcher` (v1.5.0)

A pacseek-style package launcher for Ambxst: type to search the sync repos (`pacman`)
and the AUR (`paru`) live, browse what you already have installed, and hand
install/remove/update off to an interactive terminal where `paru` owns the sudo prompt
and the progress output.

```bash
ambxst mods install https://github.com/AndoNull/ambxst-mods/tree/main/packages/pkg-launcher
ambxst mods enable and00pium.pkg-launcher
```

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
  ambxst mods enable and00pium.pkg-launcher
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
  Fetched lazily with `paru -Si` (debounced).
- **Installed / update state**: `✓ instalado` badges, and `↑ <new-version>` when an
  upgrade is pending (`pacman -Qu` + `paru -Qua`, refreshed on every open).
- **Keyboard first**: `↵` install · `Ctrl+D` remove · `Ctrl+U` update all (`paru -Syu`)
  · arrows navigate · `Esc` closes. Install/remove run in your terminal; the launcher
  never touches sudo itself.
- **Empty query browses your installed packages** (explicit ones, repos + AUR).

### Requirements

`paru` (used for search and every action) and `pacman`.

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

## desktop-widgets — `and00pium.desktop-widgets` (v0.1.0)

Rainmeter-style floating desktop widgets for Ambxst: a clock, a month calendar, a
weather card and a system-info card that live on the Wayland **background layer** —
above the wallpaper, below every window and the bar. Drag them anywhere by hand;
their positions are remembered.

```bash
ambxst mods install https://github.com/AndoNull/ambxst-mods/tree/main/packages/desktop-widgets
ambxst mods enable and00pium.desktop-widgets
```

### Features

- **Four widgets**: big digital clock with the full date, month-grid calendar
  (reuses Ambxst's dashboard calendar), weather card with a 3-day forecast strip
  (reuses Ambxst's dashboard weather widget and WeatherService), and a
  system-info card (CPU %, RAM %, battery, uptime — read from /proc).
- **Draggable anywhere**: open-hand drag, snap-free; positions are stored as
  *fractional* screen coordinates, so they survive resolution and layout changes.
- **Persisted** in `~/.local/state/ambxst/desktop-widgets.json` on drag end and on
  every menu change, debounced so drags don't thrash the disk.
- **Per-screen setup**: each monitor lives independently (per-screen positions and
  enable flags).
- **Management menu**: right-click any widget (or the command below). Per-widget
  on/off switches, overall opacity slider, "Reset positions", "Show all", "Hide all",
  close. `Esc` closes it.
- **Hover X** hides a single widget without opening the menu.

Open the menu with `ambxst run desktop-widgets` (bind it to a key, e.g. `SUPER+ALT+W`):

```lua
hl.bind("SUPER + ALT + W", hl.dsp.exec_cmd("ambxst run desktop-widgets"))
```

---

## Notes

- **Tested on base commit** `af9f8ad4` (listed in the manifest). Ambxst updates can move
  the patched lines.
- **Patches.** This mod patches `modules/services/Visibilities.qml`,
  `modules/services/GlobalShortcuts.qml` and `shell.qml`. Ambxst keeps two mods that only
  *insert* lines at the same anchor, but two mods that rewrite the *same existing lines*
  stop the build — check for overlaps before stacking mods.

## License

MIT — see [LICENSE](LICENSE).
