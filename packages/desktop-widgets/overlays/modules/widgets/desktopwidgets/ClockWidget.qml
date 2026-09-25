pragma ComponentBehavior: Bound
import QtQuick
import qs.modules.theme
import "WidgetType.js" as WidgetType

// Desktop clock, in three content families — three AMOUNTS of information, never the
// same thing made smaller:
//   compact  (280x80)  time and short date on one line, for strip and row cards
//   full     (280x190) big time, long date, year
//   detailed (280x240) full plus seconds and the calendar context: ISO week, day of
//                      the year
//
// The type scale is the mod's shared rule, not this widget's own: see WidgetType.js. Here
// it only gets the reference height of each family's normal card (190 for the stacked
// clock, 80 for the compact one). The hierarchy stays fixed: time primary, date
// secondary, rest tertiary.
Item {
    id: root

    property date now: new Date()
    // How much information to show. The widget layer sets this from the layout entry
    // (or from the group child) that renders this clock.
    property string family: "full"

    readonly property bool compactMode: root.family === "compact"
    readonly property bool detailedMode: root.family === "detailed"

    readonly property string timeText: Qt.formatDateTime(root.now, "HH:mm")
    readonly property string secondsText: Qt.formatDateTime(root.now, "ss")
    readonly property string dateText: Qt.formatDateTime(root.now, "dddd, d MMMM")
    readonly property string shortDateText: Qt.formatDateTime(root.now, "ddd d MMM")
    readonly property string widestTimeText: "0000"   // what a time can look like, widest

    readonly property int weekNumber: root.isoWeek(root.now)
    readonly property int dayOfYear: root.dayNumber(root.now)

    // Base sizes, before the scale: also what the width caps below are measured with.
    readonly property int bigSize: Styling.fontSize(2) * 2.6
    readonly property int compactTimeSize: Styling.fontSize(2) * 1.7

    // Natural widths at the BASE sizes, so the width cap never depends on the scale it
    // is feeding (no circular binding, no size that chases its own tail).
    TextMetrics {
        id: dateMetrics
        font.family: Styling.defaultFont
        font.pixelSize: Styling.fontSize(1)
        text: root.dateText
    }

    TextMetrics {
        id: compactMetrics
        font.family: Styling.defaultFont
        font.pixelSize: root.compactTimeSize
        text: root.widestTimeText + " " + root.shortDateText
    }

    // At each family's normal card height, and below it, the type is at its base size.
    readonly property real typeScale: WidgetType.typeScaleFor(root.width, root.height,
        root.compactMode ? compactMetrics.width : dateMetrics.width,
        WidgetType.innerHeight(root.compactMode ? 80 : 190))

    Timer {
        interval: 1000
        running: true
        repeat: true
        onTriggered: root.now = new Date()
    }

    // ISO-8601 week number: the week of the Thursday of this week, counted from the
    // Thursday of January 4th. Its own function so it can be checked against a reference
    // implementation instead of trusted.
    function isoWeek(date) {
        var d = new Date(date.getFullYear(), date.getMonth(), date.getDate());
        d.setDate(d.getDate() + 3 - ((d.getDay() + 6) % 7));          // -> Thursday
        var jan4 = new Date(d.getFullYear(), 0, 4);
        jan4.setDate(jan4.getDate() + 3 - ((jan4.getDay() + 6) % 7)); // -> its Thursday
        return 1 + Math.round((d - jan4) / 604800000);
    }

    // NOT named dayOfYear(): a property and a function with the same name collide in
    // QML, the property wins, and the binding ends up calling itself (logged as
    // "Property 'dayOfYear' ... is not a function" and rendering 0).
    function dayNumber(date) {
        return Math.floor((date - new Date(date.getFullYear(), 0, 0)) / 86400000);
    }

    // compact: one line, time on the left, short date on the right, both centred.
    Row {
        visible: root.compactMode
        anchors.fill: parent
        spacing: 12 * root.typeScale

        Text {
            anchors.verticalCenter: parent.verticalCenter
            textFormat: Text.PlainText
            text: root.timeText
            color: Colors.overBackground
            font.family: Styling.defaultFont
            font.pixelSize: root.compactTimeSize * root.typeScale
            font.weight: Font.Bold
        }

        Text {
            anchors.verticalCenter: parent.verticalCenter
            textFormat: Text.PlainText
            text: root.shortDateText
            color: root.alpha(Colors.overBackground, 0.75)
            font.family: Styling.defaultFont
            font.pixelSize: Styling.fontSize(0) * root.typeScale
        }
    }

    // full and detailed: the stacked look. The two extra rows exist only in detailed
    // mode, so the full card renders exactly as it always has, only scaled.
    Column {
        visible: !root.compactMode
        anchors.fill: parent
        spacing: 2 * root.typeScale

        Row {
            spacing: 4 * root.typeScale

            Text {
                id: bigTime
                textFormat: Text.PlainText
                text: root.timeText
                color: Colors.overBackground
                font.family: Styling.defaultFont
                font.pixelSize: root.bigSize * root.typeScale
                font.weight: Font.Bold
            }

            Text {
                visible: root.detailedMode
                anchors.baseline: bigTime.baseline
                textFormat: Text.PlainText
                text: root.secondsText
                color: root.alpha(Colors.overBackground, 0.5)
                font.family: Styling.defaultFont
                font.pixelSize: Styling.fontSize(2) * 0.95 * root.typeScale
                font.weight: Font.Bold
            }
        }

        Text {
            width: parent.width
            textFormat: Text.PlainText
            text: root.dateText
            color: root.alpha(Colors.overBackground, 0.75)
            font.family: Styling.defaultFont
            font.pixelSize: Styling.fontSize(1) * root.typeScale
            elide: Text.ElideRight
        }

        Text {
            textFormat: Text.PlainText
            text: Qt.formatDateTime(root.now, "yyyy")
            color: root.alpha(Colors.overBackground, 0.45)
            font.family: Styling.defaultFont
            font.pixelSize: Styling.fontSize(0) * root.typeScale
        }

        // detailed only: where this day sits in the calendar, as one muted line.
        Text {
            visible: root.detailedMode
            topPadding: 6 * root.typeScale
            textFormat: Text.PlainText
            text: "Week " + root.weekNumber + "  ·  Day " + root.dayOfYear
            color: root.alpha(Colors.overBackground, 0.45)
            font.family: Styling.defaultFont
            font.pixelSize: Styling.fontSize(-1) * root.typeScale
        }
    }

    function alpha(c, a) {
        return Qt.rgba(c.r, c.g, c.b, a);
    }
}
