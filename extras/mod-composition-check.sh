#!/usr/bin/env bash
# Mod composition check: does every Ambxst release inside a mod's declared
# range still build it, and does it still build when another mod has already
# edited the same files?
#
# The shell applies each patch with `git apply --check`, falls back to
# `git apply --3way` (which needs the pre-image blob recorded in the patch's
# `index` line), and then keeps both sides of an added-vs-added conflict. This
# script replays exactly that, on a throwaway git generation per release, with
# the mod's operations in its own manifest order.
#
#   extras/mod-composition-check.sh [package-dir ...]
#
# Defaults to every package/ that has an ambxst.mod.json. The base shell comes
# from ~/.local/share/ambxst/shell_repo, or $AMBXST_SRC.
set -uo pipefail

REPO=$(cd "$(dirname "$0")/.." && pwd)
BASE=${AMBXST_SRC:-$(cat ~/.local/share/ambxst/shell_repo 2>/dev/null)}
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
fails=0

[ -d "$BASE/.git" ] || { echo "no base shell at ${BASE:-unset} (set AMBXST_SRC)"; exit 2; }
if [ "$#" -gt 0 ]; then PKGS=("$@"); else PKGS=("$REPO"/packages/*/); fi

# --- the shell's own apply logic, one patch at a time -------------------------
apply_patch() {
    local gen=$1 patch=$2 touched=$3
    grep '^+++ ' "$patch" | awk '{print $2}' | sed 's|^[iw]/||' >> "$touched"
    if git -C "$gen" apply --check --whitespace=error-all "$patch" 2>"$WORK/err"; then
        git -C "$gen" apply --whitespace=error-all "$patch" || return 1
        return 0
    fi
    if ! git -C "$gen" apply --3way "$patch" 2>"$WORK/err"; then
        # resolveAddedBlocks(): keep both sides of every added-vs-added conflict
        local unmerged
        unmerged=$(git -C "$gen" diff --name-only --diff-filter=U)
        [ -n "$unmerged" ] || { echo "      $(head -1 "$WORK/err")"; return 1; }
        for f in $unmerged; do
            python3 - "$gen/$f" <<'PY' || return 1
import sys, pathlib
p = pathlib.Path(sys.argv[1]); out = []; lines = p.read_text().split("\n"); i = 0
while i < len(lines):
    if not lines[i].startswith("<<<<<<<"):
        out.append(lines[i]); i += 1; continue
    i += 1; ours = []; base = []; theirs = []; section = "ours"; closed = False
    while i < len(lines):
        line = lines[i]
        if line.startswith("|||||||"): section = "base"
        elif line.startswith("======="): section = "theirs"
        elif line.startswith(">>>>>>>"): closed = True
        else: {"ours": ours, "base": base, "theirs": theirs}[section].append(line)
        i += 1
        if closed: break
    if not closed or base: sys.exit(1)   # a real conflict: the shell stops
    out += ours + theirs
p.write_text("\n".join(out))
PY
            git -C "$gen" add -- "$f" || return 1
        done
    fi
    return 0
}

# --- generation, built like initComposition() ---------------------------------
generation() {
    local gen=$1 ref=$2
    rm -rf "$gen"; mkdir -p "$gen"
    git -C "$BASE" archive "$ref" | tar -x -C "$gen" || return 1
    local objects
    objects=$(git -C "$BASE" rev-parse --path-format=absolute --git-path objects)
    git -C "$gen" init -q
    git -C "$gen" config merge.conflictStyle diff3
    mkdir -p "$gen/.git/objects/info"
    echo "$objects" > "$gen/.git/objects/info/alternates"
    git -C "$gen" add -A -f . >/dev/null
    git -C "$gen" -c user.email=mods@ambxst.invalid -c user.name=mods commit -qm base >/dev/null 2>&1
}

# --- the mod itself, in its manifest's operation order ------------------------
apply_mod() {
    local pkg=$1 gen=$2 touched=$3 status=0 source
    : > "$touched"
    ( cd "$pkg" && find overlays -type f 2>/dev/null | while read -r f; do
        mkdir -p "$gen/$(dirname "${f#overlays/}")"
        cp "$f" "$gen/${f#overlays/}"
      done )
    while read -r source; do
        apply_patch "$gen" "$pkg/$source" "$touched" || { echo "      patch failed: $source"; status=1; break; }
    done < <(python3 -c "
import json, sys
m = json.load(open('$pkg/ambxst.mod.json'))
print(*[o['source'] for o in m.get('operations', []) if o['type'] == 'patch'], sep='\n')
")
    return $status
}

# the files the mod patched, with no conflict marker left in them
clean_touched() {
    local gen=$1 touched=$2 f
    while read -r f; do
        [ -f "$gen/$f" ] || continue
        grep -q '^<<<<<<<\|^>>>>>>>' "$gen/$f" && { echo "      conflict markers left in $f"; return 1; }
    done < "$touched"
    return 0
}

# A bar mod that inserts its own button right next to the bar buttons, which is
# what community.audio-device-switcher does to BarContent.qml.
foreign_bar_block() {
    python3 - "$1/modules/bar/BarContent.qml" <<'PY' || return 1
import sys, pathlib
p = pathlib.Path(sys.argv[1])
if not p.exists():
    sys.exit(0)
s = p.read_text()
block = """                        AudioDeviceSwitcher {
                            id: audioDeviceSwitcher
                            bar: root
                            startRadius: root.innerRadius
                            endRadius: root.innerRadius
                            enableShadow: root.shadowsEnabled
                        }

"""
changed = False
for id in ("batteryIndicator", "batteryIndicatorVert"):
    needle = "                        Bar.BatteryIndicator {\n                            id: " + id + "\n"
    if s.count(needle) == 1:
        s = s.replace(needle, block + needle, 1)
        changed = True
if changed:
    p.write_text(s)
PY
}

for pkg in "${PKGS[@]}"; do
    pkg=$(cd "$pkg" && pwd)
    [ -f "$pkg/ambxst.mod.json" ] || continue
    mapfile -t meta < <(python3 - "$pkg/ambxst.mod.json" "$BASE" <<'PY'
import json, subprocess, sys

m = json.load(open(sys.argv[1]))
c = m["compatibility"]
spec = c["ambxst"].replace(">=", "").replace("<=", "").replace(" ", "")
lo, _, hi = spec.partition("<")
lo = lo or "0.0.0"
hi = hi or "999.0.0"


def key(v):
    return [int(x) for x in v.split(".") if x.isdigit()]


tags = subprocess.run(["git", "-C", sys.argv[2], "tag"], capture_output=True, text=True).stdout.split()
rels = sorted((t for t in tags if t.split(".")[0].isdigit() and key(lo) <= key(t) < key(hi)), key=key)
print(m["id"])
print(c["ambxst"])
print(" ".join(rels))
PY
)
    id=${meta[0]}; range=${meta[1]}; releases=${meta[2]}
    if [ -z "$releases" ]; then
        echo "$id: no Ambxst release matches \"$range\""; fails=$((fails + 1)); continue
    fi
    echo "$id  (declares $range, $(echo "$releases" | wc -w) release(s) in range)"

    # every patch must record a pre-image blob the base repo actually has: that
    # line is what lets the shell fall back to a three-way merge when another
    # mod has already edited the same file
    for patch in "$pkg"/patches/*.patch "$pkg"/patches/*/*/*.patch "$pkg"/patches/*/*/*/*.patch; do
        [ -f "$patch" ] || continue
        rel=${patch#"$pkg"/}
        while read -r pre _; do
            git -C "$BASE" cat-file -e "$pre" 2>/dev/null ||
                { echo "   FAIL  $rel records pre-image $pre, which the base shell does not have"; fails=$((fails + 1)); }
        done < <(grep '^index ' "$patch" | awk '{split($2, a, "\\.\\."); print a[1], a[2]}' | sed 's/^\([0-9a-f]*\) \([0-9a-f]*\)$/\1 \2/')
        diffs=$(grep -c '^diff --git' "$patch")
        idx=$(grep -c '^index ' "$patch")
        [ "$diffs" = "$idx" ] ||
            { echo "   FAIL  $rel patches $diffs file(s) but records $idx pre-image(s): a three-way merge can never run for the rest"; fails=$((fails + 1)); }
    done

    oldest=${releases%% *}
    newest=${releases##* }
    # the base shell's tip is what an install actually builds, and it is not
    # always a tagged release
    tip=$(git -C "$BASE" rev-parse --short HEAD)
    [ -n "$(git -C "$BASE" describe --tags --exact-match HEAD 2>/dev/null)" ] ||
        releases="$releases $tip"
    for rel in $releases; do
        gen="$WORK/$id-$rel"
        touched="$WORK/touched"
        generation "$gen" "$rel" || { echo "   FAIL  $rel"; fails=$((fails + 1)); continue; }
        if apply_mod "$pkg" "$gen" "$touched" && clean_touched "$gen" "$touched"; then
            echo "   ok    $rel"
        else
            echo "   FAIL  $rel"; fails=$((fails + 1))
        fi
    done

    # another mod edited the bar first, on the oldest and the newest release
    for rel in $oldest $newest; do
        gen="$WORK/$id-$rel-foreign"
        touched="$WORK/touched-foreign"
        generation "$gen" "$rel" || { fails=$((fails + 1)); continue; }
        foreign_bar_block "$gen"
        git -C "$gen" commit -qam "community.audio-device-switcher" >/dev/null 2>&1
        if apply_mod "$pkg" "$gen" "$touched" && clean_touched "$gen" "$touched"; then
            echo "   ok    $rel behind another mod's bar button"
        else
            echo "   FAIL  $rel behind another mod's bar button"; fails=$((fails + 1))
        fi
    done

    # the built shell must not name anything this mod does not ship
    gen="$WORK/$id-$newest"
    if [ -f "$gen/shell.qml" ]; then
        while read -r line; do
            path=${line#import qs.}
            path=${path%;*}
            path=${path//./\/}
            [ -d "$gen/$path" ] ||
                { echo "   FAIL  shell.qml imports qs.$path, which the build does not have"; fails=$((fails + 1)); }
        done < <(grep -o '^import qs\.[A-Za-z0-9_.]*' "$gen/shell.qml")
        grep -qn 'barZoneProgress' "$gen/shell.qml" &&
            { echo "   FAIL  shell.qml reads barZoneProgress, which no Ambxst release defines"; fails=$((fails + 1)); }
    fi
done

echo
[ "$fails" -eq 0 ] && echo "mod composition: all checks passed" || echo "mod composition: $fails failure(s)"
exit $((fails > 0))
