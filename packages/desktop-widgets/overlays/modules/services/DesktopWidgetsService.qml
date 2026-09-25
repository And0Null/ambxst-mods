pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io
import qs.modules.services

// Desktop widgets: a list of widget instances (type + position + size) read from
// ~/.config/ambxst/desktop-widgets.json. A position is an ANCHOR: which edge the
// card sticks to on each axis plus its distance to that edge in pixels, so gaps
// and margins are identical on every output and on a single screen (a screen
// fraction scales the gaps instead, which collides cards on a shorter output).
// No file = no widgets. The menu and the drag-to-move flow write back here.
Singleton {
    id: root

    // Register the Visibilities module from here instead of patching the
    // moduleNames literal: several mods mutate that same array, and a patch
    // hunk landing on the same lines as another mod's would not compose.
    // The per-screen `desktopwidgets` flag itself still comes from the
    // manifest's visibilities.patch.
    Component.onCompleted: {
        if (Visibilities.moduleNames.indexOf("desktopwidgets") === -1)
            Visibilities.moduleNames.push("desktopwidgets");
    }

    property bool loaded: false
    property var widgets: []
    // Global card alpha for every widget frame (0.3..1). Persisted as the
    // top-level "opacity" field of the layout file.
    property real opacity: 0.42
    // Design the current layout came from ("split", "rail", …), or "custom" once it
    // has been edited by hand. Informational: the menu highlights it.
    property string design: "custom"
    // Layout edit mode: the layers make the widgets draggable while this is on.
    // Global on purpose: dragging is a hands-on-the-deck gesture, and one flag
    // keeps WidgetLayer trivial (every screen gets identical edit affordances).
    property bool editMode: false

    // Guards the write -> watchChanges -> reload loop: FileView fires
    // onFileChanged for our own saves too (QFileSystemWatcher is unconditional),
    // so save() sets this first, onFileChanged skips the reload while a save of
    // ours is in flight, and onSaved/onSaveFailed clear it. A safety timer
    // drops the flag anyway if a save signal never arrives.
    property bool isSaving: false

    readonly property string configPath: (Quickshell.env("XDG_CONFIG_HOME") || (Quickshell.env("HOME") + "/.config")) + "/ambxst/desktop-widgets.json"

    // The screen a layout was authored on when it still stores fractions: the
    // biggest output, which is where a layout is normally built.
    // Designs: whole-layout templates the menu applies in one click. A design is
    // plain data — the same entries the layout file stores — so it is nothing but a
    // layout someone already arranged tidily. Every design has to FIT the smallest
    // desktop in play (1366x768 today): a card that does not fit gets clamped and
    // ends up overlapping something, so these numbers are constrained, not free.
    // `family` is carried per entry and per group child for future widget variants
    // (nothing reads it yet); `direction` lays a group out as a column (default) or
    // as a row. Tuning a design is editing this list, nothing else.
    readonly property var designs: [
        {
            id: "split", name: "Split",
            entries: [
                { type: "clock", ax: "left", ox: 57, ay: "top", oy: 88, w: 280, h: 190 },
                { type: "weather", ax: "left", ox: 57, ay: "top", oy: 372, w: 280, h: 190 },
                { type: "system", ax: "right", ox: 57, ay: "top", oy: 88, w: 280, h: 190 },
                { type: "calendar", ax: "right", ox: 57, ay: "top", oy: 372, w: 360, h: 360 }
            ]
        },
        {
            id: "rail", name: "Rail",
            entries: [
                { type: "clock", ax: "left", ox: 40, ay: "top", oy: 48, w: 280, h: 190 },
                { type: "weather", ax: "left", ox: 40, ay: "top", oy: 258, w: 280, h: 190 },
                { type: "system", ax: "left", ox: 40, ay: "top", oy: 468, w: 280, h: 190 },
                { type: "calendar", ax: "right", ox: 40, ay: "top", oy: 48, w: 360, h: 360 }
            ]
        },
        {
            id: "studio", name: "Studio",
            entries: [
                { type: "group", direction: "column", children: ["clock", "weather", "system"],
                  ax: "left", ox: 40, ay: "top", oy: 48, w: 320, h: 640 },
                { type: "calendar", ax: "right", ox: 40, ay: "top", oy: 48, w: 360, h: 360 }
            ]
        },
        {
            id: "row", name: "Row",
            entries: [
                { type: "group", direction: "row", children: ["clock", "weather", "system"],
                  ax: "left", ox: 40, ay: "top", oy: 48, w: 810, h: 222 },
                { type: "calendar", ax: "right", ox: 40, ay: "top", oy: 48, w: 360, h: 360 }
            ]
        },
        {
            id: "cluster", name: "Cluster",
            entries: [
                { type: "clock", ax: "left", ox: 40, ay: "top", oy: 48, w: 280, h: 190 },
                { type: "system", ax: "left", ox: 340, ay: "top", oy: 48, w: 280, h: 190 },
                { type: "weather", ax: "left", ox: 40, ay: "top", oy: 258, w: 280, h: 190 },
                { type: "calendar", ax: "left", ox: 340, ay: "top", oy: 258, w: 360, h: 360 }
            ]
        },
        {
            id: "minimal", name: "Minimal",
            entries: [
                { type: "clock", ax: "left", ox: 57, ay: "top", oy: 88, w: 280, h: 190 },
                { type: "calendar", ax: "right", ox: 57, ay: "top", oy: 372, w: 360, h: 360 },
                { type: "weather", ax: "left", ox: 57, ay: "top", oy: 372, w: 280, h: 190, enabled: false },
                { type: "system", ax: "right", ox: 57, ay: "top", oy: 88, w: 280, h: 190, enabled: false }
            ]
        },
        {
            id: "center", name: "Center",
            entries: [
                { type: "clock", ax: "center", ox: 0, ay: "top", oy: 60, w: 280, h: 190 },
                { type: "calendar", ax: "center", ox: 0, ay: "bottom", oy: 100, w: 360, h: 360 },
                { type: "weather", ax: "left", ox: 40, ay: "bottom", oy: 100, w: 280, h: 190, enabled: false },
                { type: "system", ax: "right", ox: 40, ay: "bottom", oy: 100, w: 280, h: 190, enabled: false }
            ]
        }
    ];

    function referenceScreen() {
        var screens = Quickshell.screens || [];
        var best = null;
        for (var i = 0; i < screens.length; i++) {
            var s = screens[i];
            if (!s || !s.width || !s.height)
                continue;
            if (!best || s.width * s.height > best.width * best.height)
                best = s;
        }
        return best ? { w: best.width, h: best.height } : { w: 1920, h: 1080 };
    }

    // Which side of the screen a card sticks to, on ONE axis: the nearest edge.
    // A card parked in the dead zone (half a card wide, around the middle) keeps
    // the side it already had, so nudging a centred card cannot flip its anchor
    // and teleport it on another output. Returns "near" (top/left) or "far".
    function anchorFor(pos, size, extent, current) {
        var mid = (extent - size) / 2;
        if (pos >= mid + size / 2)
            return "far";
        if (pos <= mid - size / 2)
            return "near";
        return current;
    }

    // Resolve one stored entry's anchors: the anchor fields when the file has
    // them, a one-shot conversion of the old fractions otherwise, using the
    // reference screen so the migration reproduces the current placement.
    function anchorsFor(w, size, ref) {
        var ax = (w.ax === "left" || w.ax === "right" || w.ax === "center") ? w.ax : null;
        var ox = (typeof w.ox === "number" && isFinite(w.ox)) ? Math.round(w.ox) : null;
        // "center" ignores the offset: it is anchored to the middle of the output.
        if (ax === "center" && ox === null)
            ox = 0;
        if (ax === null || ox === null) {
            var px = (typeof w.x === "number") ? w.x * ref.w : 40;
            ax = (anchorFor(px, size.w, ref.w, "near") === "far") ? "right" : "left";
            ox = Math.round(Math.max(0, ax === "right" ? ref.w - px - size.w : px));
        }
        var ay = (w.ay === "top" || w.ay === "bottom" || w.ay === "center") ? w.ay : null;
        var oy = (typeof w.oy === "number" && isFinite(w.oy)) ? Math.round(w.oy) : null;
        if (ay === "center" && oy === null)
            oy = 0;
        if (ay === null || oy === null) {
            var py = (typeof w.y === "number") ? w.y * ref.h : 60;
            ay = (anchorFor(py, size.h, ref.h, "near") === "far") ? "bottom" : "top";
            oy = Math.round(Math.max(0, ay === "bottom" ? ref.h - py - size.h : py));
        }
        return { ax: ax, ox: ox, ay: ay, oy: oy };
    }

    // Where a card lands, in pixels, on a W x H screen.
    function pixelRect(entry, W, H) {
        return {
            x: (entry.ax === "right") ? W - entry.ox - entry.w
                : (entry.ax === "center" ? Math.round((W - entry.w) / 2) : entry.ox),
            y: (entry.ay === "bottom") ? H - entry.oy - entry.h
                : (entry.ay === "center" ? Math.round((H - entry.h) / 2) : entry.oy),
            w: entry.w,
            h: entry.h
        };
    }

    // Miniature of a design entry for the picker: the very same placement the
    // desktop uses, computed on a 1920x1080 reference screen and scaled into the
    // thumbnail box, so a preview cannot drift from what applying the design does.
    readonly property int previewRefW: 1920
    readonly property int previewRefH: 1080

    function previewRect(entry, boxW, boxH) {
        var s = Math.min(boxW / root.previewRefW, boxH / root.previewRefH);
        var r = root.pixelRect(entry, root.previewRefW, root.previewRefH);
        return {
            x: Math.round(r.x * s),
            y: Math.round(r.y * s),
            w: Math.max(2, Math.round(r.w * s)),
            h: Math.max(2, Math.round(r.h * s))
        };
    }

    // Content family of a widget. Anything the file says is kept as-is: a value this
    // mod does not know (a hand-edited tier, a design from a newer version) must survive
    // a save instead of being silently rewritten, and the widget itself decides what it
    // can render — a family it does not implement falls back to its own full layout.
    function normalizeFamily(value) {
        return (typeof value === "string" && value.length > 0) ? value : "full";
    }

    // Group children are accepted as plain type names ("weather") or as objects
    // with a family, and always reach the layer as objects: giving a child its own
    // family later is then not a file-format change.
    function normalizeKids(list) {
        var out = [];
        if (!Array.isArray(list))
            return out;
        for (var i = 0; i < list.length; i++) {
            var k = list[i];
            if (typeof k === "string")
                out.push({ type: k, family: "full" });
            else if (k && k.type)
                out.push({ type: String(k.type), family: root.normalizeFamily(k.family) });
        }
        return out;
    }

    function parse(text) {
        try {
            var j = JSON.parse(text || "");
            var list = (j && Array.isArray(j.widgets)) ? j.widgets : [];
            var out = [];
            var ref = root.referenceScreen();
            for (var i = 0; i < list.length; i++) {
                var w = list[i] || {};
                if (!w.type)
                    continue;
                var size = { w: w.w || 300, h: w.h || 180 };
                var a = root.anchorsFor(w, size, ref);
                out.push({
                    type: String(w.type),
                    ax: a.ax,
                    ox: a.ox,
                    ay: a.ay,
                    oy: a.oy,
                    w: size.w,
                    h: size.h,
                    // Keep the entry hidden with an explicit "enabled: false"
                    // field instead of deleting it: toggling back on preserves
                    // the widget's position and size.
                    // Content family of the widget ("full" today; a design can
                    // ask for "compact" once the widgets have a second variant).
                    // Carried through the file untouched so a saved layout never
                    // loses it.
                    family: root.normalizeFamily(w.family),
                    // A "group" entry lays these widgets out inside one card:
                    // "column" (default) or "row".
                    direction: (w.direction === "row") ? "row" : "column",
                    enabled: (w.enabled === false) ? false : true,
                    children: root.normalizeKids(w.children)
                });
            }
            if (j && typeof j.opacity === "number" && !isNaN(j.opacity))
                root.opacity = Math.min(1, Math.max(0.3, j.opacity));
            if (j && typeof j.design === "string" && j.design.length > 0)
                root.design = j.design;
            return out;
        } catch (e) {
            console.warn("desktop-widgets: could not parse " + root.configPath + ":", e);
            return [];
        }
    }

    // Apply a whole design: the layout becomes the design's entries, the current
    // opacity is kept, and the file records which design it is — until something is
    // edited by hand, which marks it "custom".
    function applyDesign(id) {
        for (var i = 0; i < root.designs.length; i++) {
            var d = root.designs[i];
            if (d.id !== id)
                continue;
            var next = [];
            for (var k = 0; k < d.entries.length; k++) {
                var e = d.entries[k];
                next.push({
                    type: String(e.type),
                    ax: e.ax,
                    ox: e.ox,
                    ay: e.ay,
                    oy: e.oy,
                    w: e.w,
                    h: e.h,
                    family: root.normalizeFamily(e.family),
                    direction: (e.direction === "row") ? "row" : "column",
                    enabled: (e.enabled === false) ? false : true,
                    children: root.normalizeKids(e.children)
                });
            }
            widgets = next;
            design = d.id;
            saveGuard.stop();
            save();
            return;
        }
    }

    // Anything done by hand takes the layout away from the design it came from.
    function markCustom() {
        design = "custom";
    }

    // Mutation API — everything the menu and the drag flow need persists here.
    // setPosition takes the anchor itself (side + distance in px), computed by
    // the layer from where the card was dropped.
    function setPosition(index, ax, ox, ay, oy) {
        if (index < 0 || index >= widgets.length)
            return;
        var next = widgets.slice();
        var e = JSON.parse(JSON.stringify(next[index]));
        e.ax = (ax === "right" || ax === "center") ? ax : "left";
        e.ox = Math.max(0, Math.round(ox));
        e.ay = (ay === "bottom" || ay === "center") ? ay : "top";
        e.oy = Math.max(0, Math.round(oy));
        next[index] = e;
        widgets = next;
        root.markCustom();
        saveDebounce.restart();
    }

    function setVisible(index, value) {
        if (index < 0 || index >= widgets.length)
            return;
        var next = widgets.slice();
        var e = JSON.parse(JSON.stringify(next[index]));
        e.enabled = value ? true : false;
        next[index] = e;
        widgets = next;
        saveGuard.stop();
        save();
    }

    // Content families each widget can actually render, in the order the menu offers
    // them. Kept here (not in the menu) because it is the same fact the file format
    // carries; tests/widget-family-menu.py pins it against the widget QMLs, so a
    // widget that grows or loses a variant fails the suite instead of silently
    // offering a mode nothing draws.
    readonly property var familyOptions: ({
        clock: ["compact", "full", "detailed"],
        weather: ["compact", "full", "detailed"],
        system: ["compact", "full", "detailed"],
        calendar: ["compact", "full", "detailed"]
    })

    // Families for a type, always as a fresh list: the menu binds it straight to a
    // SegmentedSwitch, and a shared array would let one switch mutate another's model.
    function familiesFor(type) {
        var list = root.familyOptions[type];
        return list ? list.slice() : ["full"];
    }

    // A widget sees the card MINUS the frame (WidgetFrame.qml: anchors.margins 16 per
    // side), and every gate the widgets declare is in that inner space. So a target in
    // card space is the gate plus twice this inset. Both numbers are pinned against the
    // sources by tests/widget-family-menu.py: the inset by reading WidgetFrame.qml, the
    // gates by reading each widget and — for the calendar — by instantiating it at the
    // resulting size and asking it.
    readonly property int frameInset: 16

    // A family's own gate, where the widget has one that a normal card can miss:
    //   calendar + detailed -> the agenda draws only at width >= 520 && height >= 300
    //                          (CalendarWidget.qml, showAgenda)
    //   weather + detailed  -> the six-day strip draws only at
    //                          height >= blockHeight + stripHeight = 110 + 80 = 190
    //                          (WeatherWidget.qml, showStrip and its two heights)
    // The clock and the system card have no such gate: the clock draws its whole family at
    // any size, and the system card DROPS rows as the height runs out on purpose ("the
    // family asks for more, the height decides how much actually arrives", pinned by
    // tests/system-rows.js), so nothing is enforced for them. A zero means "this dimension
    // is not constrained".
    readonly property var familyGate: ({
        calendar: { detailed: { w: 520, h: 300 } },
        weather: { detailed: { w: 0, h: 190 } }
    })

    // The card size a family needs: its gate moved from widget space into card space.
    function familyTarget(type, family) {
        var perType = root.familyGate[type];
        var gate = (perType && perType[family]) ? perType[family] : null;
        if (!gate)
            return null;
        return {
            w: gate.w > 0 ? gate.w + root.frameInset * 2 : 0,
            h: gate.h > 0 ? gate.h + root.frameInset * 2 : 0
        };
    }

    // The card each family LIVES at, per type — the size written on the widget's own
    // header (a compact card is 280x80, a full one 280x190, a detailed one 280x240).
    // A family is an amount of information, so it is also the room that amount needs:
    // picking one sets the card to this size in EITHER direction, which is what makes
    // the minimal tier small — the card shrinks, the calendar's square included —
    // instead of the same box with a shorter line inside it.
    //
    // The calendar's minimal is a WEEK, one row of the same dashboard cells (the
    // panel's `weekOnly`), which is why it is a 280x112 strip and not a small month: a
    // month needs ~250px of height at the base metrics, and a month squeezed into a
    // small square is the tiny-digits-in-tiny-cells look this mod avoids. Its 112 = 80
    // of content + the 32 the frame takes; the numbers are pinned against the widget
    // sources by tests/widget-family-menu.py, which reads every one of them back out of
    // the QML and refuses a table that drifted.
    readonly property var naturalCards: ({
        clock: { compact: { w: 280, h: 80 }, full: { w: 280, h: 190 }, detailed: { w: 280, h: 240 } },
        weather: { compact: { w: 280, h: 80 }, full: { w: 280, h: 190 }, detailed: { w: 280, h: 240 } },
        system: { compact: { w: 280, h: 80 }, full: { w: 280, h: 190 }, detailed: { w: 280, h: 240 } },
        calendar: { compact: { w: 280, h: 112 }, full: { w: 360, h: 360 }, detailed: { w: 552, h: 332 } }
    })

    // null for a type with no families of its own (a group card draws its children) and
    // for a family string this version cannot draw — then the card keeps its size.
    function naturalCard(type, family) {
        var perType = root.naturalCards[type];
        var size = (perType && perType[family]) ? perType[family] : null;
        return size ? { w: size.w, h: size.h } : null;
    }

    // Set the content family of an entry (childIndex < 0) or of one of its group
    // children (childIndex >= 0). Like setVisible this is a content preference, not a
    // layout edit: it does not mark the layout "custom", and re-applying a design
    // resets it — the same deal visibility already has.
    //
    // Choosing a family SETS the card to that family's size, in either direction: the
    // minimal tier shrinks the card (the calendar's square included), the detailed one
    // grows it, and the full one puts it back to the normal size. The anchor is
    // untouched, so a right-anchored card keeps its distance to the edge, and only the
    // card itself is touched — a group child's family changes what it draws inside its
    // parent card, which owns the size. Picking the family that is already on is a
    // repair, not a second resize: the size is set, never accumulated.
    function setFamily(index, childIndex, family) {
        if (index < 0 || index >= widgets.length)
            return;
        var next = widgets.slice();
        var e = JSON.parse(JSON.stringify(next[index]));
        if (childIndex >= 0) {
            if (!e.children || childIndex >= e.children.length)
                return;
            e.children[childIndex].family = root.normalizeFamily(family);
        } else {
            e.family = root.normalizeFamily(family);
            var size = root.naturalCard(e.type, e.family);
            if (size) {
                e.w = size.w;
                e.h = size.h;
            }
        }
        next[index] = e;
        widgets = next;
        saveGuard.stop();
        save();
    }

    // Sane default sizes per type; groups default to one card with three kids.
    function defaultSizeFor(type) {
        if (type === "calendar")
            return { w: 360, h: 360 };
        if (type === "clock")
            return { w: 280, h: 190 };
        if (type === "weather")
            return { w: 280, h: 190 };
        if (type === "system")
            return { w: 280, h: 190 };
        return { w: 300, h: 220 };
    }

    // Adding happens from the menu, which knows the screen it is on, so the new
    // card is placed on THAT screen: corners first, then edges, then the centre.
    function addWidget(type, screenW, screenH) {
        var size = defaultSizeFor(type);
        var ref = root.referenceScreen();
        var W = screenW || ref.w;
        var H = screenH || ref.h;
        var m = 40;
        var candidates = [
            { x: m, y: m }, { x: W - size.w - m, y: m },
            { x: m, y: H - size.h - m }, { x: W - size.w - m, y: H - size.h - m },
            { x: (W - size.w) / 2, y: m }, { x: (W - size.w) / 2, y: H - size.h - m },
            { x: m, y: (H - size.h) / 2 }, { x: W - size.w - m, y: (H - size.h) / 2 },
            { x: (W - size.w) / 2, y: (H - size.h) / 2 }
        ];
        var spot = candidates[candidates.length - 1];
        for (var i = 0; i < candidates.length; i++) {
            var c = candidates[i];
            var overlaps = false;
            for (var k = 0; k < widgets.length; k++) {
                // Anchors only mean something per screen, so the overlap test is
                // done in the pixels this screen gives them.
                var r = root.pixelRect(widgets[k], W, H);
                if (c.x < r.x + r.w + 12 && c.x + size.w + 12 > r.x
                    && c.y < r.y + r.h + 12 && c.y + size.h + 12 > r.y) {
                    overlaps = true;
                    break;
                }
            }
            if (!overlaps) {
                spot = c;
                break;
            }
        }
        var farX = root.anchorFor(spot.x, size.w, W, "near") === "far";
        var farY = root.anchorFor(spot.y, size.h, H, "near") === "far";
        widgets = widgets.concat([{
            type: type,
            ax: farX ? "right" : "left",
            ox: Math.round(farX ? W - spot.x - size.w : spot.x),
            ay: farY ? "bottom" : "top",
            oy: Math.round(farY ? H - spot.y - size.h : spot.y),
            w: size.w, h: size.h, family: "full", direction: "column",
            enabled: true, children: []
        }]);
        root.markCustom();
        saveGuard.stop();
        save();
    }

    function removeWidget(index) {
        if (index < 0 || index >= widgets.length)
            return;
        var next = widgets.slice();
        next.splice(index, 1);
        widgets = next;
        root.markCustom();
        saveGuard.stop();
        save();
    }

    // Line up the cards that are already meant to share a line. On each axis and
    // anchor side, cards whose offsets differ by no more than alignTolerance are
    // treated as an accident (a few pixels off) and share the LARGEST offset, so
    // aligning never pushes a card closer to the edge. Anything further apart is
    // deliberate and keeps its own offset: a card stacked under another one always
    // sits at least a card height below it, and the next column at least a card
    // width to the side, so neither can be swallowed by a tolerance this small.
    readonly property int alignTolerance: 40

    function alignAxis(list, sideKey, offKey) {
        var groups = {};
        var i, k;
        for (i = 0; i < list.length; i++) {
            if (list[i].enabled === false)
                continue;
            var side = list[i][sideKey];
            if (!groups[side])
                groups[side] = [];
            groups[side].push(list[i]);
        }
        for (var side in groups) {
            var g = groups[side].sort(function (a, b) { return a[offKey] - b[offKey]; });
            // A cluster is measured from its FIRST card, not from the previous one,
            // so a chain of small steps cannot drag a whole column into one offset.
            var start = 0;
            for (i = 1; i <= g.length; i++) {
                if (i === g.length || g[i][offKey] - g[start][offKey] > root.alignTolerance) {
                    for (k = start; k < i; k++)
                        g[k][offKey] = g[i - 1][offKey];
                    start = i;
                }
            }
        }
    }

    function alignWidgets() {
        var next = JSON.parse(JSON.stringify(widgets));
        root.alignAxis(next, "ax", "ox");
        root.alignAxis(next, "ay", "oy");
        widgets = next;
        root.markCustom();
        saveGuard.stop();
        save();
    }

    function resetLayout() {
        // Back to the mod's own default look: the Split design, default opacity.
        opacity = 0.42;
        root.applyDesign("split");
    }

    function setOpacity(value) {
        var next = Math.min(1, Math.max(0.3, value));
        // The menu's slider is bound to this property and also fires when the file's
        // value arrives, so a write here would save the whole layout just for opening
        // the menu (and would rewrite a hand-edited file with the parsed model).
        // Writing only what actually changed keeps opening the menu read-only.
        if (next === opacity)
            return;
        opacity = next;
        saveDebounce.restart();
    }

    function toggleEditMode() {
        editMode = !editMode;
    }

    // Serialize and persist via FileView.setText (Quickshell writes atomically
    // through QSaveFile). setText() alone suffices — writeAdapter() is only
    // needed with a QML adapter, and Ambxst's own Config/services call setText
    // the same way.
    function save() {
        isSaving = true;
        saveGuard.restart();
        file.setText(JSON.stringify({ design: design, opacity: opacity, widgets: widgets }, null, 2));
    }

    // ---- the day detail ---------------------------------------------------------
    // The day whose detail is showing, "" when none. A day tap on a card sets it, the
    // detail surface reads it, Esc clears it, and the ring on the cell follows the same
    // value — one truth, so the panel and the overlay cannot disagree about the day.
    // Transient UI state: deliberately NOT part of the saved layout, because the file holds
    // where the cards are, not what you happened to be reading.
    property string detailDayKey: ""

    // A second tap on the day whose detail is already open closes it, so the day is a
    // toggle and there is no state the user cannot get out of.
    function openDay(key) {
        var k = (key === undefined || key === null) ? "" : String(key);
        root.detailDayKey = (k !== "" && k === root.detailDayKey) ? "" : k;
    }

    function closeDay() {
        root.detailDayKey = "";
    }

    Timer {
        id: saveDebounce
        // Debounced save for high-frequency mutations (drag steps, opacity
        // slider): it keeps being restarted while a drag moves, so the file
        // gets written once, 1s after the last gesture settles.
        interval: 1000
        onTriggered: root.save()
    }

    Timer {
        id: saveGuard
        // Safety net clearing isSaving if a save signal never arrives;
        // re-armed by save() right before each write.
        interval: 4000
        onTriggered: root.isSaving = false
    }

    FileView {
        id: file
        path: root.configPath
        watchChanges: true
        onLoaded: {
            root.widgets = root.parse(text());
            root.loaded = true;
        }
        onFileChanged: {
            // Loop guard: this also fires for our own writes (the watcher is
            // unconditional), so skip while a save of ours is in flight.
            if (root.isSaving)
                return;
            reload();
        }
        onSaved: root.isSaving = false
        onSaveFailed: {
            root.isSaving = false;
            console.warn("desktop-widgets: failed to save " + root.configPath);
        }
        onLoadFailed: {
            root.widgets = [];
            root.loaded = true;
        }
    }
}
