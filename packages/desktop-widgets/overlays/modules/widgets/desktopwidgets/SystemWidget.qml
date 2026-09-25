pragma ComponentBehavior: Bound
import QtQuick
import qs.modules.theme
import qs.modules.services
import "WidgetType.js" as WidgetType

// Desktop system card, in three content families:
//   compact  (280x80)  the three percentages on one line, no bars
//   full     (280x190) the labelled bars: CPU with its temperature, RAM used/total, GPU
//   detailed (280x240) full plus the CPU history as a sparkline, and the disk line when
//                      the card is tall enough to pay for it
//
// Data comes from Ambxst's SystemResources — the same the dashboard metrics tab reads,
// nothing invented. The type scale is the mod's shared rule (WidgetType.js): a card at or
// below its family's normal size renders the base sizes exactly as before, and extra card
// height buys bigger text instead of a void.
Item {
    id: root

    property string family: "full"

    readonly property bool compactMode: root.family === "compact"
    readonly property bool detailedMode: root.family === "detailed"

    readonly property bool hasGpu: SystemResources.gpuDetected && SystemResources.gpuUsages
        && SystemResources.gpuUsages.length > 0

    // Short values for the one-line family, rich ones for the bars.
    readonly property string cpuPercent: Math.round(SystemResources.cpuUsage) + "%"
    readonly property string ramPercent: Math.round(SystemResources.ramUsage) + "%"
    readonly property string gpuPercent: Math.round(SystemResources.gpuUsages[0] || 0) + "%"

    readonly property string cpuValue: root.cpuPercent
        + (SystemResources.cpuTemp > 0 ? "   ·   " + SystemResources.cpuTemp + "°C" : "")
    readonly property string ramValue: (SystemResources.ramUsed / 1024 / 1024).toFixed(1) + " / "
        + (SystemResources.ramTotal / 1024 / 1024).toFixed(1) + " GB"
    // The GPU's temperature belongs to the detailed family: the full card's GPU row is
    // the usage alone, exactly as it always was.
    readonly property string gpuValue: root.gpuPercent
        + (root.detailedMode && SystemResources.gpuTemp > 0
            ? "   ·   " + SystemResources.gpuTemp + "°C" : "")

    readonly property var diskMount: (SystemResources.validDisks && SystemResources.validDisks.length > 0)
        ? SystemResources.validDisks[0] : ""
    readonly property real diskPercent: (root.diskMount !== "" && SystemResources.diskUsage)
        ? (SystemResources.diskUsage[root.diskMount] || 0) : -1
    readonly property string diskText: root.diskPercent >= 0
        ? ("Disk " + root.diskMount + "   " + Math.round(root.diskPercent) + "%") : ""

    readonly property int historyPoints: SystemResources.cpuHistory ? SystemResources.cpuHistory.length : 0

    // Content heights at the base sizes, in the widget's own space. Measured from the app
    // (tests/text-height.py --extent), not estimated: the gate below drops rows on these
    // numbers, so if they drift the card clips instead of adapting.
    readonly property int metricsHeight: 111   // three labelled bars, with the gaps between
    readonly property int sparkHeight: 34      // the CPU history strip and its lead-in
    readonly property int diskHeight: 30       // the disk line and its lead-in

    readonly property var rows: root.rowsThatFit(root.height, root.typeScale, root.detailedMode,
        root.historyPoints > 1, root.diskText !== "",
        root.metricsHeight, root.sparkHeight, root.diskHeight)

    readonly property bool showSpark: root.rows.spark
    readonly property bool showDisk: root.rows.disk

    // A row appears only when the card's height pays for it once the type is scaled, so
    // rows are dropped instead of squeezed and a taller card can afford more of them. A
    // detailed card only as tall as a normal one still gains the sparkline if it fits —
    // the family asks for more information, the height decides how much actually arrives.
    // Pure, so the widget and its test run the same numbers without a screen between them.
    function rowsThatFit(innerHeight, scale, detailed, sparkAvailable, diskAvailable,
                         metricsHeight, sparkHeight, diskHeight) {
        var used = metricsHeight;
        var spark = false, disk = false;
        if (detailed && sparkAvailable && innerHeight >= (used + sparkHeight) * scale) {
            spark = true;
            used += sparkHeight;
        }
        if (detailed && diskAvailable && innerHeight >= (used + diskHeight) * scale)
            disk = true;
        return { spark: spark, disk: disk };
    }

    // Base sizes, before the scale.
    readonly property int barHeight: 6

    // The longest line at its base size, per family — what the width cap is measured
    // against. The metrics never see the scale, so nothing chases its own tail.
    TextMetrics {
        id: compactMetrics
        font.family: Styling.defaultFont
        font.pixelSize: Styling.fontSize(1)
        text: "CPU 100%   RAM 100%   GPU 100%"
    }

    TextMetrics {
        id: cpuRowMetrics
        font.family: Styling.defaultFont
        font.pixelSize: Styling.fontSize(0)
        text: "CPU" + "        " + "100%   ·   100°C"
    }

    TextMetrics {
        id: ramRowMetrics
        font.family: Styling.defaultFont
        font.pixelSize: Styling.fontSize(0)
        text: "RAM" + "        " + "100.0 / 100.0 GB"
    }

    readonly property real naturalWidth: root.compactMode
        ? compactMetrics.width
        : Math.max(cpuRowMetrics.width, ramRowMetrics.width)

    readonly property real typeScale: WidgetType.typeScaleFor(root.width, root.height,
        root.naturalWidth,
        WidgetType.innerHeight(root.compactMode ? 80 : 190))

    function alpha(c, a) {
        return Qt.rgba(c.r, c.g, c.b, a);
    }

    // compact: the three percentages on one line, centred — the full card's numbers
    // without the bars.
    Row {
        visible: root.compactMode
        anchors.fill: parent
        spacing: 14 * root.typeScale

        component Pair: Row {
            id: pair
            property string label
            property string value
            spacing: 6 * root.typeScale
            anchors.verticalCenter: parent.verticalCenter

            Text {
                anchors.verticalCenter: parent.verticalCenter
                textFormat: Text.PlainText
                text: pair.label
                color: root.alpha(Colors.overBackground, 0.6)
                font.family: Styling.defaultFont
                font.pixelSize: Styling.fontSize(0) * root.typeScale
                font.weight: Font.DemiBold
            }

            Text {
                anchors.verticalCenter: parent.verticalCenter
                textFormat: Text.PlainText
                text: pair.value
                color: root.alpha(Colors.overBackground, 0.9)
                font.family: Styling.defaultFont
                font.pixelSize: Styling.fontSize(1) * root.typeScale
            }
        }

        Pair { label: "CPU"; value: root.cpuPercent }
        Pair { label: "RAM"; value: root.ramPercent }
        Pair { label: "GPU"; value: root.gpuPercent; visible: root.hasGpu }
    }

    // full and detailed: the labelled bars, plus whatever the height pays for.
    Column {
        visible: !root.compactMode
        anchors.fill: parent
        spacing: 12 * root.typeScale

        component Metric: Column {
            id: metric
            property string label
            property string value
            property real ratio: 0

            width: parent ? parent.width : 0
            spacing: 5 * root.typeScale

            Row {
                width: parent.width
                spacing: 8 * root.typeScale

                Text {
                    textFormat: Text.PlainText
                    text: metric.label
                    color: root.alpha(Colors.overBackground, 0.6)
                    font.family: Styling.defaultFont
                    font.pixelSize: Styling.fontSize(0) * root.typeScale
                    font.weight: Font.DemiBold
                }

                Text {
                    textFormat: Text.PlainText
                    text: metric.value
                    color: root.alpha(Colors.overBackground, 0.9)
                    font.family: Styling.defaultFont
                    font.pixelSize: Styling.fontSize(0) * root.typeScale
                }
            }

            Rectangle {
                width: parent.width
                height: root.barHeight * root.typeScale
                radius: height / 2
                color: root.alpha(Colors.overBackground, 0.12)

                Rectangle {
                    width: parent.width * Math.min(1, Math.max(0, metric.ratio))
                    height: parent.height
                    radius: parent.radius
                    color: Colors.primary

                    Behavior on width {
                        NumberAnimation { duration: 250; easing.type: Easing.OutCubic }
                    }
                }
            }
        }

        Metric {
            label: "CPU"
            value: root.cpuValue
            ratio: SystemResources.cpuUsage / 100
        }

        // detailed: the CPU history as bars at an absolute scale (0-100%), the same 50
        // samples the dashboard plots. Absolute, not auto-scaled: a quiet minute should
        // read as a low strip, not as a dramatic graph.
        Item {
            id: spark
            visible: root.showSpark
            width: parent.width
            // sparkHeight counts the Column's 12px lead-in too, so the strip itself is
            // that much shorter — otherwise the gate would promise more room than the row uses.
            height: (root.sparkHeight - 12) * root.typeScale

            Repeater {
                model: SystemResources.cpuHistory

                delegate: Rectangle {
                    required property var modelData
                    required property int index

                    readonly property real barWidth: (spark.width
                        - (root.historyPoints - 1) * 2) / Math.max(1, root.historyPoints)

                    x: index * (barWidth + 2)
                    width: barWidth
                    height: Math.max(2, spark.height * Math.min(1, Math.max(0, modelData)))
                    anchors.bottom: parent.bottom
                    radius: 1
                    color: root.alpha(Colors.primary, 0.7)
                }
            }
        }

        Metric {
            label: "RAM"
            // SystemResources reports KB (Ambxst's own metrics tab divides the
            // same way): /1024 -> MB, /1024 -> GB.
            value: root.ramValue
            ratio: SystemResources.ramUsage / 100
        }

        Metric {
            visible: root.hasGpu
            label: "GPU"
            value: root.gpuValue
            ratio: (SystemResources.gpuUsages[0] || 0) / 100
        }

        Text {
            visible: root.showDisk
            topPadding: 2 * root.typeScale
            textFormat: Text.PlainText
            text: root.diskText
            color: root.alpha(Colors.overBackground, 0.45)
            font.family: Styling.defaultFont
            font.pixelSize: Styling.fontSize(-1) * root.typeScale
        }
    }
}
