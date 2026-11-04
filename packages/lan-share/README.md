# lan-share (`and0null.lan-share`)

LocalSend protocol integration for the Ambxst desktop shell. Provides local network peer discovery, text and file transfers, and automated host firewall diagnostic warnings.

---

## Installation

Install and enable straight from this repository:

```bash
ambxst mods install https://github.com/And0Null/ambxst-mods/tree/main/packages/lan-share
ambxst mods enable and0null.lan-share
ambxst reload
```

**Note**: The receiver starts **OFF** by default. Right-click the bar button to toggle the receiver on.

---

## Features

- **Peer Discovery**: Automatically detects LocalSend peers on your local network, displaying device name, model, and device type.
- **Clipboard Text Sharing**: Sends Wayland clipboard content (`wl-paste`) directly to a selected peer.
- **File Transfers**: Integrated file picker (`zenity`) supporting single or multiple files with remember-last-directory support.
- **Incoming Transfers**: Accept or decline incoming files. Files save automatically to `~/Downloads` with collision-safe suffixes and desktop notifications (`notify-send`).
- **Firewall Diagnostics**: Monitors the system journal for UFW drops on port 53317 and provides a one-click button to copy correct RFC1918 firewall rules.

---

## Firewall Configuration (UFW)

LocalSend requires inbound access to **TCP and UDP port 53317**. To prevent issues when switching between Wi-Fi and phone hotspots, scope your UFW rules to RFC1918 private subnets:

```bash
sudo ufw allow from 192.168.0.0/16 to any port 53317 proto tcp
sudo ufw allow from 192.168.0.0/16 to any port 53317 proto udp
sudo ufw allow from 172.16.0.0/12 to any port 53317 proto tcp
sudo ufw allow from 172.16.0.0/12 to any port 53317 proto udp
```

To diagnose firewall drops manually:

```bash
journalctl --since -5m --no-pager | grep 'UFW BLOCK' | grep 53317
```

---

## Requirements

- `zenity` (file picker dialog)
- Wayland clipboard tools (`wl-copy`, `wl-paste`)
- `notify-send`
- Systemd `journalctl` (for active firewall drop warnings)
- Ambxst desktop shell 1.3+
