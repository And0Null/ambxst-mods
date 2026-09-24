pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io
import qs.modules.services

// Counts pending system updates from pacman (repo), AUR, flatpak and mise.
// Driven by a Timer whose interval comes from the mod setting
// `refreshMinutes` (default 15), plus an initial check ~30s after start.
// A cheaper local poll (`pacman -Qu`, every 60s) detects when updates were
// applied and triggers a full check; two bounded re-checks follow an
// in-button update so the count self-corrects without the updater exiting
// notification TerminalService can't provide.
// Every command runs through `sh -c exec ...` so a missing binary still
// reaches onExited with a nonzero code instead of a silent launch
// failure; shell stays alive no matter what.
Singleton {
    id: root

    property int pacman: 0
    property int aur: 0
    property int flatpak: 0
    property int mise: 0
    readonly property int total: pacman + aur + flatpak + mise
    property bool loading: false
    property string lastError: ""

    property int refreshMinutes: 30
    property string aurHelper: ""
    property bool externalOnly: false
    // Card/settings options: show the bar button even when everything is
    // up to date, and which sources to scan.
    property bool showWhenUpToDate: false
    property bool scanPacman: true
    property bool scanAur: true
    property bool scanFlatpak: true
    property bool scanMise: true

    // Per-source result state. `known` stays false until a successful scan,
    // so an error or a never-scanned source is never reported as up to date.
    property bool pacmanKnown: false
    property bool aurKnown: false
    property bool flatpakKnown: false
    property bool miseKnown: false
    property string pacmanError: ""
    property string aurError: ""
    property string flatpakError: ""
    property string miseError: ""

    // "off" | "error" | "unknown" | "up" | "count" — drives the card display
    // and never reports success for a failed or unscanned source.
    function sourceState(key) {
        if (key === "pacman") {
            if (!root.scanPacman)
                return "off";
            if (root.pacmanError !== "")
                return "error";
            if (!root.pacmanKnown)
                return "unknown";
            return root.pacman > 0 ? "count" : "up";
        }
        if (key === "aur") {
            if (!root.scanAur)
                return "off";
            if (root.aurError !== "")
                return "error";
            if (!root.aurKnown)
                return "unknown";
            return root.aur > 0 ? "count" : "up";
        }
        if (key === "mise") {
            if (!root.scanMise)
                return "off";
            if (root.miseError !== "")
                return "error";
            if (!root.miseKnown)
                return "unknown";
            return root.mise > 0 ? "count" : "up";
        }
        if (!root.scanFlatpak)
            return "off";
        if (root.flatpakError !== "")
            return "error";
        if (!root.flatpakKnown)
            return "unknown";
        return root.flatpak > 0 ? "count" : "up";
    }

    function sourceCount(key) {
        if (key === "pacman")
            return root.pacman;
        if (key === "aur")
            return root.aur;
        if (key === "mise")
            return root.mise;
        return root.flatpak;
    }

    Component.onCompleted: {
        ModsService.getSettings("and0null.system-updates", settings => {
            if (settings && !settings.error && settings.values) {
                root.applyRefreshMinutes(settings.values.refreshMinutes);
                root.externalOnly = !!settings.values.externalOnly;
                root.showWhenUpToDate = !!settings.values.showWhenUpToDate;
                root.scanPacman = settings.values.scanPacman !== false;
                root.scanAur = settings.values.scanAur !== false;
                root.scanFlatpak = settings.values.scanFlatpak !== false;
                root.scanMise = settings.values.scanMise !== false;
            }
        });
    }

    function setSetting(key, value) {
        ModsService.setSetting("and0null.system-updates", key, value);
    }
    property bool flatpakProbed: false
    property bool flatpakAvailable: false
    property bool miseProbed: false
    property bool miseAvailable: false

    // In-flight check counter; loading clears when the last one exits.
    property int _pending: 0

    function _start(proc) {
        root._pending++;
        proc.running = false;
        proc.running = true;
    }

    function _finish() {
        root._pending = Math.max(0, root._pending - 1);
        if (root._pending === 0)
            root.loading = false;
    }

    // Count lines in captured stdout; empty/newline-only output counts 0.
    function _countLines(text) {
        const t = String(text || "").trim();
        if (t === "")
            return 0;
        return t.split("\n").length;
    }

    function check() {
        if (root._pending !== 0)
            return;
        root.loading = true;
        root.lastError = "";

        if (root.scanPacman) {
            repoCheck.command = ["sh", "-c", "exec checkupdates"];
            root._start(repoCheck);
        } else {
            root.pacman = 0;
            root.pacmanKnown = false;
            root.pacmanError = "";
        }

        if (root.scanAur) {
            if (root.aurHelper !== "")
                _runAurCheck();
            else {
                aurProbe.command = ["sh", "-c", "command -v paru || command -v yay || command -v checkupdates-aur"];
                root._start(aurProbe);
            }
        } else {
            root.aur = 0;
            root.aurKnown = false;
            root.aurError = "";
        }

        if (root.scanFlatpak) {
            if (root.flatpakProbed) {
                if (root.flatpakAvailable)
                    _runFlatpakCheck();
                else {
                    root.flatpak = 0;
                    root.flatpakKnown = true;
                }
            } else {
                flatpakProbe.command = ["sh", "-c", "exec flatpak --version >/dev/null 2>&1"];
                root._start(flatpakProbe);
            }
        } else {
            root.flatpak = 0;
            root.flatpakKnown = false;
            root.flatpakError = "";
        }

        if (root.scanMise) {
            if (root.miseProbed) {
                if (root.miseAvailable)
                    _runMiseCheck();
                else {
                    root.mise = 0;
                    root.miseKnown = true;
                }
            } else {
                miseProbe.command = ["sh", "-c", "exec command -v mise"];
                root._start(miseProbe);
            }
        } else {
            root.mise = 0;
            root.miseKnown = false;
            root.miseError = "";
        }

        // All sources disabled: nothing in flight, loading would stick.
        if (root._pending === 0)
            root.loading = false;
    }

    function checkPacman() {
        if (root._pending !== 0 || !root.scanPacman)
            return;
        root.loading = true;
        root.lastError = "";
        repoCheck.command = ["sh", "-c", "exec checkupdates"];
        root._start(repoCheck);
    }

    function checkAur() {
        if (root._pending !== 0 || !root.scanAur)
            return;
        root.loading = true;
        root.lastError = "";
        if (root.aurHelper !== "")
            _runAurCheck();
        else {
            aurProbe.command = ["sh", "-c", "command -v paru || command -v yay || command -v checkupdates-aur"];
            root._start(aurProbe);
        }
        // Nothing started (unknown helper): don't leave loading stuck.
        if (root._pending === 0)
            root.loading = false;
    }

    function checkFlatpak() {
        if (root._pending !== 0 || !root.scanFlatpak)
            return;
        root.loading = true;
        root.lastError = "";
        if (root.flatpakProbed) {
            if (root.flatpakAvailable)
                _runFlatpakCheck();
            else {
                root.flatpak = 0;
                root.flatpakKnown = true;
            }
        } else {
            flatpakProbe.command = ["sh", "-c", "exec flatpak --version >/dev/null 2>&1"];
            root._start(flatpakProbe);
        }
        // Flatpak absent: nothing started, don't leave loading stuck.
        if (root._pending === 0)
            root.loading = false;
    }

    function checkMise() {
        if (root._pending !== 0 || !root.scanMise)
            return;
        root.loading = true;
        root.lastError = "";
        if (root.miseProbed) {
            if (root.miseAvailable)
                _runMiseCheck();
            else {
                root.mise = 0;
                root.miseKnown = true;
            }
        } else {
            miseProbe.command = ["sh", "-c", "exec command -v mise"];
            root._start(miseProbe);
        }
        // mise absent: nothing started, don't leave loading stuck.
        if (root._pending === 0)
            root.loading = false;
    }

    function _runAurCheck() {
        // ponytail: no timeout watchdog; checks are read-only and bounded
        // in practice, add a kill-timer if a refresh ever hangs a bar.
        if (root.aurHelper === "paru")
            aurCheck.command = ["sh", "-c", "exec paru -Qua"];
        else if (root.aurHelper === "yay")
            aurCheck.command = ["sh", "-c", "exec yay -Qua"];
        else if (root.aurHelper === "checkupdates-aur")
            aurCheck.command = ["sh", "-c", "exec checkupdates-aur"];
        else {
            root.aur = 0;
            return;
        }
        root._start(aurCheck);
    }

    function _runFlatpakCheck() {
        flatpakCheck.command = ["sh", "-c", "exec flatpak remote-ls --updates"];
        root._start(flatpakCheck);
    }

    function _runMiseCheck() {
        // -C "$HOME" pins the config scope: `mise outdated` also reads local
        // mise.toml files from the cwd upward and the shell's cwd is not ours
        // to choose, so -C $HOME yields exactly the global config list.
        // All mise logs go to stderr; stdout holds only one line per outdated
        // tool (empty when up to date) and the exit code is 0 either way.
        miseCheck.command = ["sh", "-c", "exec mise -C \"$HOME\" outdated"];
        root._start(miseCheck);
    }

    // Previous local count (pacman -Qu) used for drop detection; -1 means
    // "not sampled yet", so the first run never triggers a network check.
    property int lastLocal: -1

    // Fast local auto-detect: `pacman -Qu` is local-only and instant, so poll
    // it every 60s. When the count DROPS below the previous value an update
    // was applied outside this module; run the real check() to refresh all
    // counts (pacman + AUR + flatpak). Equal or rising values are no-ops.
    Timer {
        id: localPollTimer
        interval: 120000
        running: true
        repeat: true
        triggeredOnStart: true
        onTriggered: {
            if (root._pending !== 0)
                return;
            localCheck.command = ["sh", "-c", "exec pacman -Qu"];
            localCheck.running = false;
            localCheck.running = true;
        }
    }

    // The updater runs as a tracked Process: Quickshell keeps it as a child,
    // so onExited fires when the user's terminal closes. That is a real
    // completion signal, not a guessed delay. TerminalService exposes its
    // configured binary/template, so we honor the user's terminal choice.
    function _terminalCommand(shellCmd) {
        if (TerminalService.advanced) {
            const rendered = TerminalService.commandTemplate
                .replace(/\$TERMINAL/g, TerminalService.binary)
                .replace(/\$COMMAND/g, shellCmd);
            return ["sh", "-c", rendered];
        }
        return [TerminalService.binary, "-e", "bash", "-c", shellCmd];
    }

    function _launchUpdate(shellCmd) {
        if (updateRunner.running)
            return;
        if (!TerminalService.binary) {
            root.lastError = "No terminal configured for updates";
            return;
        }
        updateRunner.command = _terminalCommand(shellCmd);
        updateRunner.running = true;
    }

    // Update every source the mod counts. paru -Syu covers pacman repos + AUR;
    // flatpak and mise are updated too when installed. mise runs with the same
    // -C $HOME scope as the check, so it upgrades the global config only.
    function updateNow() {
        _launchUpdate("paru -Syu; command -v flatpak >/dev/null 2>&1 && flatpak update; command -v mise >/dev/null 2>&1 && mise -C \"$HOME\" upgrade");
    }

    // Run a single-source update command (from the card's per-source button).
    function runUpdate(command) {
        _launchUpdate(command);
    }

    Process {
        id: updateRunner
        running: false
        onExited: function() {
            // The updater finished or its terminal closed: rescan everything
            // so the counts reflect the new state.
            root.check();
        }
    }

    // True while an updater is running; the card disables its update buttons
    // so two updates can't be launched at once.
    readonly property bool updateRunning: updateRunner.running

    function applyRefreshMinutes(value) {
        const minutes = Number(value);
        if (!isFinite(minutes) || minutes < 5)
            return;
        root.refreshMinutes = Math.round(minutes);
        refreshTimer.restart();
    }

    Connections {
        target: ModsService
        function onSettingChanged(modId, key, value) {
            if (modId !== "and0null.system-updates")
                return;
            if (key === "refreshMinutes")
                root.applyRefreshMinutes(value);
            else if (key === "externalOnly")
                root.externalOnly = !!value;
            else if (key === "showWhenUpToDate")
                root.showWhenUpToDate = !!value;
            else if (key === "scanPacman")
                root.scanPacman = !!value;
            else if (key === "scanAur")
                root.scanAur = !!value;
            else if (key === "scanFlatpak")
                root.scanFlatpak = !!value;
            else if (key === "scanMise")
                root.scanMise = !!value;
        }
    }

    // Initial check ~30s after start (let the desktop settle), then every
    // refreshMinutes.
    Timer {
        id: startupDelay
        interval: 30000
        running: true
        onTriggered: {
            refreshTimer.restart();
            root.check();
        }
    }

    Timer {
        id: refreshTimer
        interval: root.refreshMinutes * 60 * 1000
        running: false
        repeat: true
        onTriggered: root.check()
    }

    Process {
        id: localCheck
        running: false
        stdout: StdioCollector {
            id: localOut
            waitForEnd: true
        }
        onExited: function(code) {
            // Missing binary or transient failure → nonzero exit; keep the
            // previous sample instead of poisoning drop detection.
            if (code !== 0)
                return;
            const count = root._countLines(localOut.text);
            if (root.lastLocal >= 0 && count < root.lastLocal)
                root.check();
            root.lastLocal = count;
        }
    }

    Process {
        id: repoCheck
        running: false
        stdout: StdioCollector {
            id: repoOut
            waitForEnd: true
        }
        onExited: function(code) {
            // checkupdates exits 0 when updates exist and 2 when there are
            // none; count stdout either way, other codes are real failures.
            if (code === 0 || code === 2) {
                root.pacman = root._countLines(repoOut.text);
                root.pacmanKnown = true;
                root.pacmanError = "";
            } else {
                root.pacmanKnown = false;
                root.pacmanError = "checkupdates failed (exit " + code + ")";
                root.lastError = root.pacmanError;
            }
            root._finish();
        }
    }

    Process {
        id: aurProbe
        running: false
        stdout: StdioCollector {
            id: aurProbeOut
            waitForEnd: true
        }
        onExited: {
            // command -v may return an absolute path ("/usr/bin/paru"); use
            // the basename so the helper comparison matches either way.
            const first = String(aurProbeOut.text || "").trim().split("\n")[0].split("/").pop();
            root.aurHelper = (first === "paru" || first === "yay" || first === "checkupdates-aur") ? first : "";
            if (root.aurHelper === "") {
                root.aurKnown = false;
                root.aurError = "No AUR update checker (paru/yay/checkupdates-aur)";
                root.lastError = root.aurError;
                root._finish();
            } else {
                // Start the follow-up scan first, then release the probe slot,
                // so `loading` never flickers false mid-check.
                _runAurCheck();
                root._finish();
            }
        }
    }

    Process {
        id: aurCheck
        running: false
        stdout: StdioCollector {
            id: aurOut
            waitForEnd: true
        }
        onExited: function(code) {
            // AUR helpers (paru/yay -Qua) exit 0 with updates and 1 with
            // none; count stdout either way.
            if (code === 0 || code === 1) {
                root.aur = root._countLines(aurOut.text);
                root.aurKnown = true;
                root.aurError = "";
            } else {
                root.aurKnown = false;
                root.aurError = root.aurHelper + " failed (exit " + code + ")";
                root.lastError = root.aurError;
            }
            root._finish();
        }
    }

    Process {
        id: flatpakProbe
        running: false
        stdout: StdioCollector {
            waitForEnd: true
        }
        onExited: function(code) {
            root.flatpakProbed = true;
            root.flatpakAvailable = code === 0;
            if (root.flatpakAvailable) {
                // Start the follow-up scan first, then release the probe slot,
                // so `loading` never flickers false mid-check.
                _runFlatpakCheck();
                root._finish();
            } else {
                // No flatpak installed is a definite answer: zero updates.
                root.flatpak = 0;
                root.flatpakKnown = true;
                root.flatpakError = "";
                root._finish();
            }
        }
    }

    Process {
        id: flatpakCheck
        running: false
        stdout: StdioCollector {
            id: flatpakOut
            waitForEnd: true
        }
        onExited: function(code) {
            if (code === 0) {
                root.flatpak = root._countLines(flatpakOut.text);
                root.flatpakKnown = true;
                root.flatpakError = "";
            } else {
                root.flatpakKnown = false;
                root.flatpakError = "flatpak remote-ls failed (exit " + code + ")";
                root.lastError = root.flatpakError;
            }
            root._finish();
        }
    }

    Process {
        id: miseProbe
        running: false
        stdout: StdioCollector {
            waitForEnd: true
        }
        onExited: function(code) {
            root.miseProbed = true;
            root.miseAvailable = code === 0;
            if (root.miseAvailable) {
                // Start the follow-up scan first, then release the probe slot,
                // so `loading` never flickers false mid-check.
                _runMiseCheck();
                root._finish();
            } else {
                // No mise installed is a definite answer: zero updates.
                root.mise = 0;
                root.miseKnown = true;
                root.miseError = "";
                root._finish();
            }
        }
    }

    Process {
        id: miseCheck
        running: false
        stdout: StdioCollector {
            id: miseOut
            waitForEnd: true
        }
        onExited: function(code) {
            if (code === 0) {
                root.mise = root._countLines(miseOut.text);
                root.miseKnown = true;
                root.miseError = "";
            } else {
                root.miseKnown = false;
                root.miseError = "mise outdated failed (exit " + code + ")";
                root.lastError = root.miseError;
            }
            root._finish();
        }
    }
}
