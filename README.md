# Ambxst Mods

Modular modifications for the [Ambxst](https://github.com/Axenide/Ambxst) desktop shell (1.3+).

This repository is organized as a monorepo containing standalone desktop packages. Each package installs directly from this repository without requiring a full clone:

```bash
ambxst mods install https://github.com/And0Null/ambxst-mods/tree/main/packages/<package-name>
ambxst mods enable <mod-id>
ambxst reload
```

---

## Mod Catalog

| Mod | Package Directory | Mod ID | Version | Description | Quick Install |
|---|---|---|---|---|---|
| **pkg-launcher** | [`packages/pkg-launcher`](packages/pkg-launcher/) | `and0null.pkg-launcher` | v1.6.1 | Pacseek-style package search and installer for pacman and AUR (paru/yay). | `ambxst mods install https://github.com/And0Null/ambxst-mods/tree/main/packages/pkg-launcher` |
| **desktop-widgets** | [`packages/desktop-widgets`](packages/desktop-widgets/) | `and0null.desktop-widgets` | v1.19.0 | Liquid-glass desktop widgets (clock, calendar with iCal, weather, system, MPRIS player). | `ambxst mods install https://github.com/And0Null/ambxst-mods/tree/main/packages/desktop-widgets` |
| **system-updates** | [`packages/system-updates`](packages/system-updates/) | `and0null.system-updates` | v1.2.1 | Compact bar indicator and interactive updater for pacman, AUR, Flatpak, and mise. | `ambxst mods install https://github.com/And0Null/ambxst-mods/tree/main/packages/system-updates` |
| **lan-share** | [`packages/lan-share`](packages/lan-share/) | `and0null.lan-share` | v1.3.2 | LocalSend LAN peer discovery, clipboard sync, and file transfer with UFW firewall diagnostics. | `ambxst mods install https://github.com/And0Null/ambxst-mods/tree/main/packages/lan-share` |

---

## Management & Updates

### Updating Installed Mods
Ambxst preserves source URLs upon installation. To check for updates and pull the latest changes:

```bash
ambxst mods update <mod-id>
ambxst reload
```

### Removing a Mod
To disable and uninstall a mod cleanly:

```bash
ambxst mods disable <mod-id>
ambxst mods remove <mod-id>
ambxst reload
```

---

## Patch Composition & Quality Checks

Mods that patch core Ambxst QML files include git pre-image blob indexes to allow clean 3-way merges when multiple mods touch adjacent anchors.

Run the automated patch composition suite across all supported Ambxst versions:

```bash
# Check all packages across all Ambxst releases in range
extras/mod-composition-check.sh

# Check a single package
extras/mod-composition-check.sh packages/lan-share
```

The check verifies that:
- Every mod applies cleanly against base Ambxst releases declared in its manifest.
- Three-way merge fallbacks succeed without leaving conflict markers.
- Composed QML files contain no undeclared imports or broken property bindings.

---

## License

MIT License. See [LICENSE](LICENSE) for details.
Upstream licenses and third-party notices are preserved in each package's `NOTICES.txt`.
