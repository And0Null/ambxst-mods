#!/usr/bin/env bash
# Build the LAN Share helper from upstream source (jfg96/omarchy-nearby, MIT).
#
# The mod ships a prebuilt payload/bin/lan-share-helper because Ambxst mods
# compose files and have no build step. This script rebuilds that helper from
# a pinned upstream commit so the build is auditable and so aarch64 users are
# not stuck with the x86_64 artifact.
#
#   ./build-helper.sh                 build for this machine (into $OUT_DIR)
#   ./build-helper.sh --install       ... and replace payload/bin/lan-share-helper
#   ./build-helper.sh --target aarch64-unknown-linux-gnu
#   ./build-helper.sh --check         verify the repo's recorded checksums only
set -euo pipefail

REPO="https://github.com/jfg96/omarchy-nearby"
PIN_TAG="helper-v1.2.9"
PIN_COMMIT="088d5a92e28ada9f6edfbf7f5c3281fa3539cd55"

# Upstream published release assets for the pinned tag (verified by upstream's
# launcher). Downloading these is the no-toolchain path; see BUILD.md.
ASSET_SHA_X86_64="7d4079795d4355f1a68d3cdec1f7dabce72cc7d64e1cd1236e84a59b23436ee2"
ASSET_SHA_AARCH64="6384e0b6dd21ecd3c7aad3c3aed3c877f4258a913dd36999a2eec0908cb48e6b"

# Checksum of the binary committed at payload/bin/lan-share-helper. It came
# from a locally renamed tree and is NOT byte-reproducible from this script;
# the value is here so the shipped artifact can be verified, not reproduced.
SHIPPED_SHA256="4e5ea58524cf3e5f3c0a82419c20c879288d879252047dc1ba5d1b6a76ff7f26"

pkg_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
payload="$pkg_dir/payload/bin/lan-share-helper"
target=""
install=false

die() { printf 'error: %s\n' "$*" >&2; exit 1; }

sha() { sha256sum "$1" | cut -d' ' -f1; }

check() {
    local failures=0
    [[ "$PIN_COMMIT" =~ ^[0-9a-f]{40}$ ]] || { printf 'FAIL pin commit is not a full sha1\n'; failures=1; }
    [[ "$SHIPPED_SHA256" =~ ^[0-9a-f]{64}$ ]] || { printf 'FAIL shipped checksum is not a sha256\n'; failures=1; }
    [[ "$ASSET_SHA_X86_64" =~ ^[0-9a-f]{64}$ ]] || { printf 'FAIL x86_64 asset checksum is not a sha256\n'; failures=1; }
    [[ "$ASSET_SHA_AARCH64" =~ ^[0-9a-f]{64}$ ]] || { printf 'FAIL aarch64 asset checksum is not a sha256\n'; failures=1; }

    [[ -f "$payload" ]] || { printf 'FAIL missing %s\n' "$payload"; failures=1; }
    if [[ -f "$payload" ]]; then
        local actual
        actual="$(sha "$payload")"
        if [[ "$actual" == "$SHIPPED_SHA256" ]]; then
            printf 'ok   payload/bin/lan-share-helper matches the recorded sha256\n'
        else
            printf 'FAIL payload/bin/lan-share-helper sha256 is %s\n' "$actual"
            printf '     recorded is %s\n' "$SHIPPED_SHA256"
            failures=1
        fi
        if [[ -x "$payload" ]]; then
            printf 'ok   payload binary is executable (the manifest overlay needs that bit)\n'
        else
            printf 'FAIL payload binary is not executable\n'; failures=1
        fi
    fi

    printf 'pinned upstream: %s (%s)\n' "$PIN_TAG" "$PIN_COMMIT"
    [[ $failures -eq 0 ]] || exit 1
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --install) install=true ;;
        --target) [[ $# -ge 2 ]] || die "--target needs a triple"; target="$2"; shift ;;
        --check) check; exit 0 ;;
        -h|--help) sed -n '2,12p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) die "unknown argument: $1" ;;
    esac
    shift
done

command -v git >/dev/null || die "git is required"
command -v cargo >/dev/null || die "cargo is required (https://rustup.rs); the pinned tree names its own toolchain"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
src="$work/omarchy-nearby"

printf 'fetching %s at %s\n' "$REPO" "$PIN_COMMIT"
git init -q "$src"
git -C "$src" remote add origin "$REPO"
git -C "$src" fetch -q --depth 1 origin "$PIN_COMMIT"
git -C "$src" checkout -q FETCH_HEAD

build_args=(build --release --locked --manifest-path backend/Cargo.toml)
[[ -n "$target" ]] && build_args+=(--target "$target")
printf 'building %s\n' "${target:-host}"
# Run inside the checkout so rustup honours the channel that tree pins in its
# own rust-toolchain.toml instead of whatever stable happens to be installed.
( cd "$src" && cargo "${build_args[@]}" )

# Outside $work: the checkout is disposable, the artifact is not.
out_dir="${OUT_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/lan-share-helper-build}"
mkdir -p "$out_dir"
bin="$src/backend/target${target:+/$target}/release/omarchy-nearby-helper"
[[ -f "$bin" ]] || die "cargo did not produce $bin"
install -Dm755 "$bin" "$out_dir/lan-share-helper"

# The helper prints one JSON event per line on stdout; the ready event carries
# the version the mod compares against minHelperVersion.
version="$(printf '' | timeout 15 "$out_dir/lan-share-helper" 2>/dev/null \
    | sed -n 's/.*"helperVersion":"\([^"]*\)".*/\1/p' | head -1 || true)"

printf '\nbuilt:    %s\n' "$out_dir/lan-share-helper"
printf 'version:  %s\n' "${version:-unknown}"
printf 'sha256:   %s\n' "$(sha "$out_dir/lan-share-helper")"
printf 'shipped:  %s  (verify only, see BUILD.md)\n' "$SHIPPED_SHA256"

if [[ "$install" == true ]]; then
    install -Dm755 "$out_dir/lan-share-helper" "$payload"
    printf '\ninstalled into %s\n' "$payload"
else
    printf '\ncopy it over the composed shell helper, or rerun with --install\n'
fi
