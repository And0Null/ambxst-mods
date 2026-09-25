pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import Quickshell
import qs.modules.services
import qs.modules.components
import qs.modules.theme
import qs.modules.widgets.lanshare

// Bar button for LAN Share (ControlsButton pattern).
// Left-click: card · right-click: receiver on/off.
Item {
    id: root

    required property var bar

    property bool vertical: bar.orientation === "vertical"
    property bool isHovered: false
    property bool layerEnabled: true
    property bool enableShadow: true

    property real radius: 0
    property real startRadius: radius
    property real endRadius: radius

    // Popup visibility state (tracks intent, not animation)
    property bool popupOpen: lanSharePopup.isOpen

    Layout.preferredWidth: 36
    Layout.preferredHeight: 36
    Layout.fillWidth: vertical
    Layout.fillHeight: !vertical

    StyledToolTip {
        show: root.isHovered && !root.popupOpen
        tooltipText: "LAN Share · " + LanShareService.statusMeta
    }

    HoverHandler {
        onHoveredChanged: root.isHovered = hovered
    }

    // Main button
    StyledRect {
        id: buttonBg
        variant: root.popupOpen ? "primary" : "bg"
        anchors.fill: parent
        enableShadow: root.enableShadow

        topLeftRadius: root.vertical ? root.startRadius : root.startRadius
        topRightRadius: root.vertical ? root.startRadius : root.endRadius
        bottomLeftRadius: root.vertical ? root.endRadius : root.startRadius
        bottomRightRadius: root.vertical ? root.endRadius : root.endRadius

        Rectangle {
            anchors.fill: parent
            color: Styling.srItem("overprimary")
            opacity: root.popupOpen ? 0 : (root.isHovered ? 0.25 : 0)
            radius: parent.radius ?? 0
        }

        Text {
            anchors.centerIn: parent
            text: Icons.globe
            font.family: Icons.font
            font.pixelSize: 18
            color: root.popupOpen ? buttonBg.item : ((LanShareService.receiverEnabled && LanShareService.backendReady) ? Styling.srItem("overprimary") : Colors.outline)
        }

        MouseArea {
            anchors.fill: parent
            hoverEnabled: false
            cursorShape: Qt.PointingHandCursor
            acceptedButtons: Qt.LeftButton | Qt.RightButton
            onClicked: mouse => {
                if (mouse.button === Qt.RightButton) {
                    LanShareService.toggleReceiver();
                    return;
                } else if (mouse.button === Qt.LeftButton) {
                    lanSharePopup.toggle();
                }
            }
        }
    }

    // LANShare card popup (anchored to the button, like Govee).
    // Discovery follows the popup: opening any card starts it, closing the
    // last one stops it.
    BarPopup {
        id: lanSharePopup
        anchorItem: buttonBg
        bar: root.bar
        popupPadding: 12

        contentWidth: 360
        contentHeight: 480

        LanShareCard {}

        onIsOpenChanged: {
            if (isOpen)
                LanShareService.viewOpened();
            else
                LanShareService.viewClosed();
        }

        Component.onDestruction: {
            if (isOpen)
                LanShareService.viewClosed();
        }
    }
}
