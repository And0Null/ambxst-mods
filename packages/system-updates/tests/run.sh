#!/usr/bin/env bash
# Behavioral test for the REAL SystemUpdatesService.qml.
#
# The service imports two Ambxst singletons (ModsService, TerminalService).
# This script copies the real service into the test module and stubs ONLY
# those two names, so every line under test is untouched source.
#
# Read-only: the service's queries (pacman -Qu, checkupdates, ...) may run,
# but the updater is never launched (the stub terminal is empty).
#
# Runs under `qs` because the service imports Quickshell, whose plugin is only
# available inside the Quickshell runtime.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
mod="$(cd "$here/.." && pwd)"
qs_bin="${QS_BIN:-qs}"
timeout_s="${TEST_TIMEOUT:-30}"
log="$(mktemp)"

cp "$mod/overlays/modules/services/SystemUpdatesService.qml" \
   "$here/qml/qs/modules/services/SystemUpdatesService.qml"
printf 'module qs.modules.services\nsingleton SystemUpdatesService 1.0 SystemUpdatesService.qml\nsingleton ModsService 1.0 ModsService.qml\nsingleton TerminalService 1.0 TerminalService.qml\n' \
   > "$here/qml/qs/modules/services/qmldir"

# The service copy and qmldir are generated per run; keep the tree clean.
cleanup() {
    rm -f "$here/qml/qs/modules/services/SystemUpdatesService.qml" \
          "$here/qml/qs/modules/services/qmldir"
}
trap cleanup EXIT

set +e
QML2_IMPORT_PATH="$here/qml" timeout "$timeout_s" "$qs_bin" -p "$here/qml/shell.qml" >"$log" 2>&1
set -e

grep -E "^\s*DEBUG.*(PASS|FAIL|RESULT)" "$log" | sed -E 's/.*DEBUG[^:]*: //' || true
failures="$(grep -c "RESULT: ALL PASS" "$log" || true)"

if [ "$failures" -eq 1 ]; then
    echo "system-updates logic test: PASS"
    exit 0
fi

echo "system-updates logic test: FAIL (full log: $log)"
cat "$log"
exit 1
