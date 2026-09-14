pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import Quickshell.Wayland
import Quickshell.Io
import qs.modules.theme
import qs.modules.services

// pacseek-style package launcher. Searches the sync repos (pacman, instant)
// and the AUR (via the configured helper, paru by default) live, shows
// installed state, and hands off install/remove to an interactive terminal so
// the helper handles the sudo prompt and progress.
// Actions never run unsupervised here; the terminal owns the transaction.
PanelWindow {
    id: root

    anchors {
        top: true
        bottom: true
        left: true
        right: true
    }

    color: "transparent"

    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.namespace: "ambxst:pkglauncher"
    WlrLayershell.keyboardFocus: root.open ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None
    exclusionMode: ExclusionMode.Ignore

    readonly property var screenVisibilities: Visibilities.getForScreen(screen.name)
    readonly property bool open: screenVisibilities ? screenVisibilities.packages : false
    visible: open

    property string query: ""
    property var results: []
    property int selected: 0
    property bool searching: false
    property bool repoDone: true
    property bool aurDone: true
    property string status: ""
    property int searchGen: 0
    property var details: ({})
    property string detailsName: ""
    // name -> { from, to } for packages with a pending upgrade (repo + AUR).
    property var updates: ({})
    // Explicitly installed packages, shown while the query is empty (browse view).
    property var installedList: []

    // AUR helper (paru or yay), loaded from mod settings once available;
    // falls back to paru when settings have not been read yet.
    property string aurHelper: "paru"
    // Binary presence, checked once after the settings load resolves the name.
    property bool helperMissing: false

    function checkHelper() {
        helperProc.command = ["bash", "-c", "command -v \"$1\" >/dev/null 2>&1 && echo yes || echo no", "_", root.aurHelper];
        helperProc.running = true;
    }

    Component.onCompleted: {
        ModsService.getSettings("and0null.pkg-launcher", (settings, error) => {
            if (!error && settings && settings.values && settings.values.aurHelper) {
                root.aurHelper = String(settings.values.aurHelper);
                root.checkHelper();
            }
        });
    }

    Process {
        id: helperProc
        command: []
        stdout: StdioCollector {
            id: helperOut
            waitForEnd: true
        }
        onExited: function() {
            var exists = String(helperOut.text).trim() === "yes";
            root.helperMissing = !exists;
        }
    }

    function alpha(c, a) {
        return Qt.rgba(c.r, c.g, c.b, a);
    }

    // Compose the status line, prefixing the missing-helper warning when relevant
    // (every code path that writes status funnels through here).
    function setStatus(main) {
        root.status = root.helperMissing
            ? main + "  ·  " + root.aurHelper + " not found — AUR disabled"
            : main;
    }

    function closeLauncher() {
        root.query = "";
        root.results = [];
        root.selected = 0;
        root.status = "";
        root.searching = false;
        Visibilities.setActiveModule("");
    }

    onOpenChanged: {
        if (root.open) {
            root.results = [];
            root.selected = 0;
            root.status = "";
            // Refresh the pending-upgrade map once per open (both exit with 1
            // when there is nothing to upgrade: count lines, ignore the code).
            root.updates = ({});
            updRepoProc.running = true;
            if (!root.helperMissing)
                updAurProc.running = true;
            // Show the cached installed list instantly, refresh it in background.
            if (root.installedList.length > 0) {
                root.results = root.installedList;
                root.setStatus(root.installedList.length + " installed");
            }
            installedProc.running = true;
            Qt.callLater(function() {
                searchField.forceActiveFocus();
            });
        }
    }

    function select(dir) {
        if (root.results.length === 0)
            return;
        var next = root.selected + dir;
        if (next < 0)
            next = root.results.length - 1;
        else if (next >= root.results.length)
            next = 0;
        root.selected = next;
        resultsList.positionViewAtIndex(next, ListView.Contain);
    }

    // Parse `pacman -Ss` / `<helper> -Ss` output:
    //   repo/name 1.2.3-1 [installed]
    //       description line
    // Plain string ops on purpose: regex literals are fragile inside QML's JS
    // parser and silently fail at runtime.
    function parsePkgOutput(text) {
        var out = [];
        var lines = String(text || "").split("\n");
        var cur = null;
        for (var i = 0; i < lines.length; i++) {
            var line = lines[i];
            if (line.length > 0 && line.charCodeAt(0) !== 32) {
                var sp = line.indexOf(" ");
                var slash = line.indexOf("/");
                if (sp > 0 && slash > 0 && slash < sp) {
                    var rest = line.slice(sp + 1).trim();
                    var vparts = rest.split(" ");
                    cur = {
                        repo: line.slice(0, slash),
                        name: line.slice(slash + 1, sp),
                        version: vparts[0] || "",
                        // pacman prints "[installed]", the helper prints "[Installed]".
                        installed: rest.toLowerCase().indexOf("[installed") !== -1,
                        description: ""
                    };
                    out.push(cur);
                } else {
                    cur = null;
                }
            } else if (cur && cur.description === "") {
                cur.description = line.trim();
            }
        }
        return out;
    }

    function finishStatus() {
        if (root.repoDone && root.aurDone) {
            root.searching = false;
            root.setStatus(root.results.length === 0 ? "No results" : (root.results.length + " packages"));
        }
    }

    // Relevance first, then alphabetical:
    //   0 exact name match        (search "yazi"  -> yazi)
    //   1 name starts with term   (             -> yazi-git, yazi-nightly-bin)
    //   2 name contains term      (             -> fetch-yazi)
    //   3 matched only in description/metadata (-> shiki, ydrive…)
    function sortResults(rows, termOverride) {
        var q = String(termOverride !== undefined ? termOverride : (root.query || "")).trim().toLowerCase();
        var term = q.split(" ")[0];
        function band(row) {
            var n = String(row.name).toLowerCase();
            if (!term)
                return 0;
            if (n === term)
                return 0;
            if (n.indexOf(term) === 0)
                return 1;
            if (n.indexOf(term) !== -1)
                return 2;
            return 3;
        }
        rows.sort(function(a, b) {
            var ba = band(a);
            var bb = band(b);
            if (ba !== bb)
                return ba - bb;
            var an = String(a.name).toLowerCase();
            var bn = String(b.name).toLowerCase();
            if (an < bn)
                return -1;
            if (an > bn)
                return 1;
            return a.repo === "aur" ? 1 : -1;
        });
        return rows;
    }

    // "Field : value" from `<helper> -Si`; wrapped lines are indented. String ops
    // only — regex literals are unreliable inside QML's JS engine.
    function parseInfo(text) {
        var out = ({});
        var lines = String(text || "").split("\n");
        var key = "";
        for (var i = 0; i < lines.length; i++) {
            var line = lines[i];
            if (line.length === 0)
                continue;
            var colon = line.indexOf(":");
            if (line.charCodeAt(0) !== 32 && colon > 0) {
                key = line.slice(0, colon).trim();
                out[key] = line.slice(colon + 1).trim();
            } else if (key !== "") {
                out[key] = (out[key] ? out[key] + " " : "") + line.trim();
            }
        }
        return out;
    }

    // Labelled rows shown in the details pane, built from the raw info.
    function detailRows(d) {
        if (!d || !d.Name)
            return [];
        var rows = [];
        function add(label, value) {
            if (value !== undefined && value !== null && value !== "" && value !== "None")
                rows.push({ label: label, value: String(value) });
        }
        add("Version", d.Version);
        add("Repo", d.Repository);
        add("Download", d["Download Size"]);
        add("Installed", d["Installed Size"]);
        if (d.Votes)
            add("AUR", d.Votes + " votes" + (d.Popularity ? "  ·  pop " + Number(d.Popularity).toFixed(3) : ""));
        add("Maintainer", d.Maintainer);
        if (d["Out Of Date"] === "Yes")
            add("Warning", "marked out-of-date");
        add("Deps", d["Depends On"] ? d["Depends On"].split("  ").join(", ") : "");
        add("URL", d.URL);
        return rows;
    }

    // Lazily fetch `<helper> -Si` for the selected package (works for repos and AUR).
    function loadDetails() {
        var r = root.results[root.selected];
        if (!r) {
            root.details = ({});
            root.detailsName = "";
            return;
        }
        if (root.detailsName === r.name)
            return;
        root.detailsName = r.name;
        root.details = ({});
        infoProc.command = ["bash", "-c", "exec " + root.aurHelper + " -Si --color never \"$1\"", "_", r.name];
        infoProc.running = true;
    }

    function runSearch() {
        var q = root.query.trim();
        root.searchGen++;
        if (!q) {
            // Empty query: browse the installed packages instead of nothing.
            root.results = root.installedList;
            root.selected = 0;
            root.searching = false;
            root.setStatus(root.installedList.length > 0 ? (root.installedList.length + " installed") : "");
            infoDebounce.restart();
            return;
        }
        var gen = root.searchGen;
        root.searching = true;
        root.repoDone = false;
        // Missing helper: skip the AUR leg entirely instead of failing.
        root.aurDone = root.helperMissing;
        root.status = "Searching…";
        // The query is passed as an argument (never interpolated into the
        // shell string) so any characters stay safe.
        repoProc.gen = gen;
        repoProc.command = ["bash", "-c", "exec pacman -Ss --color never \"$1\"", "_", q];
        repoProc.running = true;
        if (!root.helperMissing) {
            aurProc.gen = gen;
            aurProc.command = ["bash", "-c", "exec " + root.aurHelper + " -Ss --color never \"$1\"", "_", q];
            aurProc.running = true;
        }
    }

    // Repo search (instant, local sync db).
    Process {
        id: repoProc
        property int gen: 0
        command: []
        stdout: StdioCollector {
            id: repoOut
            waitForEnd: true
        }
        onExited: function(code) {
            root.repoDone = true;
            if (code !== 0 || root.searchGen !== repoProc.gen) {
                if (code !== 0)
                    root.setStatus("pacman failed (exit " + code + ")");
                root.finishStatus();
                return;
            }
            root.results = root.sortResults(root.parsePkgOutput(repoOut.text));
            root.selected = 0;
            // selected may stay 0 (no change signal) — load its details anyway.
            infoDebounce.restart();
            root.finishStatus();
        }
    }

    // AUR search (slower: touches the network). Merged when it arrives; stale
    // generations are dropped.
    Process {
        id: aurProc
        property int gen: 0
        command: []
        stdout: StdioCollector {
            id: aurOut
            waitForEnd: true
        }
        onExited: function(code) {
            root.aurDone = true;
            if (code !== 0 || root.searchGen !== aurProc.gen) {
                if (code !== 0)
                    root.setStatus(root.aurHelper + " failed (exit " + code + ")");
                root.finishStatus();
                return;
            }
            var aur = root.parsePkgOutput(aurOut.text);
            var have = {};
            for (var i = 0; i < root.results.length; i++)
                have[root.results[i].name] = true;
            var merged = root.results.slice();
            for (var j = 0; j < aur.length; j++)
                if (!have[aur[j].name])
                    merged.push(aur[j]);
            root.results = root.sortResults(merged);
            infoDebounce.restart();
            root.finishStatus();
        }
    }

    // "name version" from `pacman -Qe` (explicitly installed, repo + foreign).
    function parseInstalled(text) {
        var out = [];
        var lines = String(text || "").split("\n");
        for (var i = 0; i < lines.length; i++) {
            var parts = lines[i].trim().split(" ");
            if (parts.length < 2 || !parts[0])
                continue;
            out.push({ repo: "", name: parts[0], version: parts[1], installed: true, description: "" });
        }
        return out;
    }

    // "name 1.2-1 -> 1.3-1" from `pacman -Qu` / `<helper> -Qua`.
    function parseUpdates(text) {
        var out = ({});
        var lines = String(text || "").split("\n");
        for (var i = 0; i < lines.length; i++) {
            var parts = lines[i].trim().split(" ");
            if (parts.length >= 4 && parts[2] === "->")
                out[parts[0]] = { from: parts[1], to: parts[3] };
        }
        return out;
    }

    function mergeUpdates(add) {
        var merged = ({});
        for (var k in root.updates)
            merged[k] = root.updates[k];
        for (var k2 in add)
            merged[k2] = add[k2];
        root.updates = merged;
    }

    // Details fetch (debounced: arrow navigation must not spam <helper> -Si).
    Timer {
        id: infoDebounce
        interval: 180
        onTriggered: root.loadDetails()
    }

    onSelectedChanged: infoDebounce.restart()

    Process {
        id: infoProc
        command: []
        stdout: StdioCollector {
            id: infoOut
            waitForEnd: true
        }
        onExited: function(code) {
            if (code !== 0)
                return;
            var d = root.parseInfo(infoOut.text);
            // Drop stale responses (selection moved on meanwhile).
            var r = root.results[root.selected];
            if (r && d.Name === r.name)
                root.details = d;
        }
    }

    // Pending upgrades: repo (pacman -Qu) and AUR (<helper> -Qua). Both exit 1
    // when there is nothing to upgrade, so the exit code is deliberately ignored.
    Process {
        id: updRepoProc
        command: ["bash", "-c", "exec pacman -Qu --color never 2>/dev/null"]
        stdout: StdioCollector {
            id: updRepoOut
            waitForEnd: true
        }
        onExited: function(code) {
            root.mergeUpdates(root.parseUpdates(updRepoOut.text));
        }
    }

    Process {
        id: updAurProc
        command: ["bash", "-c", "exec " + root.aurHelper + " -Qua --color never 2>/dev/null"]
        stdout: StdioCollector {
            id: updAurOut
            waitForEnd: true
        }
        onExited: function(code) {
            root.mergeUpdates(root.parseUpdates(updAurOut.text));
        }
    }

    // Explicitly installed packages (the browse view shown for an empty query).
    Process {
        id: installedProc
        command: ["bash", "-c", "exec pacman -Qe 2>/dev/null"]
        stdout: StdioCollector {
            id: installedOut
            waitForEnd: true
        }
        onExited: function(code) {
            if (code !== 0)
                return;
            root.installedList = root.sortResults(root.parseInstalled(installedOut.text), "");
            if (root.query.trim() === "") {
                root.results = root.installedList;
                root.setStatus(root.installedList.length + " installed");
                root.selected = 0;
                infoDebounce.restart();
            }
        }
    }

    function installSelected() {
        var r = root.results[root.selected];
        if (!r)
            return;
        if (r.repo === "aur" && root.helperMissing) {
            root.setStatus("Cannot install: " + root.aurHelper + " is not installed");
            return;
        }
        // The helper handles repo + AUR and asks for the sudo password in its
        // own terminal; `exec $SHELL` keeps it open so the result is visible.
        TerminalService.execDetached(root.aurHelper + " -S " + r.name + "; exec $SHELL");
        root.closeLauncher();
    }

    // Update everything (repos + AUR) in a terminal, same as the updates button.
    function updateAll() {
        if (root.helperMissing) {
            root.setStatus("Cannot update: " + root.aurHelper + " is not installed");
            return;
        }
        TerminalService.execDetached(root.aurHelper + " -Syu; exec $SHELL");
        root.closeLauncher();
    }

    function removeSelected() {
        var r = root.results[root.selected];
        if (!r || !r.installed)
            return;
        if (root.helperMissing) {
            root.setStatus("Cannot remove: " + root.aurHelper + " is not installed");
            return;
        }
        // The helper asks for confirmation in the terminal before removing anything.
        TerminalService.execDetached(root.aurHelper + " -Rns " + r.name + "; exec $SHELL");
        root.closeLauncher();
    }

    Timer {
        id: searchDebounce
        interval: 280
        onTriggered: root.runSearch()
    }

    onQueryChanged: searchDebounce.restart()

    mask: Region {
        item: root.open ? fullMask : emptyMask
    }

    Item {
        id: fullMask
        anchors.fill: parent
    }

    Item {
        id: emptyMask
        width: 0
        height: 0
    }

    Rectangle {
        anchors.fill: parent
        visible: root.open
        color: root.alpha(Colors.scrim, 0.55)

        MouseArea {
            anchors.fill: parent
            enabled: root.open
            onClicked: root.closeLauncher()
        }
    }

    Rectangle {
        id: card
        visible: root.open
        anchors.centerIn: parent
        width: Math.min(parent.width - 120, 1020)
        height: Math.min(parent.height - 120, 560)
        radius: 16
        color: root.alpha(Colors.background, 0.97)
        border.color: root.alpha(Colors.outline, 0.55)
        border.width: 1

        MouseArea {
            anchors.fill: parent
            onClicked: {}
        }

        Column {
            anchors.fill: parent
            anchors.margins: 18
            spacing: 10

            Rectangle {
                width: parent.width
                height: 46
                radius: 10
                color: root.alpha(Colors.surface, 0.9)
                border.color: root.alpha(Colors.outline, 0.4)

                Row {
                    anchors.fill: parent
                    anchors.leftMargin: 14
                    anchors.rightMargin: 14
                    spacing: 10

                    Text {
                        id: searchIcon
                        width: 18
                        anchors.verticalCenter: parent.verticalCenter
                        text: "⌕"
                        color: root.alpha(Colors.overBackground, 0.55)
                        font.family: Styling.defaultFont
                        font.pixelSize: Styling.fontSize(2)
                    }

                    TextInput {
                        id: searchField
                        // Explicit width from the icon (childrenRect here would
                        // include the field itself: circular binding).
                        width: parent.width - searchIcon.width - parent.spacing
                        anchors.verticalCenter: parent.verticalCenter
                        color: Colors.overBackground
                        font.family: Styling.defaultFont
                        font.pixelSize: Styling.fontSize(2)
                        selectByMouse: true
                        focus: root.open
                        text: root.query
                        onTextEdited: root.query = text
                        Keys.onEscapePressed: root.closeLauncher()
                        Keys.onReturnPressed: root.installSelected()
                        Keys.onEnterPressed: root.installSelected()
                        Keys.onUpPressed: root.select(-1)
                        Keys.onDownPressed: root.select(1)
                        Keys.onPressed: function(event) {
                            if ((event.key === Qt.Key_D) && (event.modifiers & Qt.ControlModifier)) {
                                root.removeSelected();
                                event.accepted = true;
                            } else if ((event.key === Qt.Key_U) && (event.modifiers & Qt.ControlModifier)) {
                                root.updateAll();
                                event.accepted = true;
                            }
                        }

                        Text {
                            anchors.fill: parent
                            verticalAlignment: TextInput.AlignVCenter
                            visible: !searchField.text
                            text: "Search packages…  (repos + AUR)"
                            color: root.alpha(Colors.overBackground, 0.45)
                            font: searchField.font
                        }
                    }
                }
            }

            Text {
                width: parent.width
                textFormat: Text.PlainText
                text: root.status
                color: root.alpha(Colors.overBackground, 0.7)
                font.family: Styling.defaultFont
                font.pixelSize: Styling.fontSize(0)
                horizontalAlignment: Text.AlignRight
                elide: Text.ElideRight
            }

            Row {
                width: parent.width
                height: parent.height - 46 - 24 - parent.spacing * 2 - 20
                spacing: 12

                ListView {
                    id: resultsList
                    width: parent.width * 0.55 - 6
                    height: parent.height
                    clip: true
                    spacing: 4
                    model: root.results.length
                    cacheBuffer: 600

                    delegate: Rectangle {
                        required property int index
                        readonly property var pkg: root.results[index]

                        width: resultsList.width
                        height: 54
                        radius: 10
                        color: root.selected === index ? root.alpha(Colors.primary, 0.14) : "transparent"

                        Rectangle {
                            anchors.left: parent.left
                            anchors.verticalCenter: parent.verticalCenter
                            width: 3
                            height: 34
                            radius: 2
                            visible: root.selected === index
                            color: Colors.primary
                        }

                        Column {
                            anchors.fill: parent
                            anchors.leftMargin: 14
                            anchors.rightMargin: 14
                            anchors.topMargin: 7
                            spacing: 2

                            // Header line: name (left, elided) · repo/version ·
                            // ✓ instalado (right). Anchored to the actual row
                            // width instead of fixed pixel widths, so it fits
                            // the narrower list next to the details pane.
                            Item {
                                width: parent.width
                                height: 20

                                Text {
                                    id: installedMark
                                    anchors.right: parent.right
                                    anchors.verticalCenter: parent.verticalCenter
                                    textFormat: Text.PlainText
                                    readonly property var upd: root.updates[pkg ? pkg.name : ""]
                                    visible: pkg ? (pkg.installed || upd !== undefined && upd !== null) : false
                                    text: installedMark.upd ? ("↑ " + installedMark.upd.to) : "✓ installed"
                                    color: installedMark.upd ? Colors.tertiary : Colors.primary
                                    font.family: Styling.defaultFont
                                    font.pixelSize: Styling.fontSize(0)
                                    font.weight: Font.DemiBold
                                }

                                Text {
                                    id: repoVer
                                    anchors.right: installedMark.visible ? installedMark.left : parent.right
                                    anchors.rightMargin: installedMark.visible ? 8 : 0
                                    anchors.verticalCenter: parent.verticalCenter
                                    textFormat: Text.PlainText
                                    text: pkg ? (pkg.repo ? (pkg.repo + "/" + pkg.version) : pkg.version) : ""
                                    color: root.alpha(Colors.overBackground, 0.55)
                                    font.family: Styling.defaultFont
                                    font.pixelSize: Styling.fontSize(0)
                                }

                                Text {
                                    anchors.left: parent.left
                                    anchors.right: repoVer.left
                                    anchors.rightMargin: 8
                                    anchors.verticalCenter: parent.verticalCenter
                                    textFormat: Text.PlainText
                                    text: pkg ? pkg.name : ""
                                    color: Colors.overBackground
                                    font.family: Styling.defaultFont
                                    font.pixelSize: Styling.fontSize(1)
                                    font.weight: Font.DemiBold
                                    elide: Text.ElideRight
                                }
                            }

                            Text {
                                width: parent.width
                                textFormat: Text.PlainText
                                text: pkg ? pkg.description : ""
                                color: root.alpha(Colors.overBackground, 0.75)
                                font.family: Styling.defaultFont
                                font.pixelSize: Styling.fontSize(0)
                                elide: Text.ElideRight
                                maximumLineCount: 1
                            }
                        }

                        MouseArea {
                            anchors.fill: parent
                            cursorShape: Qt.PointingHandCursor
                            hoverEnabled: true
                            onClicked: {
                                root.selected = parent.index;
                                resultsList.positionViewAtIndex(parent.index, ListView.Contain);
                            }
                            onDoubleClicked: root.installSelected()
                        }
                    }

                    Text {
                        anchors.centerIn: parent
                        visible: !root.searching && root.results.length === 0
                        text: root.query ? "No results" : "Loading installed…"
                        color: root.alpha(Colors.overBackground, 0.5)
                        font.family: Styling.defaultFont
                        font.pixelSize: Styling.fontSize(1)
                    }
            }

                // Details pane (lazy `<helper> -Si` for the selected package).
                Rectangle {
                    width: parent.width - resultsList.width - parent.spacing
                    height: parent.height
                    radius: 12
                    color: root.alpha(Colors.surface, 0.55)
                    border.color: root.alpha(Colors.outline, 0.35)

                    Column {
                        anchors.fill: parent
                        anchors.margins: 14
                        spacing: 7

                        Text {
                            width: parent.width
                            textFormat: Text.PlainText
                            text: root.details.Name ? root.details.Name : (root.results[root.selected] ? root.results[root.selected].name : "")
                            color: Colors.overBackground
                            font.family: Styling.defaultFont
                            font.pixelSize: Styling.fontSize(1)
                            font.weight: Font.Bold
                            elide: Text.ElideRight
                        }

                        Text {
                            width: parent.width
                            textFormat: Text.PlainText
                            visible: root.results[root.selected] ? root.results[root.selected].installed : false
                            text: "✓ Already installed — ↵ reinstalls/updates it"
                            color: Colors.primary
                            font.family: Styling.defaultFont
                            font.pixelSize: Styling.fontSize(0)
                            font.weight: Font.DemiBold
                            wrapMode: Text.WordWrap
                        }

                        Text {
                            width: parent.width
                            textFormat: Text.PlainText
                            readonly property var upd: root.updates[root.results[root.selected] ? root.results[root.selected].name : ""]
                            visible: upd !== undefined && upd !== null
                            text: upd ? ("↑ Update: " + upd.from + "  →  " + upd.to) : ""
                            color: Colors.tertiary
                            font.family: Styling.defaultFont
                            font.pixelSize: Styling.fontSize(0)
                            font.weight: Font.DemiBold
                            wrapMode: Text.WordWrap
                        }

                        Text {
                            width: parent.width
                            textFormat: Text.PlainText
                            visible: !!(root.details.Description || (root.results[root.selected] ? root.results[root.selected].description : ""))
                            text: root.details.Description ? root.details.Description : (root.results[root.selected] ? root.results[root.selected].description : "")
                            color: root.alpha(Colors.overBackground, 0.75)
                            font.family: Styling.defaultFont
                            font.pixelSize: Styling.fontSize(0)
                            wrapMode: Text.WordWrap
                            maximumLineCount: 4
                            elide: Text.ElideRight
                        }

                        Repeater {
                            model: root.detailRows(root.details)

                            delegate: Column {
                                required property var modelData
                                width: parent.width
                                spacing: 1

                                Text {
                                    textFormat: Text.PlainText
                                    text: modelData.label
                                    color: root.alpha(Colors.overBackground, 0.45)
                                    font.family: Styling.defaultFont
                                    font.pixelSize: Styling.fontSize(0)
                                }

                                Text {
                                    width: parent.width
                                    textFormat: Text.PlainText
                                    text: modelData.value
                                    color: root.alpha(Colors.overBackground, 0.85)
                                    font.family: Styling.defaultFont
                                    font.pixelSize: Styling.fontSize(0)
                                    wrapMode: Text.WordWrap
                                    maximumLineCount: 3
                                    elide: Text.ElideRight
                                }
                            }
                        }
                    }
                }
            }


            Text {
                width: parent.width
                textFormat: Text.PlainText
                text: "↵ install   ·   Ctrl+D remove   ·   Ctrl+U update all   ·   Esc close"
                color: root.alpha(Colors.overBackground, 0.45)
                font.family: Styling.defaultFont
                font.pixelSize: Styling.fontSize(0)
                horizontalAlignment: Text.AlignHCenter
                elide: Text.ElideRight
            }
        }
    }
}
