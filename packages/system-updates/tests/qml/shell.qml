import QtQuick
import Quickshell
import qs.modules.services

// Behavioral test for the REAL SystemUpdatesService (copied in by run.sh, with
// only ModsService and TerminalService stubbed). The state mapping decides
// what the card and bar show; the guard decides whether an updater may launch.
// Runs under `qs` because the service imports Quickshell.
ShellRoot {
    id: test

    property int failures: 0
    property var checks: []

    function check(name, actual, expected) {
        const ok = actual === expected;
        checks = checks.concat([(ok ? "PASS " : "FAIL ") + name + " (got " + actual + ", want " + expected + ")"]);
        if (!ok)
            failures++;
    }

    Component.onCompleted: {
        const svc = SystemUpdatesService;

        // A never-scanned source must NOT look up to date.
        svc.scanPacman = true;
        svc.pacmanKnown = false;
        svc.pacmanError = "";
        check("pacman never scanned -> unknown", svc.sourceState("pacman"), "unknown");

        // A failed source reports error, never a green check.
        svc.pacmanError = "checkupdates failed (exit 1)";
        check("pacman failure -> error", svc.sourceState("pacman"), "error");

        // Successful scan with zero pending -> up to date.
        svc.pacmanError = "";
        svc.pacmanKnown = true;
        svc.pacman = 0;
        check("pacman scanned, zero -> up", svc.sourceState("pacman"), "up");

        // Successful scan with pending count.
        svc.pacman = 7;
        check("pacman scanned, pending -> count", svc.sourceState("pacman"), "count");
        check("sourceCount reports the number", svc.sourceCount("pacman"), 7);

        // Disabled source overrides every other state.
        svc.scanPacman = false;
        check("pacman disabled -> off", svc.sourceState("pacman"), "off");

        // AUR mirrors the same state machine.
        svc.scanAur = true;
        svc.aurKnown = false;
        svc.aurError = "";
        check("aur never scanned -> unknown", svc.sourceState("aur"), "unknown");
        svc.aurKnown = true;
        svc.aur = 2;
        check("aur pending -> count", svc.sourceState("aur"), "count");

        // Flatpak: zero after a successful scan is a definite "up to date".
        svc.scanFlatpak = true;
        svc.flatpakError = "";
        svc.flatpakKnown = true;
        svc.flatpak = 0;
        check("flatpak scanned, zero -> up", svc.sourceState("flatpak"), "up");

        // mise mirrors the same state machine.
        svc.scanMise = true;
        svc.miseError = "";
        svc.miseKnown = false;
        check("mise never scanned -> unknown", svc.sourceState("mise"), "unknown");
        svc.miseKnown = true;
        svc.mise = 0;
        check("mise scanned, zero -> up", svc.sourceState("mise"), "up");
        svc.mise = 4;
        check("mise pending -> count", svc.sourceState("mise"), "count");
        check("mise count reported", svc.sourceCount("mise"), 4);
        svc.scanMise = false;
        check("mise disabled -> off", svc.sourceState("mise"), "off");

        // The bar badge sums every source, mise included.
        svc.scanPacman = true;
        svc.pacman = 7;
        svc.pacmanKnown = true;
        svc.pacmanError = "";
        svc.scanAur = true;
        svc.aur = 2;
        svc.aurKnown = true;
        svc.aurError = "";
        svc.scanFlatpak = true;
        svc.flatpak = 1;
        svc.flatpakKnown = true;
        svc.flatpakError = "";
        svc.scanMise = true;
        svc.mise = 4;
        svc.miseKnown = true;
        svc.miseError = "";
        check("total sums every source", svc.total, 14);

        // The updater must not spawn without a configured terminal.
        svc.lastError = "";
        svc.runUpdate("true");
        check("update refused without terminal", svc.lastError !== "", true);
        check("no launch without terminal", svc.updateRunning, false);

        console.log("\n--- system-updates service logic test ---");
        for (let i = 0; i < checks.length; i++)
            console.log(checks[i]);
        console.log(failures === 0 ? "RESULT: ALL PASS" : ("RESULT: " + failures + " FAILURE(S)"));
        Qt.exit(failures === 0 ? 0 : 1);
    }
}
