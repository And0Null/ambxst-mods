pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Effects
import qs.modules.theme
import qs.modules.services
// The mono font for the two time labels reads Config.theme.monoFont, and `Config` is the
// qs.config singleton: without this import both bindings threw `ReferenceError: Config is
// not defined` (measured live in the running shell's own qslog, twice per card) and the
// times silently fell back to the UI font. Styling only re-exports font SIZES, so the
// family has to come from here.
import qs.config

import Quickshell.Services.Mpris

// Desktop player card: what is on the MPRIS bus right now, in content families — two
// AMOUNTS of what you can DO with the player, never the same thing made smaller:
//   full     (280x400) the reference shape: artwork, title, artist, a seek bar with the
//                     elapsed and total times, and the transport
//   detailed (280x457) the same, plus the CONTROLS: shuffle, loop, a volume slider and
//                     the player identity with the switcher
//
// The difference between those two heights IS the two extra rows (24 + 17 + two 8px
// spacings = 57), not a bigger cover — see the arithmetic by `artSide` below.
//
// Everything comes from MprisController (qs.modules.services), the shell's own MPRIS
// singleton: it already owns the player list, the capability flags and the persisted
// choice, so this card never talks to D-Bus and nothing runs while nothing plays.
//
// The families are MODES of this one tree, never two drawings. `family === "detailed"`
// turns the two extra rows on; nothing else changes shape.
Item {
    id: root

    // How much to show. The widget layer sets this from the layout entry (or from the
    // group child) that renders this card.
    property string family: "full"

    // The extra rows exist only in `detailed`. One flag, read in three places, so the
    // family can never be half applied: the seek bar, the control row and the identity
    // row all hang off this same value.
    readonly property bool detailed: root.family === "detailed"

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

    // --- Progress, volume, and the modes they drive ---------------------------------------
    // A player with no length (an idle browser tab publishes `mpris:length: 0`) has nothing
    // to show a bar of, so the row does not exist at all rather than drawing an empty rail.
    readonly property bool hasTimeline: root.player && root.player.length > 0
    readonly property bool canSeekBar: root.hasTimeline && root.player.canSeek
    readonly property real progress: root.hasTimeline
        ? Math.min(1, Math.max(0, root.player.position / root.player.length)) : 0

    // While a drag is in flight the bar must show the finger, not the value ticking back
    // from the player — the two fight each other and the bar jitters. `seekPosition`
    // wins for the length of the drag, then the row is left alone.
    property real seekPosition: -1
    readonly property real shownProgress: root.seekPosition >= 0
        ? root.seekPosition / root.player.length : root.progress
    property bool seekDragging: false

    readonly property bool canSeekVolume: root.player && root.player.volumeSupported
    property real dragVolume: -1
    // MPRIS volume is 0..1 but a player may hand back more than 1 (its own "boost"), so
    // the slider is capped at 1 and the raw value never reaches the geometry.
    readonly property real shownVolume: root.dragVolume >= 0 ? root.dragVolume
        : (root.player ? Math.min(1, root.player.volume) : 0)

    // Loop is a THREE state cycle, not a toggle: off -> playlist -> track -> off, which is
    // the order the shell's own dashboard player uses (FullPlayer.qml), so the same tap
    // means the same thing in both places. Shuffle is a plain boolean and the two share
    // one button, exactly like there.
    readonly property bool modeSupported: MprisController.shuffleSupported
        || MprisController.loopSupported
    function cycleMode() {
        if (MprisController.hasShuffle) {
            MprisController.setShuffle(false);
            MprisController.setLoopState(MprisLoopState.Playlist);
        } else if (MprisController.loopState === MprisLoopState.Playlist) {
            MprisController.setLoopState(MprisLoopState.Track);
        } else if (MprisController.loopState === MprisLoopState.Track) {
            MprisController.setLoopState(MprisLoopState.None);
        } else {
            MprisController.setShuffle(true);
        }
    }
    function modeIcon() {
        if (MprisController.hasShuffle)
            return Icons.shuffle;
        if (MprisController.loopState === MprisLoopState.Track)
            return Icons.repeatOnce;
        if (MprisController.loopState === MprisLoopState.Playlist)
            return Icons.repeat;
        return Icons.shuffle;
    }
    // The mode control is lit only when it is actually doing something: a muted loop with
    // no shuffle is the same glyph as a dead one, and the difference is the whole point.
    readonly property bool modeActive: MprisController.hasShuffle
        || MprisController.loopState !== MprisLoopState.None

    // "3:24", "1:02:11" past an hour, "0:07" under ten. Built here rather than with a
    // formatter so the card owns its own seconds rounding.
    function timeText(seconds) {
        var s = Math.max(0, Math.floor(seconds || 0));
        var h = Math.floor(s / 3600);
        var m = Math.floor((s % 3600) / 60);
        var sec = s % 60;
        var mm = (h > 0 ? m : m < 10 ? "0" + m : "" + m);
        return (h > 0 ? h + ":" : "") + mm + ":" + (sec < 10 ? "0" + sec : sec);
    }

    // A player going away while the list is open would otherwise leave the card on the list
    // the next time it comes back.
    onCardHiddenChanged: if (root.cardHidden) root.choosing = false

    // The artwork is SQUARE and as wide as the widget: the reference's cover is the card's
    // width, not a centred square inside a wider card, and at 248 of widget it is also the
    // only size that leaves room for everything below in a 400-tall card.
    //
    // full    card 280x400 -> widget 248x368: 248 (art) + 8 + 20 (title) + 8 + 18 (artist)
    //   + 8 + 28 (seek row: a 6px rail, 2px gap, 20px times line) + 8 + 17 (transport)
    //   = 363, which is the whole 368. The seek row's numbers are its real ones: the times
    //   ride INSIDE that row, they are not a row of their own.
    // detailed card 280x457 -> widget 248x425: the same 363 plus 8 + 24 (mode + volume)
    //   plus 8 + 17 (identity) = 420 of 425. The artwork keeps its 248 in both, and the
    //   difference in height IS the two extra rows — which is what the comment above the
    //   families promises. It used to declare 280x500, i.e. 468 of widget for 420 of
    //   content: 48px of empty card below the identity row, on a 500-tall card (measured
    //   live, and the family-size-preview photographs it). A family is an AMOUNT of
    //   information and the room that amount needs; a taller box with the same rows in it
    //   is the taller box with the same rows in it. tests/media-family-fit.py holds both
    //   numbers: the caret's ink on the artist line, and this card's slack at the bottom.
    //
    // Every number above is WIDGET space except the two card sizes: a widget measures the
    // card minus WidgetFrame's 16px margin per side, so 400 and 457 here are card numbers
    // and 368 and 425 are what the card hands this tree. Those leaf heights come from font
    // metrics (a Text's own height), so they are the same with or without a laid-out
    // window — which matters, because a bare ShellRoot never lays this tree out and every
    // Row in it then reports height 0.
    readonly property int artSide: width

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
                id: artistName
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

            // The caret is centred on the artist line by GIVING IT THE LINE'S BOX, not by
            // nudging it: a Row gives each child the Row's height top-aligned, and the
            // caret's own glyph box came out 2px shorter than the text's, so its ink sat
            // -1px off on the box and -2.5px off in the pixels against the line's centre.
            // The identity row's caret below uses `anchors.verticalCenter` and is exact;
            // here the box is matched as well, because this line is ELIDED (its width can
            // be clamped to the cover) and a fixed-height elided line would drift from
            // whatever the Row resolved to.
            Text {
                height: artistName.height
                visible: root.canChoose
                text: Icons.caretDown
                color: artistHover.hovered ? Colors.primary : root.alpha(Colors.overBackground, 0.7)
                // Icons.font: a Phosphor glyph drawn with the UI font is tofu.
                font.family: Icons.font
                font.pixelSize: root.labelSize
                verticalAlignment: Text.AlignVCenter

                HoverHandler {
                    id: artistHover
                }
            }

            TapHandler {
                // In `detailed` the identity row below is the switcher, so only one of
                // the two lines opens the list: two taps in different places doing the
                // same thing is a menu with two doors.
                enabled: root.canChoose && !root.detailed
                onTapped: root.choosing = !root.choosing
            }

            // The ONE place on this card where the pointer becomes a hand: the line that
            // really does open something. Everywhere else stays an arrow, including the
            // controls you drag — a drag is not a click.
            HoverHandler {
                enabled: root.canChoose && !root.detailed
                cursorShape: Qt.PointingHandCursor
            }
        }

        // The seek bar with the elapsed and total times beside it — the reference's row.
        // The row does not exist without a length to divide by, so a player that
        // publishes none (an idle browser tab, `mpris:length: 0`) simply has no bar.
        Column {
            id: seekRow
            visible: root.hasTimeline
            width: parent.width
            spacing: 2

            // The rail. Drawn here rather than with the shell's own PositionSlider:
            // that control is a Layout item sized by its parent and imports
            // Quickshell's own components, while this card is a plain Item in a mod
            // with no layout parent — and it needs the same `wavy` line the
            // reference shows, which is StyledSlider's own behaviour, not a file.
            Item {
                id: rail
                width: parent.width
                height: 6

                Rectangle {
                    anchors.verticalCenter: parent.verticalCenter
                    width: parent.width
                    height: 3
                    radius: 1.5
                    color: root.alpha(Colors.overBackground, 0.18)
                }

                Rectangle {
                    anchors.verticalCenter: parent.verticalCenter
                    width: parent.width * root.shownProgress
                    height: 3
                    radius: 1.5
                    color: root.canSeekBar ? Colors.primary
                        : root.alpha(Colors.overBackground, 0.4)
                }

                // The handle, only while the bar can be dragged: a dot on a read-only
                // bar would promise a seek that cannot happen.
                Rectangle {
                    visible: root.canSeekBar
                    anchors.verticalCenter: parent.verticalCenter
                    x: Math.max(0, Math.min(parent.width - width,
                        parent.width * root.shownProgress - width / 2))
                    width: 10
                    height: 10
                    radius: 5
                    color: Colors.primary
                    border.width: 2
                    border.color: root.alpha(Colors.overBackground, 0.35)
                }

            // The hit area is a MouseArea, not a DragHandler with `target: null`, and the
            // difference is the whole feature. A targetless DragHandler does NOT take the
            // pointer: the drag only continues while the cursor stays over the item, and
            // its translation is an INCREMENTAL delta, so the handle trails the finger and
            // has to be dragged off the card to move at all (measured on the live card).
            // A MouseArea grabs the pointer for the whole gesture and reports an ABSOLUTE
            // position, which is the 1:1 mapping a slider is supposed to have: press
            // anywhere on the rail, the handle goes there, and it follows the cursor exactly.
            // 24px tall on purpose: the rail is 3px, and a 3px target on a desktop card is
            // a target you miss. The WRITE is on release, so crossing the card does not
            // fire a seek per pixel.
            //
            // The margins are -9 on a 248-wide rail, so the area is 298 wide: 9px of slack
            // at each end. `mouse.x` is relative to the AREA, and the rail is INSIDE it by
            // 9px, so a press at the left edge of the area is 9px left of the rail and the
            // naive `(px - area.x) / area.width` map returned 0.0302 there instead of 0
            // (measured: the offsets had to be divided out by hand). Clamping to the rail's
            // own span keeps the ends honest: the 9px of slack eats the press, it does not
            // move the mapping.
            MouseArea {
                id: seekArea
                anchors.fill: parent
                anchors.margins: -9
                enabled: root.canSeekBar
                // No hand cursor over a control that is dragged, not clicked. The
                // default arrow is the honest one here; see the card's own comment.
                cursorShape: Qt.ArrowCursor

                function ratioAt(px) {
                    if (!root.player || root.player.length <= 0)
                        return 0;
                    // 9px of slack at each end, out of the mapping: the rail's own span.
                    var slack = 9;
                    var railW = Math.max(1, seekArea.width - slack * 2);
                    return Math.min(1, Math.max(0, (px - slack) / railW));
                }

                onPressed: function (mouse) {
                    root.seekDragging = true;
                    root.seekPosition = seekArea.ratioAt(mouse.x) * root.player.length;
                }
                onPositionChanged: function (mouse) {
                    if (!pressed || !root.player)
                        return;
                    root.seekPosition = seekArea.ratioAt(mouse.x) * root.player.length;
                }
                onReleased: function () {
                    if (root.player && root.canSeekBar && root.seekPosition >= 0)
                        root.player.position = root.seekPosition;
                    root.seekPosition = -1;
                    root.seekDragging = false;
                }
                onExited: {
                    // A gesture cancelled by the compositor never fires onReleased, and a
                    // stuck `seekDragging` would freeze the bar on a phantom position.
                    root.seekPosition = -1;
                    root.seekDragging = false;
                }
            }
            }

            Row {
                width: parent.width

                Text {
                    textFormat: Text.PlainText
                    text: root.timeText(root.hasTimeline
                        ? (root.seekPosition >= 0 ? root.seekPosition : root.player.position) : 0)
                    color: root.alpha(Colors.overBackground, 0.55)
                    font.family: Config.theme.monoFont
                    font.pixelSize: root.labelSize
                }

                Item {
                    width: parent.width - 46 - 46
                    height: 1
                }

                Text {
                    textFormat: Text.PlainText
                    text: root.timeText(root.hasTimeline ? root.player.length : 0)
                    color: root.alpha(Colors.overBackground, 0.55)
                    font.family: Config.theme.monoFont
                    font.pixelSize: root.labelSize
                }
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

        // --- The `detailed` rows: what the card can DO, not more of what it knows ---------
        // The full family already draws every row of text the metadata has. Growing it
        // with album, genre and identity would be the same information in a taller box —
        // which is exactly what a family must never be. So `detailed` adds CONTROL:
        // the mode cycle, the volume, and the switcher in a row of its own.

        // Shuffle and loop share ONE button that cycles, because that is how the shell's
        // own dashboard player does it (FullPlayer.qml): a player either shuffles or
        // repeats, and a second pair of buttons would mostly sit disabled.
        Row {
            visible: root.detailed && root.modeSupported
            width: parent.width
            spacing: 10

            // The mode button is a bare `Text` in this Row, and a Row hands every child its
            // FULL height TOP-aligned: the shuffle sat 3.5px above the volume icon and the
            // volume track beside it (measured off the capture, glyph centre 23.0 against
            // 26.5). The volume half centres its own children with
            // `anchors.verticalCenter`, so the row had two different baselines in it. This
            // Row is `height: 24` by its tallest child (the volume Item), and centring the
            // button on it puts both halves on one line — the same treatment the identity
            // row's icons already have.
            TransportButton {
                id: modeButton
                anchors.verticalCenter: parent.verticalCenter
                icon: root.modeIcon()
                enabledControl: true
                iconColor: root.modeActive ? Colors.primary
                    : root.alpha(Colors.overBackground, 0.8)
                onActivated: root.cycleMode()
            }

            // The volume slider. `MprisController.activePlayer.volume = v` is legal QML
            // (the property has a write accessor in the Mpris type), so no shell patch
            // is needed for a real volume control.
            Item {
                width: parent.width - 30
                height: 24

                Text {
                    id: volIcon
                    anchors.left: parent.left
                    anchors.verticalCenter: parent.verticalCenter
                    text: root.shownVolume <= 0.001 ? Icons.speakerNone
                        : root.shownVolume < 0.5 ? Icons.speakerLow : Icons.speakerHigh
                    color: root.canSeekVolume ? root.alpha(Colors.overBackground, 0.7)
                        : root.alpha(Colors.overBackground, 0.3)
                    // Icons.font: a Phosphor glyph drawn with the UI font is tofu.
                    font.family: Icons.font
                    font.pixelSize: root.labelSize
                }

                Item {
                    id: volTrack
                    anchors.left: volIcon.right
                    anchors.leftMargin: 8
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    height: 4

                    Rectangle {
                        width: parent.width
                        height: parent.height
                        radius: parent.height / 2
                        color: root.alpha(Colors.overBackground, 0.18)
                    }

                    Rectangle {
                        width: parent.width * root.shownVolume
                        height: parent.height
                        radius: parent.height / 2
                        color: root.canSeekVolume ? Colors.primary
                            : root.alpha(Colors.overBackground, 0.35)
                    }
                }

                // Same MouseArea reason as the seek bar: a targetless DragHandler does
                // not take the pointer, so the volume knob would trail the cursor and
                // stop tracking outside the item. 24px tall on a 4px rail, and the
                // mapping is over the TRACK's span, not the area's: the area is 9px
                // wider at each end, and folding that into the divisor made a press on
                // the left edge read as 0.03 instead of 0.
                MouseArea {
                    id: volArea
                    anchors.fill: parent
                    enabled: root.canSeekVolume
                    cursorShape: Qt.ArrowCursor

                    function ratioAt(px) {
                        var railW = Math.max(1, volArea.width - 18);
                        return Math.min(1, Math.max(0, (px - 9) / railW));
                    }

                    onPressed: function (mouse) {
                        root.dragVolume = volArea.ratioAt(mouse.x);
                    }
                    onPositionChanged: function (mouse) {
                        if (pressed)
                            root.dragVolume = volArea.ratioAt(mouse.x);
                    }
                    onReleased: {
                        if (root.player && root.canSeekVolume && root.dragVolume >= 0)
                            root.player.volume = root.dragVolume;
                        root.dragVolume = -1;
                    }
                    onExited: root.dragVolume = -1;
                }
            }
        }

        // The player's own name, with the switcher — the one row where naming the PLAYER
        // is the point, so the identity belongs here and not in the card's title.
        Row {
            visible: root.detailed
            width: parent.width
            spacing: 6

            Text {
                anchors.verticalCenter: parent.verticalCenter
                text: root.playerIcon(root.player)
                color: root.alpha(Colors.overBackground, 0.6)
                // Icons.font: a Phosphor glyph drawn with the UI font is tofu.
                font.family: Icons.font
                font.pixelSize: root.labelSize
            }

            Text {
                anchors.verticalCenter: parent.verticalCenter
                textFormat: Text.PlainText
                text: root.player ? (root.player.identity || "Unknown player") : ""
                color: root.alpha(Colors.overBackground, 0.6)
                font.family: Styling.defaultFont
                font.pixelSize: root.labelSize
                elide: Text.ElideRight
                width: Math.min(implicitWidth, parent.width - 30 - (root.canChoose ? 18 : 0))
            }

            Text {
                visible: root.canChoose
                anchors.verticalCenter: parent.verticalCenter
                text: Icons.caretDown
                color: root.alpha(Colors.overBackground, 0.6)
                // Icons.font: a Phosphor glyph drawn with the UI font is tofu.
                font.family: Icons.font
                font.pixelSize: root.labelSize
            }

            // In the full family the artist line is the switcher; in the detailed one this
            // row is, and the artist line's own handler stands down so a single tap opens
            // the list from whichever line the family put it on.
            TapHandler {
                enabled: root.canChoose
                onTapped: root.choosing = !root.choosing
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
        // The mode control passes its own colour: it has to read as LIT when it is
        // actually shuffling or looping, and the default cannot know that.
        property color iconColor: hover.hovered ? Colors.primary
            : root.alpha(Colors.overBackground, 0.8)
        signal activated()

        visible: button.enabledControl
        text: button.icon
        // `hover` is an id in this component's scope, not a property of the button:
        // `button.hover` is undefined and throws at binding time.
        color: button.iconColor
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

    // --- What the pointer looks like over each thing ---------------------------------------
    // A desktop is not a web page: a pointer that turns into a HAND over every card says
    // "everything here is a link", which is false, and it covers the whole rectangle of
    // every widget on the screen (reported live). So the rule this card follows is narrow:
    // the arrow everywhere, and the hand ONLY on the two affordances that really do open
    // something — the player's switcher, and nothing else. Dragging controls (the seek
    // bar, the volume) keep the arrow even while dragging, because a drag is not a click.
    readonly property bool switcherOpen: root.canChoose && !root.choosing

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