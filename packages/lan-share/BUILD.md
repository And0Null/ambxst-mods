# Building the LAN Share helper

`payload/bin/lan-share-helper` is a prebuilt Rust binary because an Ambxst mod is
a set of file overlays and patches: `ambxst mods install` copies files, it never
compiles anything. Shipping the binary is what makes one-command install work.

The helper is not part of this repository's code. It is a build of
[`jfg96/omarchy-nearby`](https://github.com/jfg96/omarchy-nearby) (MIT), whose
`backend/` is the helper and whose `backend/vendor/localsend-rs` is a vendored,
modified copy of [`CrossCopy/localsend-rs`](https://github.com/CrossCopy/localsend-rs)
(MIT). The attribution is in [`NOTICES.txt`](NOTICES.txt).

## What the shipped binary is

| | |
| --- | --- |
| Path | `payload/bin/lan-share-helper` (overlayed to `modules/widgets/lanshare/bin/`) |
| Size | 8,991,248 bytes (8.57 MiB), stripped |
| Type | ELF 64-bit x86-64 PIE, dynamically linked |
| sha256 | `4e5ea58524cf3e5f3c0a82419c20c879288d879252047dc1ba5d1b6a76ff7f26` |

The mod accepts any helper reporting **>= 1.1.2**
(`overlays/modules/services/LanShareService.qml`, `minHelperVersion`).

This binary is **not byte-reproducible from public source**, and its reported
version is not an upstream pointer:

- It was built from a locally renamed tree that is not published here. The
  executable stores its settings and TLS identity under `lanshare-state`, its
  diagnostics say "Shared state directory", and no brand word from upstream
  survives in its strings.
- It contains state and error paths (`secure_state.rs`, session and rate-limit
  rejections) that do not exist at upstream tag `helper-v1.1.2`, although the
  binary reports `1.1.2`. Treat that number as a floor, not as a base commit.

Nothing about LocalSend itself differs: the wire protocol, the JSON IPC, the
port and the mod's expectations are the ones in upstream. What differs is
naming, the state directory path, and the exact code generation.

## Build from source

`scripts/build-helper.sh` fetches a pinned upstream commit and runs a release
build inside that checkout, so rustup uses the channel the tree pins for itself
in its `rust-toolchain.toml` instead of whatever stable happens to be installed:

```bash
packages/lan-share/scripts/build-helper.sh
# prints the built path, its reported version and its sha256
```

The artifact lands in `$OUT_DIR`, default
`${XDG_CACHE_HOME:-~/.cache}/lan-share-helper-build/lan-share-helper`, so the
disposable source checkout can be thrown away while the binary survives.

Pinned commit: `helper-v1.2.9` = `088d5a92e28ada9f6edfbf7f5c3281fa3539cd55`.

Equivalently, by hand:

```bash
git clone https://github.com/jfg96/omarchy-nearby
cd omarchy-nearby
git checkout helper-v1.2.9
cargo build --release --locked --manifest-path backend/Cargo.toml
# backend/target/release/omarchy-nearby-helper
```

To replace the copy this mod ships with your own build:

```bash
packages/lan-share/scripts/build-helper.sh --install
ambxst reload
```

A source build reports `1.2.9` and keeps its state in
`${XDG_STATE_HOME:-~/.local/state}/omarchy-nearby`. Both the settings and the TLS
identity live in that directory, so a swap starts from a new identity and a new
incoming PIN state. Restart the receiver after changing binaries: the service
starts the helper it finds when the receiver turns on.

## aarch64 and other architectures

The shipped artifact is x86-64 only; on anything else the overlay places a binary
the kernel cannot execute. Build for the host instead:

```bash
packages/lan-share/scripts/build-helper.sh --target aarch64-unknown-linux-gnu
```

Then copy the result to `modules/widgets/lanshare/bin/lan-share-helper` inside the
composed shell tree that `ambxst mods install` produced, and reload. A
cross-toolchain for the target is needed when you are not on it; the cross build
is not exercised from this repository, so the prebuilt aarch64 asset below is the
verified path for that architecture.

If you would rather not install Rust, upstream publishes verified assets for the
pinned tag (`helper-release.env` in that repo carries the same values):

| Asset | Size | sha256 |
| --- | --- | --- |
| `omarchy-nearby-helper-v1.2.9-linux-x86_64` | 9,179,000 | `7d4079795d4355f1a68d3cdec1f7dabce72cc7d64e1cd1236e84a59b23436ee2` |
| `omarchy-nearby-helper-v1.2.9-linux-aarch64` | 7,485,424 | `6384e0b6dd21ecd3c7aad3c3aed3c877f4258a913dd36999a2eec0908cb48e6b` |

## Checking the repo copy

```bash
packages/lan-share/scripts/build-helper.sh --check
```

It verifies the recorded checksums against the committed binary and reports the
pinned upstream tag. It does not build and does not touch the network.
