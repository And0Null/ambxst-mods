pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import Quickshell.Wayland
import qs.modules.theme
import qs.modules.services

// One input-transparent Bottom-layer surface per screen that draws the widgets
// from DesktopWidgetsService. It lives under windows (like the desktop icons)
// and steps aside while a fullscreen window owns this output's workspace.
// In edit mode (menu toggle) every card becomes draggable and gets a highlight
// border; the MouseAreas stay disabled otherwise, so the layer remains fully
// click-through in normal use.
PanelWindow {
    id: root

    // No `modelData` here on purpose: the Variants delegate declares it and
    // passes it as `screen`. Declaring it in both places makes the required
    // property uninitialized and the variant fails to build.
    anchors {
        top: true
        bottom: true
        left: true
        right: true
    }

    color: "transparent"
    exclusionMode: ExclusionMode.Ignore
    // Editing needs the widgets ABOVE your windows (a tiled window covering the
    // desktop would otherwise swallow every click on a card), so edit mode
    // remaps this surface to the Top layer; normal use stays under windows.
    WlrLayershell.layer: DesktopWidgetsService.editMode ? WlrLayer.Top : WlrLayer.Bottom
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
    // The `ambxst:*` layer rule in Ambxst's hyprland.lua already blurs this
    // namespace, which is what makes the glass frame translucent instead of grey.
    WlrLayershell.namespace: "ambxst:desktopwidgets"

    readonly property var compositorMonitor: AxctlService.monitorFor(root.screen)
    // True while a card is being dragged (Lucid pattern): the input mask then
    // covers the whole surface so a fast pointer can never leave the drag
    // surface; otherwise only the card rectangles take input and everything
    // else is click-through.
    property bool grabbing: false
    readonly property bool fullscreenUp: {
        if (!compositorMonitor || !compositorMonitor.activeWorkspace || !AxctlService.clients.values)
            return false;
        var ws = compositorMonitor.activeWorkspace.id;
        return AxctlService.clients.values.some(c => c.workspace && c.workspace.id === ws && c.fullscreen === true);
    }

    visible: DesktopWidgetsService.loaded && DesktopWidgetsService.widgets.length > 0 && !root.fullscreenUp

    // Safety net only: a card is placed from its anchor (a pixel distance to the
    // edge it sticks to), so the layout is already correct on any resolution.
    // This margin applies to the corner case of a screen too small for the
    // layout's own offsets, and keeps the card fully on screen there.
    readonly property int edgeMargin: 8

    // Alignment guides. While a card is dragged, its edges and centre are compared
    // with every other visible card's and with the screen margins; within
    // snapThreshold pixels the card jumps onto that line and the line is drawn
    // (screen coordinates, -1 = nothing to show).
    readonly property int snapThreshold: 6
    readonly property int edgeSnapMargin: 40
    property real guideX: -1
    property real guideY: -1

    // Bumped whenever the Repeater's children change so the mask Regions
    // re-resolve rep.itemAt(i) (Lucid pattern).
    property int rev: 0

    function frameAt(i) {
        var _ = rev;
        return (i >= 0 && i < rep.count) ? rep.itemAt(i) : null;
    }

    // Input mask (Lucid pattern): while a card is being dragged the mask
    // covers the whole surface so a fast pointer can never outrun the drag
    // surface; otherwise only the card rectangles take input and every other
    // pixel is click-through.
    mask: Region {
        x: 0
        y: 0
        width: root.grabbing ? root.width : 0
        height: root.grabbing ? root.height : 0

        regions: [
            Region { item: root.frameAt(0) },
            Region { item: root.frameAt(1) },
            Region { item: root.frameAt(2) },
            Region { item: root.frameAt(3) },
            Region { item: root.frameAt(4) },
            Region { item: root.frameAt(5) },
            Region { item: root.frameAt(6) },
            Region { item: root.frameAt(7) },
            Region { item: root.frameAt(8) },
            Region { item: root.frameAt(9) },
            Region { item: root.frameAt(10) },
            Region { item: root.frameAt(11) },
            Region { item: root.frameAt(12) },
            Region { item: root.frameAt(13) },
            Region { item: root.frameAt(14) },
            Region { item: root.frameAt(15) }
        ]
    }

    // Every place the dragged card could line up on one axis, each with the
    // screen coordinate of the line to draw: the screen margins and, for every
    // other visible card, its two edges and its centre (a centre match aligns the
    // centres even when the cards are different sizes).
    function snapCandidates(cell, axis) {
        var out = [];
        var size = axis === "x" ? cell.width : cell.height;
        var extent = axis === "x" ? root.width : root.height;
        var margin = root.edgeSnapMargin;
        out.push({ pos: margin, line: margin });
        out.push({ pos: extent - margin - size, line: extent - margin });
        // Dead centre: dropping here anchors the card to the middle of the output,
        // which is what keeps it centred on every resolution.
        out.push({ pos: Math.round((extent - size) / 2), line: Math.round(extent / 2) });
        for (var i = 0; i < rep.count; i++) {
            var o = root.frameAt(i);
            if (!o || !o.visible || o.index === cell.index)
                continue;
            var opos = axis === "x" ? o.x : o.y;
            var osize = axis === "x" ? o.width : o.height;
            out.push({ pos: opos, line: opos });
            out.push({ pos: opos + (osize - size) / 2, line: opos + osize / 2 });
            out.push({ pos: opos + osize - size, line: opos + osize });
        }
        return out;
    }

    // Nearest candidate within the threshold, otherwise the raw drag position.
    function snapAxis(cell, raw, axis) {
        var cands = root.snapCandidates(cell, axis);
        var best = null;
        var bestD = root.snapThreshold + 1;
        for (var i = 0; i < cands.length; i++) {
            var d = Math.abs(cands[i].pos - raw);
            if (d < bestD) {
                bestD = d;
                best = cands[i];
            }
        }
        return best ? { pos: best.pos, line: best.line } : { pos: raw, line: -1 };
    }

    function componentFor(type) {
        if (type === "clock")
            return clockComp;
        if (type === "calendar")
            return calendarComp;
        if (type === "weather")
            return weatherComp;
        if (type === "system")
            return systemComp;
        return null;
    }

    Component {
        id: clockComp
        ClockWidget {}
    }

    Component {
        id: calendarComp
        CalendarWidget {}
    }

    Component {
        id: weatherComp
        WeatherWidget {}
    }

    Component {
        id: systemComp
        SystemWidget {}
    }

    Repeater {
        id: rep
        model: DesktopWidgetsService.widgets
        onItemAdded: root.rev++
        onItemRemoved: root.rev++

        delegate: Item {
            id: cell

            required property var modelData
            required property int index
            readonly property var entry: modelData
            readonly property bool isGroup: entry.type === "group"
            readonly property var kids: (entry.children && entry.children.length) ? entry.children : []
            readonly property bool editable: DesktopWidgetsService.editMode && entry.enabled !== false

            // Single source of truth for the position: the persisted entry
            // anchor before a drag, the directly-assigned pixel position
            // during it, the persisted anchor again after. The grab offset is
            // tracked in GLOBAL coordinates: the MouseArea moves WITH the
            // widget, so its mouse.x/y is relative to the already-moved cell
            // and using it directly halves the travel (w = d - w_prev).
            property bool dragging: false
            property point pressPos
            property point grabGlobal

            // The anchor decides the position: the card keeps its pixel distance
            // to the edges it sticks to, so the gaps between cards and the
            // margins to the screen edge do NOT scale with the resolution.
            readonly property real anchoredX: entry.ax === "right" ? root.width - width - entry.ox
                : (entry.ax === "center" ? Math.round((root.width - width) / 2) : entry.ox)
            readonly property real anchoredY: entry.ay === "bottom" ? root.height - height - entry.oy
                : (entry.ay === "center" ? Math.round((root.height - height) / 2) : entry.oy)
            // Clamp, do not rescale: the card's size is intrinsic, so on a screen
            // too small for its anchor the card is pulled back onto it.
            readonly property real maxX: Math.max(0, root.width - width - root.edgeMargin)
            readonly property real maxY: Math.max(0, root.height - height - root.edgeMargin)

            x: Math.min(Math.max(anchoredX, 0), maxX)
            y: Math.min(Math.max(anchoredY, 0), maxY)
            width: entry.w
            height: entry.h
            // Hidden entries keep their spot (enabled: false in the layout).
            visible: entry.enabled !== false

            WidgetFrame {
                anchors.fill: parent
                highlighted: DesktopWidgetsService.editMode

                // A single widget.
                Loader {
                    anchors.fill: parent
                    visible: !cell.isGroup
                    sourceComponent: root.componentFor(cell.entry.type)
                    // A widget decides HOW MUCH to show from its family; assigned on
                    // load because the component is picked at runtime. A widget with
                    // no variants yet does not declare the property and ignores it.
                    onLoaded: {
                        if (item && item.family !== undefined)
                            item.family = Qt.binding(function () {
                                return cell.entry.family;
                            });
                    }
                }

                // A group: several widgets inside ONE card, evenly split, so the
                // desktop does not fill up with separate boxes. Stacked (default) or
                // side by side, by the entry's `direction`.
                Column {
                    anchors.fill: parent
                    visible: cell.isGroup && cell.entry.direction !== "row"
                    spacing: 14

                    Repeater {
                        model: cell.kids

                        delegate: Loader {
                            required property var modelData

                            width: parent.width
                            height: (parent.height - (cell.kids.length - 1) * 14) / Math.max(1, cell.kids.length)
                            sourceComponent: root.componentFor(modelData.type)
                            onLoaded: {
                                if (item && item.family !== undefined)
                                    item.family = Qt.binding(function () {
                                        return modelData.family;
                                    });
                            }
                        }
                    }
                }

                Row {
                    anchors.fill: parent
                    visible: cell.isGroup && cell.entry.direction === "row"
                    spacing: 14

                    Repeater {
                        model: cell.kids

                        delegate: Loader {
                            required property var modelData

                            width: (parent.width - (cell.kids.length - 1) * 14) / Math.max(1, cell.kids.length)
                            height: parent.height
                            sourceComponent: root.componentFor(modelData.type)
                            onLoaded: {
                                if (item && item.family !== undefined)
                                    item.family = Qt.binding(function () {
                                        return modelData.family;
                                    });
                            }
                        }
                    }
                }
            }

            // Drag surface. Declared after the frame in edit mode so dragging
            // wins over content clicks (calendar navigation and such); it is
            // disabled otherwise, and the disabled MouseArea leaves the events
            // to the content underneath.
            MouseArea {
                anchors.fill: parent
                enabled: cell.editable
                cursorShape: cell.dragging ? Qt.ClosedHandCursor : Qt.OpenHandCursor

                onPressed: mouse => {
                    // Read while the x/y binding is still alive: cell.x/y is
                    // the widget's start position, and cell.x + mouse.x/y is
                    // the cursor in global screen coords.
                    cell.pressPos = Qt.point(cell.x, cell.y);
                    cell.grabGlobal = Qt.point(cell.x + mouse.x, cell.y + mouse.y);
                    cell.dragging = true;
                    root.grabbing = true;
                }
                onPositionChanged: mouse => {
                    if (!cell.dragging)
                        return;
                    // Cursor in global coords (cell.x still holds the
                    // pre-assignment position): newPosition =
                    // start + (cursorNow - cursorAtPress). No feedback.
                    var now = Qt.point(cell.x + mouse.x, cell.y + mouse.y);
                    // The drag always starts from the raw position, never from the
                    // snapped one, so a snap cannot accumulate drift.
                    var rawX = cell.pressPos.x + (now.x - cell.grabGlobal.x);
                    var rawY = cell.pressPos.y + (now.y - cell.grabGlobal.y);
                    var sx = root.snapAxis(cell, rawX, "x");
                    var sy = root.snapAxis(cell, rawY, "y");
                    // Keep at least 40px on screen while dragging.
                    cell.x = Math.min(Math.max(sx.pos, -(cell.width - 40)), root.width - 40);
                    cell.y = Math.min(Math.max(sy.pos, -(cell.height - 40)), root.height - 40);
                    root.guideX = sx.line;
                    root.guideY = sy.line;
                }
                onReleased: {
                    cell.dragging = false;
                    root.grabbing = false;
                    root.guideX = -1;
                    root.guideY = -1;
                    // Store where the card now sticks: the nearest edge on each
                    // axis, keeping the side it already had when the drop lands
                    // in the dead zone around the middle. Distances are pixels,
                    // so a drop behaves the same on the next monitor.
                    var keptX = cell.entry.ax === "right" ? "far" : "near";
                    var keptY = cell.entry.ay === "bottom" ? "far" : "near";
                    // A card dropped on the middle of an axis becomes centre-anchored:
                    // a left/right anchor would drift off-centre on another output.
                    var centredX = Math.abs(cell.x + cell.width / 2 - root.width / 2) <= root.snapThreshold;
                    var centredY = Math.abs(cell.y + cell.height / 2 - root.height / 2) <= root.snapThreshold;
                    var right = !centredX && DesktopWidgetsService.anchorFor(cell.x, cell.width, root.width, keptX) === "far";
                    var bottom = !centredY && DesktopWidgetsService.anchorFor(cell.y, cell.height, root.height, keptY) === "far";
                    DesktopWidgetsService.setPosition(cell.index,
                        centredX ? "center" : (right ? "right" : "left"),
                        Math.round(centredX ? 0 : (right ? root.width - cell.x - cell.width : cell.x)),
                        centredY ? "center" : (bottom ? "bottom" : "top"),
                        Math.round(centredY ? 0 : (bottom ? root.height - cell.y - cell.height : cell.y)));
                }
                onCanceled: {
                    cell.dragging = false;
                    root.grabbing = false;
                    root.guideX = -1;
                    root.guideY = -1;
                }
            }
        }
    }

    // Guides, declared after the Repeater so they draw above the cards: a 1px line
    // in the theme's primary colour, spanning the output, shown only while a drag is
    // lined up with something.
    Rectangle {
        visible: DesktopWidgetsService.editMode && root.guideX >= 0
        x: Math.round(root.guideX)
        y: 0
        width: 1
        height: root.height
        color: Colors.primary
        opacity: 0.9
    }

    Rectangle {
        visible: DesktopWidgetsService.editMode && root.guideY >= 0
        x: 0
        y: Math.round(root.guideY)
        width: root.width
        height: 1
        color: Colors.primary
        opacity: 0.9
    }
}
