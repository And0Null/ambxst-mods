pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import qs.config
import qs.modules.theme
import qs.modules.services
import qs.modules.components

// Management card for system updates, opened by the bar button.
//
// Every control uses Ambxst's own button recipe (the inner ActionButton in
// modules/widgets/dashboard/controls/ModsPanel.qml): the label colour is always
// derived from the surface underneath it, so contrast cannot drift when the
// theme changes. Filled ("primary") means engaged/active.
//
// BarPopup owns anchoring, focus grabbing, outside-click closure and styling.
// The caller supplies anchorItem and bar, then calls open() or toggle().
BarPopup {
    id: root

    contentWidth: 360
    contentHeight: cardColumn.implicitHeight + popupPadding * 2
    popupPadding: 16

    onIsOpenChanged: {
        if (isOpen)
            Qt.callLater(() => cardPanel.forceActiveFocus());
    }

    // Copied from Ambxst's ModsPanel ActionButton, with card-sized padding.
    // `primary` = filled/engaged; the text colour reads the surface it sits on.
    component ActionButton: Button {
        id: action

        property bool primary: false
        property bool destructive: false

        implicitHeight: 28
        leftPadding: 10
        rightPadding: 10
        topPadding: 0
        bottomPadding: 0

        opacity: enabled ? 1 : 0.45

        readonly property bool engaged: hovered || down || activeFocus
        readonly property string surface: action.primary
            ? (action.engaged ? "primaryfocus" : "primary")
            : (action.engaged ? (action.destructive ? "error" : "secondary") : "focus")

        background: StyledRect {
            variant: action.surface
            radius: Styling.radius(-4)
            enableShadow: false
        }

        contentItem: Text {
            text: action.text
            font.family: Config.theme.font
            font.pixelSize: Styling.fontSize(-2)
            font.weight: action.primary ? Font.DemiBold : Font.Medium
            color: action.primary || action.engaged ? Styling.srItem(action.surface)
                : action.destructive ? Colors.error
                : Colors.overBackground
            horizontalAlignment: Text.AlignHCenter
            verticalAlignment: Text.AlignVCenter
            elide: Text.ElideRight
        }
    }

    FocusScope {
        id: cardPanel
        anchors.fill: parent

        Keys.priority: Keys.BeforeItem
        Keys.onEscapePressed: event => {
            root.close();
            event.accepted = true;
        }

        ColumnLayout {
            id: cardColumn
            anchors.fill: parent
            spacing: 8

            Text {
                text: "System updates"
                font.family: Config.theme.font
                font.pixelSize: Styling.fontSize(2)
                font.weight: Font.DemiBold
                color: Colors.overBackground
            }

            // Per-source rows: state, re-scan, on/off and update.
            Repeater {
                model: [
                    { key: "pacman", label: "pacman", state: SystemUpdatesService.sourceState("pacman"), count: SystemUpdatesService.sourceCount("pacman"), enabled: SystemUpdatesService.scanPacman },
                    { key: "aur", label: "AUR", state: SystemUpdatesService.sourceState("aur"), count: SystemUpdatesService.sourceCount("aur"), enabled: SystemUpdatesService.scanAur },
                    { key: "flatpak", label: "flatpak", state: SystemUpdatesService.sourceState("flatpak"), count: SystemUpdatesService.sourceCount("flatpak"), enabled: SystemUpdatesService.scanFlatpak }
                ]

                delegate: RowLayout {
                    id: sourceRow

                    required property var modelData
                    readonly property int count: modelData.count
                    readonly property string state: modelData.state
                    readonly property bool sourceOn: modelData.enabled
                    readonly property bool hasUpdates: sourceRow.count > 0 && sourceRow.state === "count"
                    readonly property string toggleKey: {
                        if (modelData.key === "pacman")
                            return "scanPacman";
                        if (modelData.key === "aur")
                            return "scanAur";
                        return "scanFlatpak";
                    }
                    readonly property string command: {
                        if (modelData.key === "pacman")
                            return root.pacmanCommand;
                        if (modelData.key === "aur")
                            return root.aurCommand;
                        return root.flatpakCommand;
                    }

                    Layout.fillWidth: true
                    spacing: 6

                    Text {
                        text: sourceRow.modelData.label
                        font.family: Config.theme.font
                        font.pixelSize: Styling.fontSize(-1)
                        color: Colors.overBackground
                        Layout.preferredWidth: 56
                    }

                    // off / error / unknown / count / up — a failed or
                    // never-scanned source never reads as up to date.
                    Text {
                        text: {
                            if (sourceRow.state === "off")
                                return "off";
                            if (sourceRow.state === "error")
                                return "!";
                            if (sourceRow.state === "unknown")
                                return "–";
                            if (sourceRow.state === "count")
                                return String(sourceRow.count);
                            return "✓";
                        }
                        font.family: Config.theme.font
                        font.pixelSize: Styling.fontSize(-1)
                        font.weight: sourceRow.state === "count" ? Font.DemiBold : Font.Normal
                        color: {
                            if (sourceRow.state === "error")
                                return Colors.error;
                            if (sourceRow.state === "up")
                                return Colors.green;
                            if (sourceRow.state === "count")
                                return Colors.overBackground;
                            return Colors.outline;
                        }
                        Layout.preferredWidth: 24
                    }

                    // Re-scan just this source.
                    ActionButton {
                        text: "↻"
                        enabled: sourceRow.sourceOn && !SystemUpdatesService.loading
                        onClicked: {
                            if (sourceRow.modelData.key === "pacman")
                                SystemUpdatesService.checkPacman();
                            else if (sourceRow.modelData.key === "aur")
                                SystemUpdatesService.checkAur();
                            else
                                SystemUpdatesService.checkFlatpak();
                        }
                    }

                    Item { Layout.fillWidth: true }

                    // Include this source in the automatic scans.
                    ActionButton {
                        text: sourceRow.sourceOn ? "On" : "Off"
                        primary: sourceRow.sourceOn
                        onClicked: SystemUpdatesService.setSetting(sourceRow.toggleKey, !sourceRow.sourceOn)
                    }

                    // Update this source alone (needs something pending).
                    ActionButton {
                        text: "Update"
                        primary: sourceRow.hasUpdates
                        enabled: sourceRow.hasUpdates && !SystemUpdatesService.updateRunning
                        onClicked: SystemUpdatesService.runUpdate(sourceRow.command)
                    }
                }
            }

            // Global actions, full width so they read as the primary action row.
            RowLayout {
                Layout.fillWidth: true
                Layout.topMargin: 2
                spacing: 6

                ActionButton {
                    Layout.fillWidth: true
                    text: SystemUpdatesService.loading ? "Scanning…" : "Scan all"
                    enabled: !SystemUpdatesService.loading
                    onClicked: SystemUpdatesService.check()
                }

                ActionButton {
                    Layout.fillWidth: true
                    text: SystemUpdatesService.updateRunning ? "Updating…" : "Update all"
                    primary: SystemUpdatesService.total > 0 && !SystemUpdatesService.updateRunning
                    enabled: SystemUpdatesService.total > 0 && !SystemUpdatesService.updateRunning
                    onClicked: SystemUpdatesService.updateNow()
                }
            }

            // Preferences. Kept in the card, but rendered exactly like Ambxst's
            // own settings rows: label on the left, an On/Off ActionButton right.
            RowLayout {
                Layout.fillWidth: true
                Layout.topMargin: 2
                spacing: 8

                Text {
                    text: "Show in bar when up to date"
                    font.family: Config.theme.font
                    font.pixelSize: Styling.fontSize(-1)
                    color: Colors.overBackground
                    Layout.fillWidth: true
                }

                ActionButton {
                    text: SystemUpdatesService.showWhenUpToDate ? "On" : "Off"
                    primary: SystemUpdatesService.showWhenUpToDate
                    onClicked: SystemUpdatesService.setSetting("showWhenUpToDate", !SystemUpdatesService.showWhenUpToDate)
                }
            }

            Text {
                text: "Scans run every " + SystemUpdatesService.refreshMinutes + " min (change it in Ambxst Settings → Mods)."
                font.family: Config.theme.font
                font.pixelSize: Styling.fontSize(-2)
                color: Colors.outline
                wrapMode: Text.Wrap
                Layout.fillWidth: true
            }
        }
    }

    // Per-source update command. The service tracks the terminal as a Process,
    // so closing it triggers the rescan. No shell keep-alive.
    // The helper comes from the service's probe (paru preferred); -a limits the
    // upgrade to AUR targets, and there is no yay fallback after a paru failure
    // — a mixed run would double-install.
    readonly property string pacmanCommand: "sudo pacman -Syu"
    readonly property string aurCommand: SystemUpdatesService.aurHelper === "yay" ? "yay -Sua" : "paru -Sua"
    readonly property string flatpakCommand: "flatpak update"
}
