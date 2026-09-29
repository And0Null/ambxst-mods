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

    // --- Which player the card is about -------------------------------------------------
    // The card follows the player that is WORTH SHOWING, not simply the one the controller
    // tracks. `MprisController.activePlayer` is `trackedPlayer ? trackedPlayer :
    // filteredPlayers[0]`, so a player that was once in front and then went quiet — a
    // browser left open — holds `activePlayer` forever while another app plays. Reading
    // that here would show an empty card, and the hidden rule below would turn that into no
    // card at all, with the music invisible and nothing left to tap to switch to it.
    //
    // The order, and the reason for each step:
    //   1. what you picked, WHILE it is playing — two players playing at once is exactly
    //      what the chooser exists for, so the pick has to outrank "first playing";
    //   2. otherwise the first player that is playing;
    //   3. nothing playing: a paused track you picked is still worth showing;
    //   4. otherwise any player with something to say;
    //   5. otherwise nothing, and the card hides.
    // "Something to show" is NOT the same as "something published": an idle browser tab sits
    // on the bus publishing its PAGE TITLE as `xesam:title` (measured here: a Helium tab as
    // "Profile - Kick Streaming", no artist, no art), so a bare title would keep the card
    // alive — a web page dressed as a song — on a desktop where nothing is playing. A player
    // counts when it is PLAYING (audio is coming out of it, and you want the pause button), or
    // when it publishes a TRACK: an artist or a cover.
    function worthShowing(p) {
        if (!p)
            return false;
        return p.isPlaying || (p.trackArtist || "") !== "" || (p.trackArtUrl || "") !== "";
    }

    readonly property var shownPlayer: {
        var list = MprisController.filteredPlayers;
        var tracked = MprisController.trackedPlayer;
        var i;
        if (tracked && tracked.isPlaying)
            return tracked;
        for (i = 0; i < list.length; i++)
            if (list[i].isPlaying)
                return list[i];
        if (root.worthShowing(tracked))
            return tracked;
        for (i = 0; i < list.length; i++)
            if (root.worthShowing(list[i]))
                return list[i];
        return null;
    }

    readonly property var player: root.shownPlayer

    // No identity fallback on purpose: the title is what this card calls a SONG, and a player
    // that publishes an identity but no track would put a browser's name in that place. The
    // identity belongs to the chooser's rows below and to the DETAILED family's bottom row,
    // where the thing being named is the PLAYER.
    readonly property string titleText: root.player ? (root.player.trackTitle || "") : ""
    readonly property string artistText: root.player ? (root.player.trackArtist || "") : ""
    readonly property string artUrl: root.player ? (root.player.trackArtUrl || "") : ""

    // Hidden is the rule that CHOSE the player, read back: one rule, so the two cannot drift
    // apart. A PAUSED player with an artist or a cover still counts — there is something to
    // read and a play button worth pressing — and so does a player that is PLAYING with no
    // tags at all: audio is coming out of it.
    readonly property bool hasSomethingToShow: root.worthShowing(root.player)
    readonly property bool cardHidden: !root.hasSomethingToShow

    // --- The chooser ---------------------------------------------------------------------
    // A MODE of this card, not a second surface: these card rectangles are the only region
    // this layer accepts input in, so a list drawn outside the card would not be clickable,
    // and the dashboard's player list already exists for full management. The shell's own
    // player list (dashboard/widgets/FullPlayer.qml) is the reference for the look: one row
    // per player, an icon mapped from the player's own name, the track title over the
    // player's identity, and picking writes MprisController so the choice sticks.
    readonly property bool canChoose: MprisController.filteredPlayers.length > 1
    property bool choosing: false
    // Bounded: past four players the dashboard is the editor, and the card does not grow
    // with how many players happen to be open.
    readonly property var chooserPlayers: MprisController.filteredPlayers.slice(0, 4)
    readonly property int labelSize: Styling.fontSize(0)

    // A player going away while the list is open would otherwise leave the card on the list
    // the next time it comes back.
    onCardHiddenChanged: if (root.cardHidden) root.choosing = false

    // 224 of the square's 328 of widget, the rest for the text column under it:
    // 224 + 8 + 21 + 8 + 20 + 8 + 22 = 311 of 328.
    readonly property int artSide: 224

    Column {
        id: body
        anchors.fill: parent
        spacing: 8
        visible: !root.choosing

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

        // The artist line doubles as the way into the chooser when there is more than one
        // player to choose from. The caret is the affordance: nothing else on the card
        // would say that a tap here opens a list.
        Row {
            id: artistRow
            anchors.horizontalCenter: parent.horizontalCenter
            spacing: 4

            Text {
                textFormat: Text.PlainText
                text: root.artistText
                color: root.alpha(Colors.overBackground, 0.7)
                font.family: Styling.defaultFont
                font.pixelSize: Styling.fontSize(1)
                elide: Text.ElideRight
                verticalAlignment: Text.AlignVCenter
                // Capped so the caret beside it always fits: the cover is this column's
                // natural content width.
                width: Math.min(implicitWidth, root.artSide - (root.canChoose ? 18 : 0))
            }

            Text {
                visible: root.canChoose
                text: Icons.caretDown
                color: artistHover.hovered ? Colors.primary : root.alpha(Colors.overBackground, 0.7)
                // Icons.font: a Phosphor glyph drawn with the UI font is tofu.
                font.family: Icons.font
                font.pixelSize: root.labelSize

                HoverHandler {
                    id: artistHover
                }
            }

            TapHandler {
                enabled: root.canChoose
                onTapped: root.choosing = !root.choosing
            }
        }

        // Transport, centred: each control exists only when the player says it can do it.
        // They act on the player the card SHOWS, not on MprisController: with two players on
        // the bus the controller's own controls belong to the one it tracks, which is not
        // necessarily the one on screen. (mpv on a single file reports CanGoNext and
        // CanGoPrevious as false, so this row is play/pause alone — correct, not broken.)
        Row {
            anchors.horizontalCenter: parent.horizontalCenter
            spacing: 18

            TransportButton {
                icon: Icons.previous
                enabledControl: root.player ? root.player.canGoPrevious : false
                onActivated: if (root.player) root.player.previous()
            }

            TransportButton {
                icon: (root.player && root.player.isPlaying) ? Icons.pause : Icons.play
                enabledControl: root.player ? root.player.canTogglePlaying : false
                onActivated: if (root.player) root.player.togglePlaying()
            }

            TransportButton {
                icon: Icons.next
                enabledControl: root.player ? root.player.canGoNext : false
                onActivated: if (root.player) root.player.next()
            }
        }
    }

    // The chooser, in the card's own place: the header is the way back out, and every row
    // is both the label and the pick.
    Column {
        id: chooser
        anchors.fill: parent
        spacing: 2
        visible: root.choosing

        Row {
            spacing: 4

            Text {
                text: Icons.caretLeft
                color: backHover.hovered ? Colors.primary : root.alpha(Colors.overBackground, 0.55)
                // Icons.font: a Phosphor glyph drawn with the UI font is tofu.
                font.family: Icons.font
                font.pixelSize: root.labelSize

                HoverHandler {
                    id: backHover
                }
            }

            Text {
                textFormat: Text.PlainText
                text: "Which player"
                color: root.alpha(Colors.overBackground, 0.55)
                font.family: Styling.defaultFont
                font.pixelSize: Styling.fontSize(-1)
            }

            TapHandler {
                onTapped: root.choosing = false
            }
        }

        Repeater {
            model: root.chooserPlayers

            delegate: Rectangle {
                id: chooserRow

                required property var modelData

                width: chooser.width
                height: 40
                radius: Styling.radius(2)
                // The one the card is showing is the one marked: that is the fact the tap
                // either confirms or changes.
                color: chooserRow.modelData === root.player ? Colors.surfaceBright : "transparent"
                border.width: chooserRow.modelData === root.player ? 1 : 0
                border.color: Colors.outline

                Row {
                    anchors.fill: parent
                    anchors.margins: 8
                    spacing: 8

                    Text {
                        anchors.verticalCenter: parent.verticalCenter
                        text: root.playerIcon(chooserRow.modelData)
                        color: Colors.overBackground
                        // Icons.font: a Phosphor glyph drawn with the UI font is tofu.
                        font.family: Icons.font
                        font.pixelSize: Styling.fontSize(3)
                    }

                    Text {
                        anchors.verticalCenter: parent.verticalCenter
                        textFormat: Text.PlainText
                        // The identity belongs HERE, where what is being told apart is the
                        // PLAYER, not in the card's title, where it would be a song title.
                        text: chooserRow.modelData.trackTitle || chooserRow.modelData.identity
                              || "Unknown player"
                        color: Colors.overBackground
                        font.family: Styling.defaultFont
                        font.pixelSize: root.labelSize
                        elide: Text.ElideRight
                        width: Math.min(implicitWidth, chooserRow.width - 16 - 26)
                    }
                }

                HoverHandler {
                    id: rowHover
                }

                TapHandler {
                    onTapped: {
                        MprisController.setActivePlayer(chooserRow.modelData);
                        root.choosing = false;
                    }
                }
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

    // The shell's own mapping (dashboard/widgets/FullPlayer.qml), kept local instead of
    // imported: the mod ships no shared components, and these are the same Phosphor glyphs.
    function playerIcon(p) {
        if (!p)
            return Icons.player;
        const dbusName = (p.dbusName || "").toLowerCase();
        const desktopEntry = (p.desktopEntry || "").toLowerCase();
        const identity = (p.identity || "").toLowerCase();

        if (dbusName.includes("spotify") || desktopEntry.includes("spotify") || identity.includes("spotify"))
            return Icons.spotify;
        if (dbusName.includes("chromium") || dbusName.includes("chrome")
                || desktopEntry.includes("chromium") || desktopEntry.includes("chrome"))
            return Icons.chromium;
        if (dbusName.includes("firefox") || desktopEntry.includes("firefox"))
            return Icons.firefox;
        if (dbusName.includes("telegram") || desktopEntry.includes("telegram") || identity.includes("telegram"))
            return Icons.telegram;
        return Icons.player;
    }
}