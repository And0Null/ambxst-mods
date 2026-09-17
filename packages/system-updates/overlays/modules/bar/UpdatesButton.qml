pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import Quickshell
import qs.modules.services
import qs.modules.components
import qs.modules.theme

// Bar button: pending system updates. Invisible when there is nothing to
// update (total === 0), so it adds zero clutter. Left-click opens a
// terminal running `paru -Syu`; right-click forces a full re-check.
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

    // Set once the mod's externalOnly setting is read; hide on laptop
    // internal panels (screen name starts with "eDP") when enabled.
    property bool internalScreen: root.bar?.screen?.name?.startsWith("eDP") ?? false

    visible: {
        if (SystemUpdatesService.externalOnly && root.internalScreen)
            return false;
        if (SystemUpdatesService.showWhenUpToDate)
            return true;
        return SystemUpdatesService.total > 0;
    }
    Layout.preferredWidth: 36
    Layout.preferredHeight: 36
    Layout.fillWidth: vertical
    Layout.fillHeight: !vertical

    UpdatesCard {
        id: updatesCard
        anchorItem: root
        bar: root.bar
    }

    StyledToolTip {
        show: root.isHovered
        tooltipText: "Updates · " + SystemUpdatesService.pacman + " pacman"
            + (SystemUpdatesService.aur > 0 ? (", " + SystemUpdatesService.aur + " AUR") : "")
            + (SystemUpdatesService.flatpak > 0 ? (", " + SystemUpdatesService.flatpak + " flatpak") : "")
    }

    HoverHandler {
        onHoveredChanged: root.isHovered = hovered
    }

    StyledRect {
        id: buttonBg
        variant: "bg"
        anchors.fill: parent
        enableShadow: root.enableShadow

        topLeftRadius: root.startRadius
        topRightRadius: root.endRadius
        bottomLeftRadius: root.startRadius
        bottomRightRadius: root.endRadius

        Rectangle {
            anchors.fill: parent
            color: Styling.srItem("overprimary")
            opacity: root.isHovered ? 0.25 : 0
            radius: parent.radius ?? 0
        }

        // Icon area: when there are updates, the package glyph + count badge;
        // when everything is up to date and "show when up to date" is on,
        // a green check instead.
        Text {
            anchors.horizontalCenter: parent.horizontalCenter
            anchors.bottom: parent.verticalCenter
            anchors.bottomMargin: 1
            visible: SystemUpdatesService.total > 0
            // Nerd-font package glyph (Icons has no fitting glyph).
            text: "󰏖" // nf-md-package
            font.family: "CaskaydiaCove Nerd Font"
            font.pixelSize: 15
            color: Styling.srItem("overprimary")
        }

        Text {
            anchors.centerIn: parent
            visible: SystemUpdatesService.total === 0 && SystemUpdatesService.showWhenUpToDate
            text: "󰄬" // nf-md-check
            font.family: "CaskaydiaCove Nerd Font"
            font.pixelSize: 16
            color: "#4caf50"
        }

        Text {
            anchors.horizontalCenter: parent.horizontalCenter
            anchors.top: parent.verticalCenter
            anchors.topMargin: 1
            // Count always shown when there is anything to update, including 1.
            visible: SystemUpdatesService.total > 0
            text: SystemUpdatesService.total
            font.pixelSize: Styling.fontSize(-4)
            color: Styling.srItem("overprimary")
        }

        MouseArea {
            anchors.fill: parent
            hoverEnabled: false
            cursorShape: Qt.PointingHandCursor
            acceptedButtons: Qt.LeftButton | Qt.RightButton
            onClicked: mouse => {
                if (mouse.button === Qt.RightButton)
                    SystemUpdatesService.check();
                else
                    updatesCard.toggle();
            }
        }
    }
}
