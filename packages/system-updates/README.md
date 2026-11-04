# system-updates (`and0null.system-updates`)

A compact Ambxst bar button that monitors pending system updates across official repositories (`pacman`), the AUR (`paru`/`yay`), Flatpak, and `mise`. The button stays hidden until updates are available.

---

## Installation

Install and enable straight from this repository:

```bash
ambxst mods install https://github.com/And0Null/ambxst-mods/tree/main/packages/system-updates
ambxst mods enable and0null.system-updates
ambxst reload
```

---

## Usage

- **Left-Click**: Opens the interactive update management card.
- **Right-Click**: Forces an immediate re-scan across all sources.

### Management Card

The popup card provides per-source indicators and controls:
- Individual re-scan buttons per package manager.
- **Scan all / Update all**: Runs updates in an interactive terminal window with tracked child process lifecycle.
- **Show in bar when up to date**: Optional toggle to keep a subtle checkmark badge in the bar even when no updates are pending.

---

## Behavior & Polling

- Scans on desktop startup, then polls periodically according to `refreshMinutes` (default: 30 minutes, configurable in **Ambxst Settings -> Mods -> System updates**).
- Background polling uses non-blocking child checks.
- When an update terminal closes, the mod automatically re-scans counts rather than relying on a fixed timeout.
- The `mise` checker monitors the global configuration (`~/.config/mise/config.toml`).

---

## Requirements

- `pacman`
- `checkupdates` (from `pacman-contrib`)
- AUR helper: `paru` (preferred) or `yay`
- Optional: `flatpak`, `mise` (rows activate only when installed)
