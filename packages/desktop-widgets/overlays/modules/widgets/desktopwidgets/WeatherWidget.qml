pragma ComponentBehavior: Bound
import QtQuick
import qs.modules.theme
import qs.modules.services
import "WidgetType.js" as WidgetType

// Desktop weather card, in three content families:
//   compact  (280x80)  symbol, temperature and the condition, on one line
//   full     (280x190) current condition, today's range, wind and sun times
//   detailed (280x240) full plus the next six days from WeatherService.forecast, each
//                      with its emoji and range
//
// Data comes straight from Ambxst's WeatherService — the same the bar uses, nothing
// invented. The type scale is the mod's shared rule (WidgetType.js); the reference height
// per family is the card size at which this content renders at its base sizes, so extra
// card height buys bigger text instead of a void, and a card below that size keeps the
// base type (the type is never shrunk).
Item {
    id: root

    property string family: "full"

    readonly property bool compactMode: root.family === "compact"
    readonly property bool detailedMode: root.family === "detailed"
    readonly property bool ready: WeatherService.dataAvailable && !WeatherService.hasFailed

    // How tall this widget's content is at its base sizes, in the widget's own space.
    // Measured, not estimated: tests/text-extent.py reports the ink extent inside a card.
    readonly property int blockHeight: 110    // symbol + temperature, range, wind, sun
    readonly property int stripHeight: 80     // the six day columns and their lead-in

    // The days AFTER today. Today's range is already in the block above, and the service
    // labels its first entry "Today" — also wider than a three-letter column.
    readonly property var nextDays: {
        var out = [];
        var f = WeatherService.forecast || [];
        for (var i = 1; i < Math.min(7, f.length); i++) {
            out.push({
                day: String(f[i].dayName || ""),
                emoji: String(f[i].emoji || ""),
                max: Math.round(f[i].maxTemp) + "°",
                min: Math.round(f[i].minTemp) + "°",
            });
        }
        return out;
    }

    // The strip costs stripHeight, so a card too short for it falls back to the full
    // layout instead of overflowing: content stays inside the card, no ellipsis.
    readonly property bool showStrip: root.detailedMode && root.nextDays.length > 0
        && root.height >= root.blockHeight + root.stripHeight

    readonly property string symbolText: root.ready ? WeatherService.weatherSymbol : "…"
    readonly property string tempText: root.ready
        ? Math.round(WeatherService.currentTemp) + "°" : "—"
    readonly property string rangeText: "H " + Math.round(WeatherService.maxTemp) + "°   ·   L "
        + Math.round(WeatherService.minTemp) + "°"
    readonly property string windText: "Wind " + Math.round(WeatherService.windSpeed) + " km/h"
    readonly property string sunText: "↑ " + WeatherService.sunrise + "    ↓ " + WeatherService.sunset

    // Base sizes, before the scale.
    readonly property int symbolSize: Styling.fontSize(2) * 1.8
    readonly property int tempSize: Styling.fontSize(2) * 1.6
    readonly property int stripGap: 8

    // Longest line at its base size, per family — what the width cap is measured against.
    // The metrics never see the scale, so nothing chases its own tail.
    TextMetrics {
        id: sunMetrics
        font.family: Styling.defaultFont
        font.pixelSize: Styling.fontSize(0)
        text: root.ready ? root.sunText : ""
    }

    TextMetrics {
        id: compactMetrics
        font.family: Styling.defaultFont
        font.pixelSize: Styling.fontSize(0)
        text: root.symbolText + "  " + root.tempText + "  " + WeatherService.weatherDescription
    }

    // A strip column is as wide as its widest cell, taken from the data it will show.
    TextMetrics {
        id: dayLabelMetrics
        font.family: Styling.defaultFont
        font.pixelSize: Styling.fontSize(-1)
        text: "Wed"
    }

    TextMetrics {
        id: dayTempMetrics
        font.family: Styling.defaultFont
        font.pixelSize: Styling.fontSize(0)
        text: "24°"
    }

    TextMetrics {
        id: dayEmojiMetrics
        font.family: Styling.defaultFont
        font.pixelSize: Styling.fontSize(1)
        text: root.nextDays.length > 0 ? root.nextDays[0].emoji : ""
    }

    readonly property real columnWidth: Math.max(dayLabelMetrics.width,
        Math.max(dayTempMetrics.width, dayEmojiMetrics.width))

    readonly property real naturalWidth: {
        if (root.compactMode)
            return compactMetrics.width;
        var w = sunMetrics.width;
        if (root.showStrip)
            w = Math.max(w, 6 * root.columnWidth + 5 * root.stripGap);
        return w;
    }

    readonly property real typeScale: WidgetType.typeScaleFor(root.width, root.height,
        root.naturalWidth,
        WidgetType.innerHeight(root.compactMode ? 80 : (root.detailedMode ? 240 : 190)))

    function alpha(c, a) {
        return Qt.rgba(c.r, c.g, c.b, a);
    }

    // compact: symbol, temperature and condition on one line, centred.
    Row {
        visible: root.compactMode
        anchors.fill: parent
        spacing: 8 * root.typeScale

        Text {
            anchors.verticalCenter: parent.verticalCenter
            textFormat: Text.PlainText
            text: root.symbolText
            font.pixelSize: root.symbolSize * root.typeScale
        }

        Text {
            anchors.verticalCenter: parent.verticalCenter
            textFormat: Text.PlainText
            text: root.tempText
            color: Colors.overBackground
            font.family: Styling.defaultFont
            font.pixelSize: root.tempSize * root.typeScale
            font.weight: Font.DemiBold
        }

        Text {
            anchors.verticalCenter: parent.verticalCenter
            width: parent.width - x - 4
            textFormat: Text.PlainText
            text: WeatherService.weatherDescription
            color: root.alpha(Colors.overBackground, 0.75)
            font.family: Styling.defaultFont
            font.pixelSize: Styling.fontSize(0) * root.typeScale
            elide: Text.ElideRight
        }
    }

    // full and detailed: the stacked block, plus the forecast strip when it fits.
    Column {
        visible: !root.compactMode
        anchors.fill: parent
        spacing: 4 * root.typeScale

        Row {
            spacing: 10 * root.typeScale

            Text {
                anchors.verticalCenter: parent.verticalCenter
                textFormat: Text.PlainText
                text: root.symbolText
                font.pixelSize: root.symbolSize * root.typeScale
            }

            Text {
                anchors.verticalCenter: parent.verticalCenter
                textFormat: Text.PlainText
                text: root.tempText
                color: Colors.overBackground
                font.family: Styling.defaultFont
                font.pixelSize: root.tempSize * root.typeScale
                font.weight: Font.DemiBold
            }
        }

        Text {
            visible: root.ready
            textFormat: Text.PlainText
            text: root.rangeText
            color: root.alpha(Colors.overBackground, 0.75)
            font.family: Styling.defaultFont
            font.pixelSize: Styling.fontSize(1) * root.typeScale
        }

        Text {
            visible: root.ready
            textFormat: Text.PlainText
            text: root.windText
            color: root.alpha(Colors.overBackground, 0.55)
            font.family: Styling.defaultFont
            font.pixelSize: Styling.fontSize(0) * root.typeScale
        }

        Text {
            visible: root.ready
            textFormat: Text.PlainText
            text: root.sunText
            color: root.alpha(Colors.overBackground, 0.45)
            font.family: Styling.defaultFont
            font.pixelSize: Styling.fontSize(0) * root.typeScale
        }

        Text {
            visible: !root.ready
            textFormat: Text.PlainText
            text: WeatherService.isLoading ? "Loading weather…" : "Weather unavailable"
            color: root.alpha(Colors.overBackground, 0.55)
            font.family: Styling.defaultFont
            font.pixelSize: Styling.fontSize(0) * root.typeScale
        }

        // detailed: the six days after today. The columns stretch to the card's width;
        // the width cap above already guaranteed their text fits.
        Row {
            id: strip
            visible: root.showStrip
            topPadding: 10 * root.typeScale
            spacing: root.stripGap * root.typeScale
            width: parent.width

            Repeater {
                model: root.nextDays

                delegate: Column {
                    required property var modelData
                    width: (strip.width - (root.nextDays.length - 1) * strip.spacing)
                        / Math.max(1, root.nextDays.length)
                    spacing: 1 * root.typeScale

                    Text {
                        anchors.horizontalCenter: parent.horizontalCenter
                        textFormat: Text.PlainText
                        text: modelData.day
                        color: root.alpha(Colors.overBackground, 0.55)
                        font.family: Styling.defaultFont
                        font.pixelSize: Styling.fontSize(-1) * root.typeScale
                    }

                    Text {
                        anchors.horizontalCenter: parent.horizontalCenter
                        textFormat: Text.PlainText
                        text: modelData.emoji
                        font.pixelSize: Styling.fontSize(1) * root.typeScale
                    }

                    Text {
                        anchors.horizontalCenter: parent.horizontalCenter
                        textFormat: Text.PlainText
                        text: modelData.max
                        color: Colors.overBackground
                        font.family: Styling.defaultFont
                        font.pixelSize: Styling.fontSize(0) * root.typeScale
                    }

                    Text {
                        anchors.horizontalCenter: parent.horizontalCenter
                        textFormat: Text.PlainText
                        text: modelData.min
                        color: root.alpha(Colors.overBackground, 0.45)
                        font.family: Styling.defaultFont
                        font.pixelSize: Styling.fontSize(-1) * root.typeScale
                    }
                }
            }
        }
    }
}
