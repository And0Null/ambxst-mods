pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io
import qs.modules.theme
import "../widgets/desktopwidgets/ics.js" as Ics

// Calendar events for the desktop widgets.
//
// ONE model, TWO doors: ~/.config/ambxst/desktop-widgets-calendars.json lists the
// sources (a URL or a local .ics path, a name and a color picked from the theme). This
// service reads that file, fetches every source and merges the lot by UID, so the same
// event arriving from two sources is ONE event. The management menu (when it grows a
// Calendars section) writes the SAME file instead of keeping its own store, so a
// hand-edited entry shows up in the menu and vice versa.
//
// Transport, measured on this machine (Quickshell 0.3.1), because both obvious answers
// are wrong:
//   - a URL goes through an ASYNC XMLHttpRequest. Sync XHR does not exist in QML
//     (`open(..., false)` + `send()` throws "Invalid state").
//   - a local path goes through a FileView: XHR on a file:// URL never reaches DONE.
//     The bonus is that a local .ics updates LIVE (watchChanges reloads it).
// No daemon anywhere: a timer inside the shell re-fetches the URLs every 30 minutes.
// That is not a service sitting at idle, it is one request every half hour.
//
// The file is mode 600 on purpose: a feed URL is a credential (Google's "secret address
// in iCal format", iCloud's published link), and every other ~/.config/ambxst/*.json is
// 644. Nothing here ever logs a URL.
Singleton {
    id: root

    readonly property string configPath: (Quickshell.env("XDG_CONFIG_HOME") || (Quickshell.env("HOME") + "/.config")) + "/ambxst/desktop-widgets-calendars.json"

    // Enabled sources, normalized: [{ key, name, colorName, url, path }]
    property var sources: []
    // Every event of every source, merged by UID and sorted by start.
    property var events: []
    // uid -> source, so an occurrence can be colored without re-scanning events.
    property var sourceOfUid: ({})
    property bool loaded: false
    // Anything that went wrong, in plain words: a file that would not parse, a feed that
    // answered 404. Silent failure is this shell's house style and it should not be ours.
    property var problems: []
    property int refreshMinutes: 30
    property double lastRefresh: 0

    // Raw text per source key, as it arrives (async, order unknown).
    property var texts: ({})

    // Every source in the file, enabled or not, in file order: the management menu edits
    // THIS list and writes it back, so a calendar that is switched off keeps its place and
    // its link.
    property var entries: []
    // Guards the write -> watch -> reload loop, the way DesktopWidgetsService does.
    property bool isSaving: false
    // Set when a write to the sources file failed, for the menu to show.
    property string saveError: ""
    // The file was read but its JSON does not parse. Writing would then replace every
    // calendar in it with whatever the menu holds, so every edit stops until it is fixed.
    property bool fileBroken: false

    // Colors are NAMES from the theme's matugen-generated palette, never a hardcoded
    // hex: the palette moves when the wallpaper does, and a source that picked `cyan`
    // keeps matching the desktop afterwards. A source with no color gets one in order.
    readonly property var paletteNames: ["primary", "secondary", "tertiary", "cyan", "green", "magenta", "yellow", "blue", "red"]
    readonly property var palette: ({
        "primary": Colors.primary,
        "secondary": Colors.secondary,
        "tertiary": Colors.tertiary,
        "cyan": Colors.cyan,
        "green": Colors.green,
        "magenta": Colors.magenta,
        "yellow": Colors.yellow,
        "blue": Colors.blue,
        "red": Colors.red,
        "error": Colors.error
    })

    function colorNameFor(name, index) {
        var key = String(name || "").toLowerCase();
        if (root.palette[key] !== undefined)
            return key;
        return root.paletteNames[index % root.paletteNames.length];
    }

    function colorFor(name, index) {
        return root.palette[root.colorNameFor(name, index)];
    }

    // The palette name a source ended up with, by source key (the dots need it).
    function colorNameOf(key) {
        for (var i = 0; i < root.sources.length; i++) {
            if (root.sources[i].key === key)
                return root.sources[i].colorName;
        }
        return root.paletteNames[0];
    }

    function colorOf(key) {
        return root.palette[root.colorNameOf(key)];
    }

    function expandPath(path) {
        if (path.indexOf("~/") === 0)
            return Quickshell.env("HOME") + path.slice(1);
        return path;
    }

    function note(problem) {
        if (problem === "" || root.problems.indexOf(problem) !== -1)
            return;
        var next = root.problems.slice();
        next.push(problem);
        root.problems = next;
    }

    // ---- the sources file ------------------------------------------------------

    function applySources(text) {
        var list = [];
        var problems = [];
        var data = null;
        try {
            data = JSON.parse(text || "{}");
        } catch (e) {
            root.problems = ["could not read " + root.configPath + ": " + e];
            root.fileBroken = true;
            root.entries = [];
            root.sources = [];
            root.texts = ({});
            root.merge();
            root.loaded = true;
            return;
        }
        root.fileBroken = false;
        var raw = (data && data.sources) ? data.sources : [];
        var entries = [];
        for (var i = 0; i < raw.length; i++) {
            var s = raw[i] || {};
            entries.push({
                name: String(s.name || ("Calendar " + (i + 1))),
                color: String(s.color || ""),
                url: String(s.url || ""),
                path: String(s.path || ""),
                enabled: s.enabled !== false
            });
            if (s.enabled === false)
                continue;
            var url = String(s.url || "");
            var path = root.expandPath(String(s.path || ""));
            if (url === "" && path === "") {
                problems.push("source " + (i + 1) + " has neither a url nor a path");
                continue;
            }
            // webcal:// is https:// with another scheme, nothing more.
            if (url.indexOf("webcal://") === 0)
                url = "https://" + url.slice(9);
            list.push({
                key: String(s.name || ("source" + i)) + "#" + i,
                name: String(s.name || ("Calendar " + (i + 1))),
                colorName: root.colorNameFor(s.color, i),
                url: url,
                path: path
            });
        }
        root.problems = problems;
        root.entries = entries;
        root.sources = list;
        // Keep the text of the sources that are still here: editing a name or a color must
        // not blank the desktop while every feed is fetched again. fetchUrls() below
        // refreshes them in the background either way.
        var kept = ({});
        for (var k in root.texts) {
            for (var m = 0; m < list.length; m++) {
                if (list[m].key === k) {
                    kept[k] = root.texts[k];
                    break;
                }
            }
        }
        root.texts = kept;
        root.merge();
        root.loaded = true;
        root.fetchUrls();
    }

    // A source answered (or did not): keep its text and re-merge once the dust settles,
    // so five sources landing at once parse once, not five times.
    function absorb(key, text, problem) {
        var next = {};
        for (var k in root.texts) {
            if (k !== key)
                next[k] = root.texts[k];
        }
        if (problem !== "" && problem !== undefined)
            root.note(problem);
        if (text)
            next[key] = text;
        root.texts = next;
        mergeTimer.restart();
    }

    // ---- fetching --------------------------------------------------------------

    function fetchUrls() {
        var urls = 0;
        for (var i = 0; i < root.sources.length; i++) {
            var s = root.sources[i];
            if (s.url === "")
                continue;
            urls++;
            root.request(s.key, s.url);
        }
        root.lastRefresh = Date.now();
        if (urls === 0)
            mergeTimer.restart();
    }

    function refresh() {
        root.fetchUrls();
        for (var i = 0; i < localReaders.count; i++) {
            var reader = localReaders.objectAt(i);
            if (reader && reader.path)
                reader.reload();
        }
    }

    function request(key, url) {
        var xhr = new XMLHttpRequest();
        xhr.onreadystatechange = function () {
            if (xhr.readyState !== XMLHttpRequest.DONE)
                return;
            if (xhr.status === 200)
                root.absorb(key, xhr.responseText, "");
            else
                root.absorb(key, "", "feed " + key + " answered HTTP " + xhr.status);
        };
        try {
            xhr.open("GET", url, true);
            xhr.send();
        } catch (e) {
            root.absorb(key, "", "could not request " + key + ": " + e);
        }
    }

    // One reader per local source: a real file watch, so editing the .ics shows up on the
    // desktop without waiting for the refresh timer.
    Instantiator {
        id: localReaders
        model: root.sources
        delegate: FileView {
            required property var modelData
            path: modelData.path
            watchChanges: true
            printErrors: false
            onLoaded: root.absorb(modelData.key, text(), "")
            onFileChanged: reload()
            onLoadFailed: function (error) {
                root.absorb(modelData.key, "", "could not read " + modelData.path);
            }
        }
    }

    FileView {
        id: sourcesFile
        path: root.configPath
        watchChanges: true
        printErrors: false
        onLoaded: root.applySources(text())
        onSaved: {
            // One parsing path: the file decides what the sources are, never the menu.
            root.isSaving = false;
            reload();
        }
        onSaveFailed: function (error) {
            root.isSaving = false;
            root.saveError = "could not write " + root.configPath;
            root.note(root.saveError);
        }
        onFileChanged: {
            // This also fires for our own write (the watcher is unconditional).
            if (root.isSaving)
                return;
            reload();
        }
        onLoadFailed: function (error) {
            // No file is a valid state: no calendars, no dots, no noise.
            root.applySources("");
        }
    }

    Timer {
        id: mergeTimer
        interval: 150
        onTriggered: root.merge()
    }

    Timer {
        interval: root.refreshMinutes * 60000
        repeat: true
        running: root.loaded
        onTriggered: root.refresh()
    }

    // ---- the merge -------------------------------------------------------------

    function merge() {
        var out = [];
        var seen = ({});
        var index = ({});
        for (var i = 0; i < root.sources.length; i++) {
            var s = root.sources[i];
            var text = root.texts[s.key];
            if (!text)
                continue;
            var parsed = [];
            try {
                parsed = Ics.parse(text);
            } catch (e) {
                root.note("could not parse " + s.name + ": " + e);
                continue;
            }
            var errors = parsed.errors || [];
            for (var e = 0; e < errors.length; e++)
                root.note(s.name + ": " + errors[e]);
            for (var j = 0; j < parsed.length; j++) {
                var ev = parsed[j];
                var uid = String(ev.uid || (s.key + ":" + ev.startMs + ":" + ev.summary));
                if (seen[uid])
                    continue;   // the same event from two sources is one event
                seen[uid] = true;
                ev.sourceKey = s.key;
                ev.sourceName = s.name;
                ev.colorName = s.colorName;
                ev.color = root.palette[s.colorName];
                index[uid] = ev;
                out.push(ev);
            }
        }
        out.sort(function (a, b) {
            return a.startMs - b.startMs;
        });
        root.sourceOfUid = index;
        root.events = out;
    }

    // ---- what the widgets ask for ----------------------------------------------

    // The next events from `fromMs`, expanded and in order. `count` caps the list; the
    // widget decides how many it can draw.
    function upcoming(fromMs, count) {
        var from = (fromMs === undefined || fromMs === null) ? Date.now() : fromMs;
        var list = Ics.occurrences(root.events, from, from + 400 * 86400000);
        var out = [];
        var limit = (count === undefined || count === null) ? list.length : count;
        for (var i = 0; i < list.length && out.length < limit; i++) {
            var o = list[i];
            var src = root.sourceOfUid[o.uid];
            o.colorName = src ? src.colorName : root.paletteNames[0];
            o.color = src ? src.color : root.palette[root.paletteNames[0]];
            o.sourceName = src ? src.sourceName : "";
            out.push(o);
        }
        return out;
    }

    // The key these maps are bucketed by ("YYYY-MM-DD", local), so a caller can look a day
    // up without reimplementing the format.
    function dayKey(ms) {
        return Ics.dayKey(ms);
    }

    // And back: the local midnight a key stands for, for a caller that holds a key and
    // wants a date to label it with.
    function dayMs(key) {
        return Ics.dayKeyToMs(key);
    }

    // The events of ONE local day, in order, each carrying its calendar's colour and name:
    // what a day detail draws. The key is this service's own day format, so a caller with a
    // date asks dayKey() for it and nothing else reimplements the bucket. An event that
    // touches the day from either side is in it (an all-day "Viaje a la costa" shows on
    // every day it spans), and a day with nothing is an empty list, never null.
    function eventsOn(key) {
        var ms = Ics.dayKeyToMs(key);
        if (ms === null || ms === undefined || isNaN(ms))
            return [];
        var grouped = Ics.groupByDay(root.events, ms, ms + 86400000);
        var list = grouped[key] || [];
        var out = [];
        for (var i = 0; i < list.length; i++) {
            var o = list[i];
            var src = root.sourceOfUid[o.uid];
            out.push({
                uid: o.uid,
                summary: o.summary,
                location: o.location,
                startMs: o.startMs,
                endMs: o.endMs,
                allDay: o.allDay ? true : false,
                recurring: o.recurring ? true : false,
                colorName: src ? src.colorName : root.paletteNames[0],
                color: src ? src.color : root.palette[root.paletteNames[0]],
                sourceName: src ? src.sourceName : ""
            });
        }
        return out;
    }

    // dayKey -> [color] for the days that carry events, one entry per CALENDAR with
    // something that day (not per event): a 28px cell fits three dots, not a count.
    function daysWithEvents(fromMs, toMs) {
        var grouped = Ics.groupByDay(root.events, fromMs, toMs);
        var out = ({});
        for (var key in grouped) {
            var names = [];
            var list = grouped[key];
            for (var i = 0; i < list.length; i++) {
                var src = root.sourceOfUid[list[i].uid];
                var name = src ? src.colorName : root.paletteNames[0];
                if (names.indexOf(name) === -1)
                    names.push(name);
            }
            var colors = [];
            for (var j = 0; j < names.length; j++)
                colors.push(root.palette[names[j]]);
            out[key] = colors;
        }
        return out;
    }

    // ---- the menu's half of the two doors ---------------------------------------

    // The color a new source gets: the first palette name nobody is using, so two
    // calendars do not arrive the same color by accident.
    function nextColorName() {
        var used = [];
        for (var i = 0; i < root.entries.length; i++)
            used.push(root.colorNameFor(root.entries[i].color, i));
        for (var j = 0; j < root.paletteNames.length; j++) {
            if (used.indexOf(root.paletteNames[j]) === -1)
                return root.paletteNames[j];
        }
        return root.paletteNames[root.entries.length % root.paletteNames.length];
    }

    // What the menu may show of a link. Never the whole thing: a feed URL is a credential
    // and the shell's log is plain text, so the file (mode 600) is the only place it lives.
    function sourceTail(entry) {
        var path = String(entry.path || "");
        if (path !== "")
            return path.split("/").pop();
        var url = String(entry.url || "");
        var host = url.replace(/^[a-zA-Z]+:\/\//, "").split("/")[0];
        return host + "..." + url.slice(-6);
    }

    // "" when the source was added, otherwise the reason it was not, in words the menu can
    // show. webcal:// is https:// with another scheme, the same translation applySources
    // does, so a link pasted from iCloud works either way.
    // Every edit goes through this first. A read that has not finished, or a file this
    // could not parse, means `entries` is not the user's real list - and writing it back
    // would delete calendars they still have. Refusing is recoverable; clobbering is not.
    // An index the menu may act on: inside the list, and the list is trustworthy.
    function canEdit(index) {
        if (index < 0 || index >= root.entries.length)
            return false;
        if (root.writable() !== "") {
            root.saveError = root.writable();
            return false;
        }
        return true;
    }

    function writable() {
        if (!root.loaded)
            return "Still reading the sources file - try again in a moment.";
        if (root.fileBroken)
            return "The sources file is not the JSON this reads, so it will not be overwritten. Fix it or delete it first.";
        return "";
    }

    function addSource(name, target, colorName) {
        var guard = root.writable();
        if (guard !== "")
            return guard;
        var t = String(target || "").trim();
        if (t === "")
            return "Paste a calendar link, or the path of a .ics file.";
        var url = "";
        var path = "";
        if (t.indexOf("webcal://") === 0)
            url = "https://" + t.slice(9);
        else if (t.indexOf("https://") === 0 || t.indexOf("http://") === 0)
            url = t;
        else if (t.indexOf("://") !== -1)
            // Any other scheme (ftp://, and whatever someone pastes) is not a link this can
            // fetch, and it must not fall through to the file branch just for ending in .ics.
            return "Only https://, webcal:// or a local .ics file.";
        else if (t.charAt(0) === "/" || t.charAt(0) === "~")
            // A local file must be absolute or home-relative: a bare or relative path would
            // be resolved against the shell's working directory, which is not where anyone
            // keeps their calendar, and it would fail silently.
            path = t;
        else
            return "A link starts with https:// or webcal://; a file path with / or ~.";
        var list = root.entries.slice();
        for (var i = 0; i < list.length; i++) {
            if (url !== "" && String(list[i].url || "") === url)
                return "That calendar is already in the list.";
            // Compare EXPANDED paths: ~/x.ics and /home/you/x.ics are the same file, and a
            // second copy of one calendar is exactly what the UID merge exists to hide.
            if (path !== "" && root.expandPath(String(list[i].path || "")) === root.expandPath(path))
                return "That file is already in the list.";
        }
        var entry = {
            name: String(name || "").trim() || ("Calendar " + (list.length + 1)),
            color: root.colorNameFor(colorName, list.length),
            enabled: true
        };
        if (url !== "")
            entry.url = url;
        else
            entry.path = path;
        list.push(entry);
        root.entries = list;
        root.save();
        return "";
    }

    function removeSource(index) {
        if (!root.canEdit(index))
            return;
        var list = root.entries.slice();
        list.splice(index, 1);
        root.entries = list;
        root.save();
    }

    function setSourceEnabled(index, on) {
        if (!root.canEdit(index))
            return;
        var list = root.entries.slice();
        list[index].enabled = on;
        root.entries = list;
        root.save();
    }

    function cycleSourceColor(index) {
        if (!root.canEdit(index))
            return;
        var list = root.entries.slice();
        var at = root.paletteNames.indexOf(root.colorNameFor(list[index].color, index));
        list[index].color = root.paletteNames[(at + 1) % root.paletteNames.length];
        root.entries = list;
        root.save();
    }

    // The file is the source of truth: this writes it (atomically, through QSaveFile) and
    // re-reads it. The menu keeps no copy of anything, which is what makes the two doors
    // impossible to disagree.
    function save() {
        var guard = root.writable();
        if (guard !== "") {
            root.saveError = guard;
            root.note(guard);
            return;
        }
        root.isSaving = true;
        root.saveError = "";
        sourcesFile.setText(JSON.stringify({ sources: root.entries }, null, 2));
    }
}
