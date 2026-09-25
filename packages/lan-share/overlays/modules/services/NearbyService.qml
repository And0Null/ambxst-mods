pragma Singleton
pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io
import qs.modules.services
import "../widgets/nearby/NearbyModel.js" as Model

// LAN peer presence and transfer for and0null.lan-share (LocalSend subset).
// Owns the vendored helper Process plus the transfer state machine. The bar
// button and the card are views onto this object: one engine per session, not
// one per monitor, because the helper binds port 53317 and a second instance
// would lose the race with EADDRINUSE.
//
// v1.0 scope: discovery + clipboard text send + incoming-file accept/decline.
// v1.1 adds: PC -> phone multi-file send via a service-owned zenity picker
// (selectFilesTo/sendFilesTo) reusing the outgoing_* lifecycle.
// No PIN, no updater flows.
Singleton {
    id: root

    // Oldest helper this service knows how to drive. A mismatch is an error
    // state, never a start.
    readonly property string minHelperVersion: "1.1.2"

    // Helper resolved next to the composed generation tree (overlay target
    // modules/widgets/nearby/bin/narciss-lan-share-helper). The manifest ships
    // the binary with the executable bit; composition preserves it via git.
    readonly property string helperPath: String(Qt.resolvedUrl("../widgets/nearby/bin/narciss-lan-share-helper")).replace(/^file:\/\//, "")

    // Device name announced to peers. The helper takes its LocalSend alias from
    // the HOSTNAME environment variable and has no usable compiled-in
    // fallback, so the backend Process below always sets it explicitly.
    // An empty override resolves to the system hostname and then to the
    // login user, never to the helper's own default.
    property string deviceName: ""
    property string systemHostname: ""
    property bool hostnameReady: false

    readonly property string announcedName: {
        const configured = String(root.deviceName || "").trim();
        if (configured !== "")
            return configured;
        const host = String(root.systemHostname || "").trim();
        if (host !== "")
            return host;
        return String(Quickshell.env("USER") || "").trim();
    }

    // `hostname` (coreutils) instead of Quickshell.env("HOSTNAME"): the
    // variable is not exported into the shell's session, which is exactly why
    // the helper used to announce its compiled-in fallback.
    Process {
        id: hostnameProbe
        command: ["hostname"]
        running: true

        stdout: StdioCollector {
            id: hostnameOutput
            waitForEnd: true
            onStreamFinished: {
                root.systemHostname = String(hostnameOutput.text || "").trim();
                root.hostnameReady = true;
            }
        }
    }

    // Fails open: if the probe never reports, the receiver still starts after
    // this window (announcing the login user rather than nothing).
    Timer {
        interval: 3000
        running: !root.hostnameReady
        onTriggered: root.hostnameReady = true
    }

    // Receiver gate: OFF by default, persisted via StateService. The helper
    // never runs before the persisted value is restored.
    property bool receiverEnabled: false
    property bool _restored: false
    property bool shutdownPending: false

    // Single source of truth for "the helper may start now": the backend
    // Process binds `running` to this and bindBackendRunning() re-installs the
    // same expression, so an added condition can never drift between the two.
    readonly property bool backendEligible: root._restored && root.receiverEnabled && !root.versionMismatch && root.hostnameReady

    property string helperVersion: ""
    property bool versionMismatch: false
    property bool helperMissing: false
    property bool backendReady: false
    property bool discoveryActive: false

    // Frontend mirror of the helper PEER_TTL (90s): a peer not re-sighted
    // within this window is pruned locally so a powered-off device cannot
    // stick on the card until the next authoritative snapshot or toggle.
    readonly property int peerTtlMs: 90000

    // Scan epoch: rescan() bumps scanEpoch so in-flight Qt.callLater
    // re-hydrations from the previous round cannot overwrite the optimistic
    // clear. While scanPending is true the round is open: `device` sightings
    // repopulate progressively without flipping statusText, and the next
    // `peer_snapshot` closes the round showing Ready only for peers actually
    // re-sighted in this epoch (the helper snapshot still carries 90s-TTL
    // ghosts, so unfiltered re-apply would resurrect the gone peer in one
    // frame and make Rescan look like a no-op).
    property int scanEpoch: 0
    property bool scanPending: false
    property var sightedInEpoch: ({})

    property var peers: []
    property var selectedPeer: null
    property string viewState: "nearby"
    property string statusText: "Turned off"
    property string errorText: ""

    property var incomingQueue: []
    readonly property var incoming: Model.currentIncoming(incomingQueue)
    property string incomingText: ""
    property bool incomingTextPending: false
    property real progress: 0
    property string transferName: ""
    property string transferPeer: ""
    property string activeIncomingSession: ""
    property string outgoingTransferId: ""
    property var pendingSendDevice: null
    // Last directory the file picker saw a selection in, persisted via
    // StateService (`nearby.lastFileDir`, trailing slash). The zenity
    // --filename start dir for the next pick; falls back to $HOME.
    property string lastFileDir: ""
    property int transferSequence: 0
    property bool backendAcceptedThisRun: false
    property string startupFailureCode: ""
    property int startupFailurePort: 0

    // Discovery follows the popup, and popups exist once per monitor, so
    // openness is a count: discovery runs while any view is open.
    property int openViewCount: 0
    readonly property bool anyViewOpen: openViewCount > 0
    readonly property bool backendRunning: backend.running

    readonly property string statusMeta: {
        if (!root.receiverEnabled)
            return "OFF";
        if (!root.backendReady)
            return root.statusText !== "" ? root.statusText.toUpperCase() : "STARTING";
        if (root.incoming)
            return "INCOMING";
        if (root.scanPending)
            return "SCANNING";
        if (root.peers.length === 0)
            return "READY";
        return root.peers.length === 1 ? "1 PEER" : root.peers.length + " PEERS";
    }

    Connections {
        target: ModsService
        function onSettingChanged(modId, key, value) {
            if (modId !== "and0null.lan-share" || key !== "deviceName")
                return;
            root.deviceName = String(value || "");
        }
    }

    Connections {
        target: StateService
        function onInitializedChanged() {
            root._restore();
        }
    }
    Component.onCompleted: {
        root._restore();
        ModsService.getSettings("and0null.lan-share", settings => {
            if (settings && !settings.error && settings.values)
                root.deviceName = String(settings.values.deviceName || "");
        });
    }

    function _restore() {
        if (StateService.initialized && !root._restored) {
            root._restored = true;
            root.receiverEnabled = StateService.get("nearby.receiverEnabled", false);
            root.lastFileDir = String(StateService.get("nearby.lastFileDir", ""));
            if (root.receiverEnabled)
                root.statusText = "Starting receiver…";
        }
    }

    function send(command) {
        if (!backend.running)
            return;
        backend.write(JSON.stringify(command) + "\n");
    }

    function bindBackendRunning() {
        // Assigning a plain `true` here removes the declarative binding from
        // Process.running. Reinstall the binding instead so receiver OFF -> ON
        // can still start the helper after the retry budget is exhausted.
        backend.running = Qt.binding(function() {
            return root.backendEligible;
        });
    }

    // Never persists before StateService.initialized. Enabling persists at
    // once; disabling goes through the shutdown handshake so the helper exits
    // cleanly before the running binding drops.
    function setReceiver(on) {
        if (!StateService.initialized || root.shutdownPending)
            return;
        if (on === root.receiverEnabled)
            return;
        if (on) {
            backendRestart.attempts = 0;
            root.receiverEnabled = true;
            StateService.set("nearby.receiverEnabled", true);
            root.versionMismatch = false;
            root.helperMissing = false;
            root.errorText = "";
            root.statusText = "Starting receiver…";
        } else {
            root.stopDiscovery();
            root.shutdownPending = true;
            root.send({ command: "shutdown" });
            receiverShutdownFallback.restart();
        }
    }

    function toggleReceiver() {
        root.setReceiver(!root.receiverEnabled);
    }

    function finishReceiverShutdown() {
        receiverShutdownFallback.stop();
        rescanStarter.stop();
        root.shutdownPending = false;
        root.receiverEnabled = false;
        StateService.set("nearby.receiverEnabled", false);
        root.backendReady = false;
        root.discoveryActive = false;
        root.peers = [];
        root.selectedPeer = null;
        root.scanPending = false;
        root.sightedInEpoch = {};
        root.incomingQueue = [];
        root.incomingText = "";
        root.incomingTextPending = false;
        root.activeIncomingSession = "";
        root.pendingSendDevice = null;
        root.outgoingTransferId = "";
        root.viewState = "nearby";
        root.statusText = "Turned off";
        root.errorText = "";
    }

    function startDiscovery() {
        root.discoveryActive = true;
        root.errorText = "";
        root.statusText = root.peers.length ? "Ready" : "Looking nearby…";
        root.send({ command: "discovery_start" });
    }

    function rescan() {
        if (!root.backendReady) {
            root.statusText = "Receiver not ready";
            root.errorText = "Turn the LAN Share receiver on and wait for it to be ready before rescanning.";
            return;
        }
        // New scan generation: the optimistic clear below must stay visible
        // until the next authoritative snapshot closes the round. Stale
        // Qt.callLater closures from the previous round carry their epoch and
        // are dropped by the handlers.
        root.scanEpoch++;
        root.scanPending = true;
        root.sightedInEpoch = {};
        // Revalidate: drop the current list optimistically so a device that
        // left since the last sighting cannot survive on the card. Only
        // peers the new round actually re-sights come back via `device`
        // events and the next authoritative `peer_snapshot`. First clear:
        // the delayed start below clears again to seal the stop→start
        // window where the helper re-emits the last peer instantly.
        root.peers = [];
        root.selectedPeer = null;
        root.errorText = "";
        root.statusText = "Scanning local network…";
        // Strict rescan: stop -> 300ms -> bare start (no force_full: it is a
        // no-op in helper v1.1.2). The stop cuts the continuous re-emission;
        // the delay drops the rehydrated peer in the window; the bare start
        // opens a clean epoch that only repopulates with fresh `device`
        // events from this epoch.
        root.stopDiscovery();
        // Re-arm the finite window even when discovery was already active:
        // `running: discoveryActive` alone would not restart the timer, so
        // a Rescan late in a round would only scan until the old expiry.
        // Re-armed again on the delayed start for a full 12s window.
        discoveryTimeout.restart();
        rescanStarter.restart();
    }

    function stopDiscovery() {
        root.discoveryActive = false;
        root.send({ command: "discovery_stop" });
    }

    function viewOpened() {
        root.openViewCount++;
        if (root.openViewCount !== 1)
            return;
        // Opening starts one finite scan round (visible scanning ~12s,
        // then a stable Ready/N-peers state), never a continuous discovery.
        if (root.viewState === "nearby" && root.receiverEnabled && root.backendReady)
            root.rescan();
    }

    function viewClosed() {
        if (root.openViewCount > 0)
            root.openViewCount--;
        if (root.openViewCount !== 0)
            return;
        rescanStarter.stop();
        root.stopDiscovery();
        // Real close: never keep last session's presence on the card. The
        // next open re-discovers from zero via rescan().
        // Bump the epoch so in-flight Qt.callLater closures (peer_snapshot,
        // device) from the closed round cannot re-populate the cleared list
        // — the same guard rescan() and discoveryTimeout use.
        root.scanEpoch++;
        root.peers = [];
        root.selectedPeer = null;
        root.scanPending = false;
        root.sightedInEpoch = {};
        if (root.viewState === "target")
            root.viewState = "nearby";
        if (root.receiverEnabled && root.backendReady)
            root.statusText = "Ready to receive";
    }

    // A desktop notification exists to reach a user who is not looking at the
    // card. Raising one for something the open card already shows is a
    // duplicate the user has to dismiss on top of the prompt they answer.
    function notificationNeeded(onScreen) {
        return !root.anyViewOpen || !onScreen;
    }

    function choosePeer(index) {
        if (index >= 0 && index < root.peers.length) {
            root.selectedPeer = root.peers[index];
            root.viewState = "target";
        }
    }

    function incomingSummary(files) {
        return Model.incomingSummary(files);
    }

    function clearTarget() {
        root.viewState = "nearby";
        root.selectedPeer = null;
    }

    // Clipboard text send (v1.0 subset: no PIN). An empty clipboard is
    // a visible refusal, never an empty payload on the wire.
    function sendTextTo(fingerprint) {
        var device = null;
        for (var i = 0; i < root.peers.length; i++) {
            if (root.peers[i] && root.peers[i].fingerprint === fingerprint) {
                device = root.peers[i];
                break;
            }
        }
        if (!device) {
            root.viewState = "error";
            root.reportFailure("Peer unavailable", "That peer is no longer nearby.");
            return;
        }
        if (!backend.running || clipboardReader.running || filePicker.running)
            return;
        root.pendingSendDevice = device;
        clipboardReader.launched = false;
        clipboardReader.running = true;
    }

    // File send (v1.1: PC -> phone, no PIN). The picker lives in the service
    // (one engine per session), never in the card (one view per monitor).
    // Guards mirror sendTextTo: no peer means nothing to do, a busy backend
    // or picker means a silent return, never a second launch.
    //
    // Focus decoupling: opening zenity steals focus, BarPopup closes on
    // focus-lost and viewClosed() clears peers/selectedPeer. So the target is
    // snapshotted into pendingSendDevice BEFORE launching, and onExited sends
    // through that snapshot instead of selectedPeer: the transfer survives the
    // popup closing. BarPopup itself is core shell code, untouched on purpose.
    function selectFilesTo() {
        if (!root.selectedPeer)
            return;
        if (!backend.running || filePicker.running || clipboardReader.running)
            return;
        root.pendingSendDevice = root.selectedPeer;
        filePicker.command = ["zenity", "--file-selection", "--multiple", "--separator=\n", "--title=Send with LAN Share", "--filename=" + root.pickerStartDir()];
        filePicker.launched = false;
        filePicker.running = true;
    }

    // Where the next picker opens: last used dir when remembered, $HOME
    // otherwise. Trailing slash so zenity treats it as a directory.
    // (zenity 4.2.2 file-selection has no address-bar or --show-hidden
    // option — hidden files toggle with Ctrl+H inside the dialog — so a
    // useful start dir is the navigation fix available with stock zenity.)
    function pickerStartDir() {
        if (root.lastFileDir !== "")
            return root.lastFileDir;
        var home = String(Quickshell.env("HOME") || "");
        return home !== "" ? home + "/" : "/";
    }

    // Remembers the dir of the first picked path for the next picker open.
    function rememberFileDir(paths) {
        if (!paths || !paths.length || !StateService.initialized)
            return;
        var dir = Model.dirOf(paths[0]);
        if (dir === "")
            return;
        root.lastFileDir = dir + "/";
        StateService.set("nearby.lastFileDir", root.lastFileDir);
    }

    // Builds pending {kind:"files"} via Model.sendFilesCommand and sends it
    // directly (this mod has no PIN pending queue: no beginOutgoing /
    // dispatchPendingOutgoing like the oma.nearby reference). Empty selections
    // are a visible refusal, never an empty payload on the wire. Progress and
    // cancel reuse the existing outgoing_preparing/progress/done/cancelled/
    // failed events plus finishOutgoing/cancelOutgoing.
    function sendFilesTo(device, paths) {
        if (!device || !device.fingerprint || !device.alias) {
            root.viewState = "error";
            root.reportFailure("Peer unavailable", "That peer is no longer nearby.");
            return;
        }
        if (!backend.running)
            return;
        root.transferSequence++;
        var transferId = "out-" + Date.now() + "-" + root.transferSequence;
        var command = Model.sendFilesCommand(device, paths, transferId);
        if (!command) {
            root.viewState = "error";
            root.reportFailure("Send refused", "No files selected.");
            return;
        }
        root.outgoingTransferId = transferId;
        root.send(command);
    }

    function acceptIncoming(requestId) {
        var current = root.incoming;
        var id = requestId || (current ? current.requestId : "");
        if (!id)
            return;
        root.send({ command: "accept", request_id: id });
        root.viewState = "receiving";
        root.transferPeer = current ? String(current.sender || "") : "";
        root.transferName = current ? Model.incomingSummary(current.files) : "Transfer";
        root.progress = 0;
    }

    function declineIncoming(requestId) {
        var current = root.incoming;
        var id = requestId || (current ? current.requestId : "");
        if (!id)
            return;
        root.send({ command: "decline", request_id: id });
        root.incomingQueue = Model.removeIncoming(root.incomingQueue, id);
        if (root.incoming) {
            root.viewState = "incoming";
            root.statusText = "Incoming transfer";
        } else if (root.incomingTextPending) {
            root.incomingTextPending = false;
            root.viewState = "text";
            root.statusText = "Text received";
        } else {
            root.viewState = "nearby";
            root.statusText = "Declined";
        }
    }

    function copyReceivedText() {
        if (clipboardWriter.running)
            return;
        clipboardWriter.launched = false;
        clipboardWriter.running = true;
    }

    function reportFailure(summary, detail) {
        root.statusText = summary;
        root.errorText = detail;
    }

    function cancelOutgoing() {
        root.send({ command: "cancel_outgoing", transfer_id: root.outgoingTransferId });
    }

    function finishIncoming(terminalState, message, completed) {
        root.activeIncomingSession = "";
        if (root.incoming) {
            root.viewState = "incoming";
            root.statusText = "Incoming transfer";
            root.errorText = "";
            root.progress = 0;
            return;
        }
        if (root.incomingTextPending) {
            root.incomingTextPending = false;
            root.viewState = "text";
            root.statusText = "Text received";
            root.errorText = "";
            root.progress = 0;
            return;
        }
        root.viewState = terminalState;
        root.statusText = message;
        root.errorText = terminalState === "error" ? message : "";
        if (completed)
            root.progress = 1;
    }

    function finishOutgoing(terminalState, message, completed) {
        root.pendingSendDevice = null;
        root.outgoingTransferId = "";
        if (root.incoming) {
            root.viewState = "incoming";
            root.statusText = "Incoming transfer";
            root.errorText = "";
            root.progress = 0;
            return;
        }
        if (root.incomingTextPending) {
            root.incomingTextPending = false;
            root.viewState = "text";
            root.statusText = "Text received";
            root.errorText = "";
            root.progress = 0;
            return;
        }
        root.viewState = terminalState;
        root.statusText = message;
        root.errorText = terminalState === "error" ? message : "";
        if (completed)
            root.progress = 1;
    }

    function finishText() {
        root.incomingText = "";
        root.incomingTextPending = false;
        root.viewState = "nearby";
        root.startDiscovery();
    }

    function finishTerminal() {
        root.viewState = "nearby";
        root.startDiscovery();
    }

    function handleBackendExit(code) {
        root.backendReady = false;
        root.discoveryActive = false;
        root.incomingQueue = [];
        root.incomingTextPending = false;
        root.activeIncomingSession = "";
        root.pendingSendDevice = null;
        root.outgoingTransferId = "";
        if (root.shutdownPending) {
            root.finishReceiverShutdown();
            return;
        }
        if (!root.receiverEnabled) {
            root.statusText = "Turned off";
            root.errorText = "";
            return;
        }
        if (root.versionMismatch)
            return;
        if (!root.backendAcceptedThisRun) {
            if (root.startupFailureCode === "receiver_security_settings_invalid") {
                root.reportFailure("Security settings invalid",
                    "LAN Share security settings are invalid. Repair or remove the receiver's settings.json in your XDG state directory.");
            } else if (backendRestart.attempts < 4) {
                root.reportFailure("Retrying…", "The LAN Share receiver could not start. Retrying…");
            } else if (root.startupFailureCode === "receiver_port_in_use") {
                var port = root.startupFailurePort > 0 ? root.startupFailurePort : 53317;
                root.reportFailure("Port " + port + " in use",
                    "LocalSend receiver port " + port + " is already in use. Quit the other receiver and enable LAN Share again.");
            } else {
                root.reportFailure("Could not start", "The LAN Share receiver could not start.");
            }
        } else {
            root.reportFailure(code === 0 ? "Receiver stopped" : "Receiver unavailable",
                code === 0 ? "Receiver stopped." : "Receiver unavailable.");
            if (root.viewState === "sending" || root.viewState === "receiving" || root.viewState === "incoming")
                root.viewState = "error";
        }
        if (backendRestart.attempts < 4) {
            backendRestart.attempts++;
            backendRestart.interval = Math.min(30000, 1000 * Math.pow(2, backendRestart.attempts - 1));
            backendRestart.restart();
        }
    }

    function handleEvent(event) {
        if (!event || !event.event)
            return;
        if (root.versionMismatch && event.event !== "ready")
            return;
        if (event.event === "startup_failed") {
            root.startupFailureCode = String(event.code || "");
            root.startupFailurePort = Number(event.port) || 0;
        } else if (event.event === "ready") {
            root.helperVersion = String(event.helperVersion || "");
            root.helperMissing = false;
            if (!Model.helperSatisfies(root.minHelperVersion, root.helperVersion)) {
                root.backendReady = false;
                root.versionMismatch = true;
                root.reportFailure("Helper out of date",
                    "Needs helper " + root.minHelperVersion + " · installed " + (root.helperVersion !== "" ? root.helperVersion : "unknown"));
                root.send({ command: "shutdown" });
                return;
            }
            root.backendAcceptedThisRun = true;
            root.backendReady = true;
            root.versionMismatch = false;
            backendRestart.attempts = 0;
            root.statusText = "Ready to receive";
            root.errorText = "";
            if (root.anyViewOpen && root.viewState === "nearby")
                root.startDiscovery();
        } else if (event.event === "peer_snapshot") {
            var snapEpoch = root.scanEpoch;
            var snapDevices = event.devices;
            Qt.callLater(function() {
                if (snapEpoch !== root.scanEpoch)
                    return;
                if (root.scanPending) {
                    // Close the round (STRICT): only peers re-sighted via
                    // `device` in this epoch re-enter. A snapshot ghost
                    // without a fresh `device` in this epoch NEVER enters.
                    // The raw snapshot still holds 90s-TTL ghosts, so
                    // applying it whole would undo the optimistic clear in
                    // one frame. Ready shows only after this snapshot, never
                    // mid-round.
                    var sighted = root.sightedInEpoch;
                    var fresh = [];
                    for (var i = 0; i < (snapDevices || []).length; i++) {
                        var cand = snapDevices[i];
                        if (cand && cand.fingerprint && sighted[cand.fingerprint] === snapEpoch)
                            fresh.push(cand);
                    }
                    root.peers = Model.snapshotDevices(fresh, Date.now());
                    root.scanPending = false;
                    root.statusText = root.peers.length ? "Ready" : "Looking nearby…";
                    return;
                }
                root.peers = Model.snapshotDevices(snapDevices, Date.now());
                root.statusText = root.peers.length ? "Ready" : "Looking nearby…";
            });
        } else if (event.event === "device") {
            var devEpoch = root.scanEpoch;
            var dev = event.device;
            Qt.callLater(function() {
                if (devEpoch !== root.scanEpoch)
                    return;
                if (!dev || !dev.fingerprint)
                    return;
                if (root.scanPending) {
                    var marks = root.sightedInEpoch;
                    marks[dev.fingerprint] = devEpoch;
                    root.sightedInEpoch = marks;
                    root.peers = Model.upsertDevice(root.peers, dev, Date.now());
                    // Keep "Scanning local network…" visible: the snapshot
                    // closing the round is what flips to Ready.
                    return;
                }
                root.peers = Model.upsertDevice(root.peers, dev, Date.now());
                root.statusText = root.peers.length ? "Ready" : "Looking nearby…";
            });
        } else if (event.event === "discovery_started") {
            root.discoveryActive = true;
        } else if (event.event === "discovery_stopped") {
            root.discoveryActive = false;
        } else if (event.event === "incoming_request") {
            Qt.callLater(function() {
                root.incomingQueue = Model.enqueueIncoming(root.incomingQueue, event);
                var takesView = root.viewState !== "sending" && root.viewState !== "receiving";
                if (takesView)
                    root.viewState = "incoming";
                if (root.notificationNeeded(takesView && root.incoming && root.incoming.requestId === event.requestId))
                    Quickshell.execDetached(["notify-send", "-a", "LAN Share", "Incoming transfer",
                        String(event.sender) + " wants to send " + Model.incomingSummary(event.files)]);
            });
        } else if (event.event === "incoming_text") {
            root.incomingText = String(event.text || "");
            root.transferPeer = String(event.sender || "");
            root.incomingTextPending = root.outgoingTransferId !== "";
            if (!root.incomingTextPending) {
                root.viewState = "text";
                root.stopDiscovery();
            }
            if (root.notificationNeeded(!root.incomingTextPending))
                Quickshell.execDetached(["notify-send", "-a", "LAN Share", "Text received", "From " + String(event.sender || "")]);
        } else if (event.event === "incoming_accepted") {
            root.incomingQueue = Model.removeIncoming(root.incomingQueue, event.requestId);
        } else if (event.event === "incoming_expired") {
            var expiredWasCurrent = root.incoming && root.incoming.requestId === event.requestId;
            root.incomingQueue = Model.removeIncoming(root.incomingQueue, event.requestId);
            if (expiredWasCurrent && (root.viewState === "incoming" || (root.viewState === "receiving" && root.activeIncomingSession === ""))) {
                if (root.incoming) {
                    root.statusText = "Incoming transfer";
                } else if (root.incomingTextPending) {
                    root.incomingTextPending = false;
                    root.viewState = "text";
                    root.statusText = "Text received";
                    root.errorText = "";
                } else {
                    root.viewState = "error";
                    root.errorText = "Transfer request expired";
                    root.statusText = root.errorText;
                }
            }
        } else if (event.event === "incoming_progress") {
            if (root.activeIncomingSession === "") {
                if (root.viewState !== "receiving")
                    return;
                root.activeIncomingSession = String(event.sessionId);
            }
            if (root.activeIncomingSession !== String(event.sessionId))
                return;
            if (root.outgoingTransferId !== "")
                return;
            root.viewState = "receiving";
            root.transferName = String(event.name);
            root.transferPeer = String(event.sender);
            root.progress = event.total > 0 ? event.bytes / event.total : 0;
        } else if (event.event === "file_received") {
            if (root.activeIncomingSession === "") {
                if (root.viewState !== "receiving")
                    return;
                root.activeIncomingSession = String(event.sessionId);
            }
            if (root.activeIncomingSession !== String(event.sessionId))
                return;
            root.transferName = String(event.name);
            root.transferPeer = String(event.sender);
        } else if (event.event === "incoming_done") {
            if (root.activeIncomingSession !== String(event.sessionId))
                return;
            Quickshell.execDetached(["notify-send", "-a", "LAN Share", "Transfer received",
                root.transferName !== "" ? root.transferName : "File saved to Downloads"]);
            root.finishIncoming("success", "Received", true);
        } else if (event.event === "incoming_cancelled") {
            if (root.activeIncomingSession === "") {
                if (root.viewState !== "receiving")
                    return;
                root.activeIncomingSession = String(event.sessionId);
            }
            if (root.activeIncomingSession !== String(event.sessionId))
                return;
            root.finishIncoming("error", "Transfer cancelled", false);
        } else if (event.event === "incoming_failed") {
            if (root.activeIncomingSession === "") {
                if (root.viewState !== "receiving")
                    return;
                root.activeIncomingSession = String(event.sessionId);
            }
            if (root.activeIncomingSession !== String(event.sessionId))
                return;
            root.finishIncoming("error", String(event.message || "Transfer failed"), false);
        } else if (event.event === "incoming_declined") {
            root.incomingQueue = Model.removeIncoming(root.incomingQueue, event.requestId);
        } else if (event.event === "outgoing_preparing") {
            if (String(event.transferId) !== root.outgoingTransferId)
                return;
            root.viewState = "sending";
            root.transferName = String(event.name);
            root.transferPeer = String(event.target);
            root.progress = 0;
            root.stopDiscovery();
        } else if (event.event === "outgoing_progress") {
            if (String(event.transferId) !== root.outgoingTransferId)
                return;
            root.viewState = "sending";
            root.progress = event.total > 0 ? event.bytes / event.total : 0;
        } else if (event.event === "outgoing_done") {
            if (String(event.transferId) !== root.outgoingTransferId)
                return;
            root.finishOutgoing("success", "Sent", true);
        } else if (event.event === "outgoing_cancelled") {
            if (String(event.transferId) !== root.outgoingTransferId)
                return;
            root.finishOutgoing("error", "Transfer cancelled", false);
        } else if (event.event === "outgoing_failed") {
            if (event.transferId && String(event.transferId) !== root.outgoingTransferId)
                return;
            root.finishOutgoing("error", String(event.message || "Transfer failed"), false);
        } else if (event.event === "error") {
            // Generic error: route through the same finish* paths as the
            // terminal transfer states so mid-transfer errors settle state
            // cleanly (outgoingTransferId cleared, pendingSendDevice dropped)
            // instead of leaving a transfer stuck as "in progress".
            var errorMsg = String(event.message || "Transfer failed");
            if (root.outgoingTransferId !== "")
                root.finishOutgoing("error", errorMsg, false);
            else if (root.activeIncomingSession !== "")
                root.finishIncoming("error", errorMsg, false);
            else {
                root.viewState = "error";
                root.statusText = errorMsg;
                root.errorText = errorMsg;
            }
        }
    }

    Process {
        id: backend
        property bool launched: false
        // Not eligible to start until the persisted receiver flag is back.
        // Defaulting to on before then would bind the LocalSend port and
        // announce on the LAN for a user who turned the receiver off.
        command: [root.helperPath]
        // The helper reads its announced alias from HOSTNAME (see announcedName).
        environment: ({ HOSTNAME: root.announcedName })
        running: root.backendEligible
        stdinEnabled: true
        stdout: SplitParser {
            onRead: function(line) {
                root.handleEvent(Model.parseLine(line));
            }
        }
        stderr: SplitParser {
            onRead: function(line) {
                console.warn("lan share backend:", line);
            }
        }
        onStarted: {
            backend.launched = true;
            root.backendAcceptedThisRun = false;
            root.versionMismatch = false;
            root.helperMissing = false;
            root.startupFailureCode = "";
            root.startupFailurePort = 0;
        }
        // A helper that is missing rather than failing never reaches onExited:
        // Quickshell returns running to false without an exit code. This is
        // the case reinstalling the mod actually fixes.
        onRunningChanged: {
            if (running) {
                backend.launched = false;
                return;
            }
            if (backend.launched)
                return;
            // `running` is a binding, so it also drops when the receiver is
            // turned off. Only a helper we still want running counts as one
            // that failed to launch.
            if (!root.receiverEnabled || !root._restored)
                return;
            root.backendReady = false;
            root.helperMissing = true;
            root.reportFailure("Helper missing",
                "LAN Share helper is missing or could not start. Reinstall the and0null.lan-share mod.");
        }
        onExited: function(code) {
            root.handleBackendExit(code);
        }
    }

    // Clipboard read for text send. Quickshell reports a command it could not
    // launch by returning `running` to false without `started`/`exited`, so a
    // missing wl-paste has to be caught on runningChanged.
    Process {
        id: clipboardReader
        property bool launched: false
        command: ["wl-paste", "--no-newline", "--type", "text"]
        running: false
        stdout: StdioCollector {
            id: clipboardOutput
            waitForEnd: true
        }
        onStarted: clipboardReader.launched = true
        onRunningChanged: {
            if (!running && !clipboardReader.launched) {
                root.pendingSendDevice = null;
                root.viewState = "error";
                root.reportFailure("Clipboard unavailable", "wl-paste is required to read the clipboard.");
            }
        }
        onExited: function(code) {
            var device = root.pendingSendDevice;
            root.pendingSendDevice = null;
            var text = String(clipboardOutput.text || "");
            if (code === 0 && text.trim() !== "" && device) {
                root.transferSequence++;
                var transferId = "out-" + Date.now() + "-" + root.transferSequence;
                var command = Model.sendTextCommand(device, text, transferId);
                if (command) {
                    root.outgoingTransferId = transferId;
                    root.send(command);
                    return;
                }
            }
            root.viewState = "error";
            root.reportFailure("Send refused", "Clipboard is empty.");
        }
    }

    // zenity file picker for file send. Quickshell reports a command it could
    // not launch by returning `running` to false without `started`/`exited`,
    // so a missing zenity has to be caught on runningChanged (visible error).
    // Exit 0 with paths: sends through the pendingSendDevice snapshot taken
    // in selectFilesTo (NOT selectedPeer: the popup already closed on
    // focus-lost and viewClosed() cleared it). Exit 1 is the picker dismissed
    // with nothing chosen: silent, snapshot dropped, state unchanged.
    // Exit >1 never opened: visible error, no transfer.
    Process {
        id: filePicker
        property bool launched: false
        command: ["zenity", "--file-selection", "--multiple", "--separator=\n", "--title=Send with LAN Share"]
        running: false
        stdout: StdioCollector {
            id: filePickerOutput
            waitForEnd: true
        }
        onStarted: filePicker.launched = true
        onRunningChanged: {
            if (!running && !filePicker.launched) {
                root.pendingSendDevice = null;
                root.viewState = "error";
                root.reportFailure("The file chooser could not be started", "zenity is required to choose files.");
            }
        }
        onExited: function(code) {
            var device = root.pendingSendDevice;
            root.pendingSendDevice = null;
            if (code > 1) {
                root.viewState = "error";
                root.reportFailure("The file chooser did not open", "zenity exited with an error.");
                return;
            }
            if (code !== 0 || !device)
                return;
            var paths = String(filePickerOutput.text || "").split("\n").filter(function(v) { return v.trim() !== ""; });
            if (!paths.length)
                return;
            root.rememberFileDir(paths);
            root.sendFilesTo(device, paths);
        }
    }

    Process {
        id: clipboardWriter
        property bool launched: false
        command: ["wl-copy"]
        running: false
        stdinEnabled: true
        onStarted: {
            clipboardWriter.launched = true;
            clipboardWriter.write(root.incomingText);
            clipboardWriter.stdinEnabled = false;
        }
        onRunningChanged: {
            if (!running && !clipboardWriter.launched && root.viewState === "text")
                root.reportFailure("Copy unavailable", "wl-copy is required to copy received text.");
        }
        onExited: function(code) {
            clipboardWriter.stdinEnabled = true;
            if (root.viewState !== "text")
                return;
            if (code !== 0)
                root.reportFailure("Copy unavailable", "wl-copy is required to copy received text.");
        }
    }

    Timer {
        id: backendRestart
        property int attempts: 0
        interval: 1000
        repeat: false
        onTriggered: {
            if (root.receiverEnabled && !backend.running)
                root.bindBackendRunning();
        }
    }

    Timer {
        id: receiverShutdownFallback
        interval: 250
        repeat: false
        onTriggered: root.finishReceiverShutdown()
    }

    // Strict rescan sequencer: 300ms between discovery_stop and the bare
    // discovery_start so the helper's instant re-emit in the window lands on
    // an open round and is dropped without a fresh `device` sighting. The
    // second clear seals that window. Guarded by scanPending so a view close
    // inside the window never restarts discovery.
    Timer {
        id: rescanStarter
        interval: 300
        repeat: false
        onTriggered: {
            if (!root.scanPending)
                return;
            root.sightedInEpoch = {};
            root.peers = [];
            root.selectedPeer = null;
            root.discoveryActive = true;
            root.errorText = "";
            root.statusText = "Scanning local network…";
            discoveryTimeout.restart();
            root.send({ command: "discovery_start" });
        }
    }

    // Finite discovery window (~12s): the helper has no server-side scan
    // timeout, so a stuck `discoveryActive` keeps re-emitting snapshots
    // that re-stamp lastSeen and the 5s sweep + 90s TTL can never prune.
    // Auto-stop breaks that circle and leaves a stable Ready/N-peers state
    // instead of a scanning-forever UI. The epoch bump seals the round so
    // late in-flight snapshots cannot re-apply whole (90s-TTL ghosts).
    // Rescan re-arms it via discoveryActive + discoveryTimeout.restart().
    Timer {
        id: discoveryTimeout
        interval: 12000
        repeat: false
        running: root.discoveryActive
        onTriggered: {
            root.stopDiscovery();
            if (root.scanPending) {
                root.scanPending = false;
                root.scanEpoch++;
                root.sightedInEpoch = {};
                root.statusText = root.peers.length ? "Ready" : "No devices nearby";
            }
        }
    }

    // Local expiry mirror: `device` events are additive and the helper only
    // re-emits an authoritative `peer_snapshot` every 5s while discovery runs
    // (peers expire server-side after 90s), so a device that leaves between
    // snapshots would otherwise stay on the card until receiver toggle.
    // Skipped mid-transfer so a long send/receive never loses its peer.
    Timer {
        id: peerSweep
        interval: 5000
        repeat: true
        running: root.receiverEnabled && root.backendReady && root.peers.length > 0
        onTriggered: {
            if (root.viewState === "sending" || root.viewState === "receiving")
                return;
            // Not mid-round: the open scan owns peers + statusText until it
            // closes, so the sweep cannot overwrite "Scanning local network…"
            // or prune a peer the round just sighted. It stays the safety
            // net for stale rows between rounds.
            if (root.scanPending)
                return;
            Qt.callLater(function() {
                var pruned = Model.pruneStaleDevices(root.peers, Date.now(), root.peerTtlMs);
                if (pruned.length === root.peers.length)
                    return;
                root.peers = pruned;
                if (root.selectedPeer) {
                    var kept = false;
                    for (var i = 0; i < pruned.length; i++) {
                        if (pruned[i] && pruned[i].fingerprint === root.selectedPeer.fingerprint) {
                            root.selectedPeer = pruned[i];
                            kept = true;
                            break;
                        }
                    }
                    if (!kept) {
                        root.selectedPeer = null;
                        if (root.viewState === "target")
                            root.viewState = "nearby";
                    }
                }
                if (root.viewState === "nearby" || root.viewState === "target")
                    root.statusText = pruned.length ? "Ready" : "Looking nearby…";
            });
        }
    }
}
