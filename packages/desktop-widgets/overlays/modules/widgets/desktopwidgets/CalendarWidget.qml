pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import qs.modules.widgets.dashboard.widgets.calendar
import qs.modules.theme
import qs.modules.services
import qs.config
import "WidgetType.js" as WidgetType

// Desktop calendar.
//
// The grid is NOT reimplemented here: it is the DASHBOARD's month panel
// (qs.modules.widgets.dashboard.widgets.calendar), so the cells, the fonts and the today
// highlight are the ones the rest of the shell draws — a second implementation would drift
// from that look the first time either side changed. What the dashboard's panel does not
// have is a size: its metrics are fixed, so in a tall card it draws the same ~250px of grid
// and leaves the rest of the glass empty. `patches/calendar-scale.patch` adds `metricScale`
// to that panel and to its day cell for this widget to set; the dashboard leaves it at 1 and
// renders as it always has.
//
// Two content families, three amounts of information:
//   compact  (280x112) the WEEK: the seven days of the current week in one row, today
//                      highlighted — the same dashboard cells, one row instead of six
//                      (the panel's `weekOnly`). A month needs ~250px of height at the
//                      base metrics, so the small tier is a week and not a squeezed
//                      month: less time, not smaller digits.
//   full     (360x360) the month grid, exactly as it has always rendered
//   detailed (552x332) full plus the agenda: the next events from today, one row each,
//                      with the colour of the calendar they come from beside them
//
// The card sizes are the ones the management menu applies when a family is picked; the
// scale is the mod's shared rule, not this widget's own (see WidgetType.js).
//
// The agenda needs room to be worth reading: a square-ish grid (>= 220 wide at scale 1) plus
// a list column. A `detailed` card that cannot pay for both falls back to the plain grid,
// the same way the other widgets drop a row they cannot fit.
Item {
    id: root

    property string family: "full"

    readonly property bool weekMode: root.family === "compact"

    // The width is not what limits the grid: the day cells stretch to fill their row and
    // the digits are capped by the row height, so only the height feeds the scale. In the
    // week tier the scale stays at its base: one row of cells in a 280-wide card is the
    // week, and the panel's own fits gate decides whether the letters arrive with it.
    readonly property real metricScale: WidgetType.typeScaleFor(root.width, root.height, 0,
        WidgetType.innerHeight(360))

    readonly property bool showAgenda: root.family === "detailed"
        && root.width >= 520 && root.height >= 300

    // The grid keeps its square-ish shape; the rest of a wide card goes to the list.
    readonly property real gridWidth: root.showAgenda ? Math.min(root.height, root.width - 300) : root.width

    readonly property real rowHeight: Math.max(16, Math.round(22 * root.metricScale))
    readonly property real headerHeight: Math.max(14, Math.round(20 * root.metricScale))

    // What the agenda draws: day headers and event rows, already trimmed to what the card
    // can pay for. Built in JS because a row that does not fit must not be drawn at all
    // (the same fits-gate the other widgets use for their extra rows).
    property var agendaModel: []

    // ---- the agenda ----------------------------------------------------------

    function dayLabel(ms) {
        var d = new Date(ms);
        var today = new Date();
        var midnight = function (x) {
            return new Date(x.getFullYear(), x.getMonth(), x.getDate()).getTime();
        };
        var diff = Math.round((midnight(d) - midnight(today)) / 86400000);
        if (diff === 0)
            return "Today";
        if (diff === 1)
            return "Tomorrow";
        return Qt.formatDateTime(d, "ddd d MMM");
    }

    function timeLabel(o) {
        if (o.allDay)
            return "All day";
        return Qt.formatDateTime(new Date(o.startMs), "HH:mm");
    }

    function buildAgenda() {
        if (!root.showAgenda || root.height <= 0) {
            root.agendaModel = [];
            return;
        }
        var budget = root.height - root.headerHeight - 8;
        var rows = [];
        var used = 0;
        var lastDay = "";
        var items = CalendarEventsService.upcoming(Date.now(), 80);
        for (var i = 0; i < items.length; i++) {
            var o = items[i];
            var day = Qt.formatDateTime(new Date(o.startMs), "yyyy-MM-dd");
            if (day !== lastDay) {
                // A day header is only worth drawing if its first event comes with it,
                // or the card ends on a heading with nothing under it.
                if (used + 2 * root.rowHeight > budget)
                    break;
                rows.push({ kind: "day", label: root.dayLabel(o.startMs) });
                used += root.rowHeight;
                lastDay = day;
            }
            if (used + root.rowHeight > budget)
                break;
            rows.push({
                kind: "event",
                time: root.timeLabel(o),
                title: o.summary,
                color: o.color
            });
            used += root.rowHeight;
        }
        root.agendaModel = rows;
    }

    Connections {
        target: CalendarEventsService
        function onEventsChanged() {
            root.buildAgenda();
        }
    }

    // "Today" stops being today at midnight and an event stops being upcoming once it
    // starts, so the list is rebuilt on the minute even when no file changed.
    Timer {
        interval: 60000
        repeat: true
        running: root.showAgenda
        onTriggered: root.buildAgenda()
    }

    onShowAgendaChanged: root.buildAgenda()
    onHeightChanged: root.buildAgenda()
    onWidthChanged: root.buildAgenda()

    Calendar {
        id: grid

        anchors.left: parent.left
        anchors.top: parent.top
        anchors.bottom: parent.bottom
        width: root.gridWidth
        metricScale: root.metricScale
        // The week tier: one row of the same cells instead of the six the month needs.
        weekOnly: root.weekMode
        // One dot per calendar with something that day. It is off in the dashboard's own
        // panel, so this is the only calendar in the shell that draws them.
        showEventDots: true
        // The day detail: the panel reports the tap, the service owns which day is open,
        // and the ring comes back from that same value — one truth for both ends.
        selectedDayKey: DesktopWidgetsService.detailDayKey
        // In edit mode the drag owns every press on a card, so the cells stop taking them.
        dayClicksEnabled: !DesktopWidgetsService.editMode
        onDayActivated: function (key) {
            DesktopWidgetsService.openDay(key);
        }
    }

    ColumnLayout {
        id: agenda

        visible: root.showAgenda
        anchors.left: grid.right
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.bottom: parent.bottom
        anchors.leftMargin: Math.round(14 * root.metricScale)
        spacing: 0

        Text {
            Layout.fillWidth: true
            Layout.preferredHeight: root.headerHeight
            text: "Upcoming"
            verticalAlignment: Text.AlignVCenter
            font.family: Config.defaultFont
            font.pixelSize: Math.round(11 * root.metricScale)
            font.weight: Font.Bold
            color: Colors.outline
        }

        Repeater {
            model: root.agendaModel

            delegate: RowLayout {
                id: row

                required property var modelData

                Layout.fillWidth: true
                Layout.preferredHeight: root.rowHeight
                spacing: Math.round(6 * root.metricScale)

                Text {
                    Layout.fillWidth: true
                    visible: row.modelData.kind === "day"
                    text: row.modelData.kind === "day" ? row.modelData.label : ""
                    verticalAlignment: Text.AlignVCenter
                    elide: Text.ElideRight
                    font.family: Config.defaultFont
                    font.pixelSize: Math.round(10 * root.metricScale)
                    font.weight: Font.Bold
                    color: Colors.primary
                }

                Rectangle {
                    visible: row.modelData.kind === "event"
                    Layout.preferredWidth: Math.max(2, Math.round(3 * root.metricScale))
                    Layout.preferredHeight: Math.round(10 * root.metricScale)
                    Layout.alignment: Qt.AlignVCenter
                    radius: width / 2
                    color: row.modelData.kind === "event" ? row.modelData.color : "transparent"
                }

                Text {
                    visible: row.modelData.kind === "event"
                    text: row.modelData.kind === "event" ? row.modelData.time : ""
                    Layout.preferredWidth: Math.round(52 * root.metricScale)
                    verticalAlignment: Text.AlignVCenter
                    elide: Text.ElideRight
                    font.family: Config.defaultFont
                    font.pixelSize: Math.round(10 * root.metricScale)
                    color: Colors.outline
                }

                Text {
                    Layout.fillWidth: true
                    visible: row.modelData.kind === "event"
                    text: row.modelData.kind === "event" ? row.modelData.title : ""
                    verticalAlignment: Text.AlignVCenter
                    elide: Text.ElideRight
                    font.family: Config.defaultFont
                    font.pixelSize: Math.round(11 * root.metricScale)
                    color: Colors.overSurface
                }
            }
        }

        Text {
            Layout.fillWidth: true
            Layout.preferredHeight: root.rowHeight
            visible: root.agendaModel.length === 0
            text: CalendarEventsService.sources.length === 0 ? "No calendars" : "Nothing upcoming"
            verticalAlignment: Text.AlignVCenter
            font.family: Config.defaultFont
            font.pixelSize: Math.round(10 * root.metricScale)
            color: Colors.outline
        }
    }

    Component.onCompleted: root.buildAgenda()
}
