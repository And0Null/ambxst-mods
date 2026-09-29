pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Effects
import qs.modules.theme
import qs.modules.services

// Desktop player card: what is on the MPRIS bus right now, in content families — three
// AMOUNTS of information, never the same thing made smaller:
//   full     (360x360) the square: artwork on top, title, artist, transport
//
// Everything comes from MprisController (qs.modules.services), the shell's own MPRIS
// singleton: it already owns the player list, the capability flags and the persisted
// choice, so this card never talks to D-Bus and nothing runs while nothing plays.
Item {
    id: root

    // How much information to show. The widget layer sets this from the layout entry
    // (or from the group child) that renders this card.
    property string family: "full"

    readonly property var player: MprisController.activePlayer

    // No identity fallback on purpose: `hasSomethingToShow` below is built on this line, and
    // a player that publishes an identity but no track (an idle browser tab publishes
    // `{"mpris:length": 0}` and nothing else) would keep the card full of empty glass
    // forever. The identity belongs to the DETAILED family's bottom row, not to the title.
    readonly property string titleText: root.player ? (root.player.trackTitle || "") : ""
    readonly property string artistText: root.player ? (root.player.trackArtist || "") : ""
    readonly property string artUrl: root.player ? (root.player.trackArtUrl || "") : ""

    // The card leaves the screen when there is nothing to SHOW, which is NOT the same as
    // "no player": an idle Chromium tab publishes `{"mpris:length": 0}` and nothing else
    // (measured on this machine), so a bare player count would draw empty glass on a
    // desktop that has a browser open. A PAUSED player WITH a title still counts: there is
    // something to read and a play button worth pressing.
    readonly property bool hasSomethingToShow: root.titleText !== ""
        || root.artistText !== "" || root.artUrl !== ""
    readonly property bool cardHidden: !root.hasSomethingToShow

    // 224 of the square's 328 of widget, the rest for the text column under it:
    // 224 + 8 + 21 + 8 + 20 + 8 + 22 = 311 of 328.
    readonly property int artSide: 224

    Column {
        anchors.fill: parent
        spacing: 8

        // Artwork when the player publishes one, a themed tile when it does not: a card
        // that collapses when the art is missing reads as broken. (mpv hands the cover
        // over INLINE as a base64 data: URI, so either way this is the URL.)
        Rectangle {
            id: art
            anchors.horizontalCenter: parent.horizontalCenter
            width: root.artSide
            height: root.artSide
            radius: Styling.radius(4)
            color: Colors.surfaceContainer
            border.width: 1
            border.color: Colors.outline

            Image {
                id: artImage
                anchors.fill: parent
                anchors.margins: 1
                source: root.artUrl
                visible: root.artUrl !== "" && status === Image.Ready
                fillMode: Image.PreserveAspectCrop
                asynchronous: true

                // The cover is CLIPPED to the tile's radius. A Rectangle with `radius` does
                // NOT clip its children in QML, so without this mask the Image paints its
                // square corners over the arc: measured on a capture, the tile's rounded
                // corner did not exist at all and the photo read as a square pasted on a
                // round card.
                layer.enabled: true
                layer.effect: MultiEffect {
                    maskEnabled: true
                    maskSource: artMask
                    maskThresholdMin: 0.5
                    maskSpreadAtMin: 1.0
                }
            }

            // The mask itself: same rect and radius as the image area, never drawn, kept
            // alive as a texture for the MultiEffect (the shell's own idiom, BarBg.qml).
            Rectangle {
                id: artMask
                anchors.fill: parent
                anchors.margins: 1
                radius: Math.max(art.radius - 1, 0)
                color: "white"
                visible: false
                layer.enabled: true
            }

            Text {
                anchors.centerIn: parent
                visible: !artImage.visible
                text: Icons.note
                color: root.alpha(Colors.overBackground, 0.45)
                // Icons.font (Phosphor-Bold), NOT Styling.defaultFont: a glyph drawn with
                // the UI font renders as tofu, and no text-based check in the suite can
                // see that.
                font.family: Icons.font
                font.pixelSize: Math.round(root.artSide * 0.18)
            }
        }

        Text {
            width: parent.width
            textFormat: Text.PlainText
            text: root.titleText
            color: Colors.overBackground
            font.family: Styling.defaultFont
            font.pixelSize: Styling.fontSize(2)
            font.weight: Font.Bold
            horizontalAlignment: Text.AlignHCenter
            elide: Text.ElideRight
        }

        Text {
            width: parent.width
            textFormat: Text.PlainText
            text: root.artistText
            color: root.alpha(Colors.overBackground, 0.7)
            font.family: Styling.defaultFont
            font.pixelSize: Styling.fontSize(1)
            horizontalAlignment: Text.AlignHCenter
            elide: Text.ElideRight
        }

        // Transport, centred: each control exists only when the player says it can do it,
        // and every action goes through the controller. (mpv on a single file reports
        // CanGoNext and CanGoPrevious as false, so this row is play/pause alone — correct,
        // not broken.)
        Row {
            anchors.horizontalCenter: parent.horizontalCenter
            spacing: 18

            TransportButton {
                icon: Icons.previous
                enabledControl: MprisController.canGoPrevious
                onActivated: MprisController.previous()
            }

            TransportButton {
                icon: MprisController.isPlaying ? Icons.pause : Icons.play
                enabledControl: MprisController.canTogglePlaying
                onActivated: MprisController.togglePlaying()
            }

            TransportButton {
                icon: Icons.next
                enabledControl: MprisController.canGoNext
                onActivated: MprisController.next()
            }
        }
    }

    // Local, the way WidgetMenu keeps its own IconButton: the mod ships no shared button
    // component, and a glyph plus a TapHandler is the whole thing.
    component TransportButton: Text {
        id: button

        property string icon: ""
        property bool enabledControl: true
        signal activated()

        visible: button.enabledControl
        text: button.icon
        // `hover` is an id in this component's scope, not a property of the button:
        // `button.hover` is undefined and throws at binding time.
        color: hover.hovered ? Colors.primary : root.alpha(Colors.overBackground, 0.8)
        // Icons.font, not the UI font: the whole point of the component is drawing a
        // Phosphor glyph, and the UI font turns it into tofu.
        font.family: Icons.font
        font.pixelSize: Styling.fontSize(3)

        HoverHandler {
            id: hover
        }

        TapHandler {
            onTapped: button.activated()
        }
    }

    function alpha(c, a) {
        return Qt.rgba(c.r, c.g, c.b, a);
    }
}
