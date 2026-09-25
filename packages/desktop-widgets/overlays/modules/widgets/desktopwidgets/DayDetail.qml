import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Wayland
import qs.config
import qs.modules.theme
import qs.modules.components
import qs.modules.services

// What one day holds, opened by tapping a day on a desktop calendar card.
//
// It is a SURFACE of its own, on purpose. A day's worth of events does not fit in a
// 280x112 card (the minimal tier is a week strip) and sizing every card to hold it would
// undo the family sizes the cards declare; as its own surface it is the same thing in all
// three tiers. It rides the Top layer because the cards live on the Bottom one, UNDER
// every window — a panel drawn below them would be invisible half the time.
//
// The state is the service's (`detailDayKey`): the card's tap sets it, this surface reads
// it, Esc clears it, and the ring on the cell follows the same value, so the two ends can
// never disagree about which day is open.
PanelWindow {
    id: root

    // `screen` is PanelWindow's own, and the Variants delegate in shell.qml sets it to
    // modelData. Declaring it again here shadowed the inherited property: the margins below
    // read the screen we were given, while the window itself opened on whichever output had
    // focus.

    anchors {
        top: true
        left: true
    }
    margins.top: Math.round((screen.height - implicitHeight) / 2)
    margins.left: Math.round((screen.width - implicitWidth) / 2)

    color: "transparent"
    exclusionMode: ExclusionMode.Ignore
    WlrLayershell.layer: WlrLayer.Top
    WlrLayershell.namespace: "ambxst:desktopwidgets-daydetail"
    // Exclusive while it is open, the way the management menu does it: this surface has to
    // see Esc, and nothing else in the shell expects the keyboard meanwhile.
    WlrLayershell.keyboardFocus: root.open ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None

    readonly property string dayKey: DesktopWidgetsService.detailDayKey
    readonly property bool open: root.dayKey !== ""
    visible: root.open

    implicitWidth: 360
    implicitHeight: Math.min(rowsColumn.implicitHeight + 32, root.screen.height - 24)

    // The events of the open day, straight from the service: it is the only thing that
    // knows how events are bucketed, and it hands them over already coloured and named.
    property var rows: []
    function rebuild() {
        root.rows = root.open ? CalendarEventsService.eventsOn(root.dayKey) : [];
    }
    onOpenChanged: root.rebuild()
    onDayKeyChanged: root.rebuild()
    Component.onCompleted: root.rebuild()

    Connections {
        target: CalendarEventsService
        function onEventsChanged() {
            root.rebuild();
        }
    }

    // The same vocabulary the agenda uses (Today / Tomorrow / All day), so the detail and
    // the card read alike. The date itself comes from the service's key, never re-parsed.
    function dayLabel(key) {
        var ms = CalendarEventsService.dayMs(key);
        if (ms === null || ms === undefined || isNaN(ms))
            return key;
        var d = new Date(ms);
        var midnight = function (x) {
            return new Date(x.getFullYear(), x.getMonth(), x.getDate()).getTime();
        };
        var diff = Math.round((midnight(d) - midnight(new Date())) / 86400000);
        if (diff === 0)
            return "Today";
        if (diff === 1)
            return "Tomorrow";
        if (diff === -1)
            return "Yesterday";
        return Qt.formatDateTime(d, "dddd d MMMM");
    }

    function timeLabel(e) {
        // A range whenever there is one: the end is what tells you that two events of the
        // day overlap, and an event with no end is drawn as its start alone.
        if (e.allDay)
            return "All day";
        var from = Qt.formatDateTime(new Date(e.startMs), "HH:mm");
        if (!e.endMs || e.endMs <= e.startMs)
            return from;
        return from + "-" + Qt.formatDateTime(new Date(e.endMs), "HH:mm");
    }

    // The line under a title: where it is and which calendar it came from (with three feeds
    // on one day, the dot alone does not say which one an event belongs to).
    function metaOf(e) {
        var parts = [];
        if (e.location)
            parts.push(e.location);
        if (e.sourceName)
            parts.push(e.sourceName);
        return parts.join("  ·  ");
    }

    StyledRect {
        id: panel
        anchors.fill: parent
        variant: "popup"
        enableShadow: true

        Keys.priority: Keys.BeforeItem
        Keys.onPressed: function (event) {
            if (event.key === Qt.Key_Escape) {
                DesktopWidgetsService.closeDay();
                event.accepted = true;
            }
        }
    }

    Flickable {
        anchors.fill: parent
        anchors.margins: 16
        contentWidth: width
        // Explicit: with a ColumnLayout as the content item, contentHeight stays 0 and
        // every row renders invisible (the same trap the management menu documents).
        contentHeight: rowsColumn.implicitHeight
        boundsBehavior: Flickable.StopAtBounds
        clip: true

        ColumnLayout {
            id: rowsColumn
            width: parent.width
            spacing: 6

            Text {
                Layout.fillWidth: true
                text: root.dayLabel(root.dayKey)
                elide: Text.ElideRight
                font.family: Config.defaultFont
                font.pixelSize: 12
                font.weight: Font.Bold
                color: Colors.primary
            }

            Text {
                Layout.fillWidth: true
                visible: root.rows.length === 0
                text: "No events"
                font.family: Config.defaultFont
                font.pixelSize: 11
                color: Colors.outline
            }

            Repeater {
                model: root.rows

                delegate: RowLayout {
                    id: eventRow

                    required property var modelData

                    Layout.fillWidth: true
                    spacing: 6

                    Rectangle {
                        Layout.preferredWidth: 3
                        Layout.preferredHeight: Math.round(eventRow.implicitHeight * 0.7)
                        Layout.alignment: Qt.AlignVCenter
                        radius: width / 2
                        color: eventRow.modelData.color
                    }

                    Text {
                        Layout.preferredWidth: 84
                        text: root.timeLabel(eventRow.modelData)
                        elide: Text.ElideRight
                        verticalAlignment: Text.AlignVCenter
                        font.family: Config.defaultFont
                        font.pixelSize: 10
                        color: Colors.outline
                    }

                    ColumnLayout {
                        Layout.fillWidth: true
                        spacing: 1

                        Text {
                            Layout.fillWidth: true
                            text: eventRow.modelData.summary !== "" ? eventRow.modelData.summary : "(no title)"
                            elide: Text.ElideRight
                            font.family: Config.defaultFont
                            font.pixelSize: 11
                            color: Colors.overSurface
                        }

                        Text {
                            Layout.fillWidth: true
                            visible: text !== ""
                            text: root.metaOf(eventRow.modelData)
                            elide: Text.ElideRight
                            font.family: Config.defaultFont
                            font.pixelSize: 10
                            color: Colors.outline
                        }
                    }
                }
            }
        }
    }

    onVisibleChanged: {
        if (visible)
            panel.forceActiveFocus();
    }
}
