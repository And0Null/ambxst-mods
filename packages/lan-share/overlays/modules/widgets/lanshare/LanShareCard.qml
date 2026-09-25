import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import qs.modules.services
import qs.modules.components
import qs.modules.theme

// LANShare presence card (inside BarPopup): hero + receiver toggle + peer list
// + rescan + file/clipboard send + incoming accept/decline. Outgoing file
// send (v1.1) goes through the service-owned zenity picker
// (LanShareService.selectFilesTo); the card owns no picker Process.
// No PIN, no updater UI.
ColumnLayout {
    id: root

    anchors.fill: parent
    spacing: 10

    // Soft body text only for this card (theme globals untouched):
    // overSurfaceVariant in body, overSurface in titles.
    readonly property color softFg: Colors.overSurfaceVariant
    readonly property color strongFg: Colors.overSurface

    component LanShareAction: Button {
        id: actionBtn

        property string label: ""
        property bool primary: false

        text: ""
        Layout.fillWidth: true
        Layout.preferredHeight: 34

        scale: pressed ? 0.96 : 1.0

        background: StyledRect {
            variant: actionBtn.primary ? "primary" : "bg"
            radius: Styling.radius(8)

            Rectangle {
                anchors.fill: parent
                radius: parent.radius ?? 0
                color: Styling.srItem("overprimary")
                opacity: actionBtn.pressed ? 0.45 : (actionBtn.hovered ? 0.22 : 0)
            }
        }

        contentItem: Text {
            text: actionBtn.label
            color: actionBtn.primary ? Colors.background : Colors.overSurfaceVariant
            font.pixelSize: 13
            horizontalAlignment: Text.AlignHCenter
            verticalAlignment: Text.AlignVCenter
            elide: Text.ElideRight
        }
    }

    Flickable {
        Layout.fillWidth: true
        Layout.fillHeight: true
        contentWidth: width
        contentHeight: contentColumn.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds

        ColumnLayout {
            id: contentColumn
            width: parent.width
            spacing: 10

            // Hero
            RowLayout {
                Layout.fillWidth: true
                spacing: 10

                Text {
                    text: Icons.globe
                    font.family: Icons.font
                    font.pixelSize: 30
                    color: (LanShareService.receiverEnabled && LanShareService.backendReady) ? Styling.srItem("overprimary") : Colors.overSurfaceVariant
                    Layout.alignment: Qt.AlignVCenter
                }

                Column {
                    Layout.fillWidth: true
                    spacing: 2

                    Text {
                        text: "LAN Share"
                        color: root.strongFg
                        font.pixelSize: 16
                        font.bold: true
                    }

                    Text {
                        text: LanShareService.statusMeta
                        color: root.softFg
                        font.pixelSize: 12
                    }
                }

                LanShareAction {
                    label: LanShareService.receiverEnabled ? "ON" : "OFF"
                    primary: LanShareService.receiverEnabled
                    Layout.fillWidth: false
                    Layout.preferredWidth: 64
                    onClicked: LanShareService.toggleReceiver()
                }
            }

            // Error line
            Text {
                visible: LanShareService.errorText !== ""
                Layout.fillWidth: true
                text: LanShareService.errorText
                color: root.softFg
                font.pixelSize: 11
                wrapMode: Text.WordWrap
            }

            // Devices
            ColumnLayout {
                visible: LanShareService.viewState === "lanshare"
                Layout.fillWidth: true
                spacing: 6

                Text {
                    text: "DEVICES"
                    color: root.strongFg
                    font.pixelSize: 12
                    font.bold: true
                }

                Text {
                    visible: LanShareService.peers.length === 0
                    Layout.fillWidth: true
                    text: !LanShareService.receiverEnabled
                        ? "LAN Share is turned off"
                        : (!LanShareService.backendReady ? LanShareService.statusText : (LanShareService.scanPending ? LanShareService.statusText : (LanShareService.discoveryActive ? "Finding devices…" : "No devices in range")))
                    color: root.softFg
                    font.pixelSize: 13
                    wrapMode: Text.WordWrap
                    topPadding: 12
                    bottomPadding: 12
                }

                Repeater {
                    model: LanShareService.peers

                    delegate: MouseArea {
                        required property var modelData
                        required property int index

                        Layout.fillWidth: true
                        Layout.preferredHeight: 40
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: LanShareService.choosePeer(index)

                        StyledRect {
                            anchors.fill: parent
                            variant: "common"
                            radius: Styling.radius(8)

                            RowLayout {
                                anchors.fill: parent
                                anchors.leftMargin: 12
                                anchors.rightMargin: 12
                                spacing: 8

                                Text {
                                    Layout.fillWidth: true
                                    text: modelData.alias
                                    color: root.strongFg
                                    font.pixelSize: 13
                                    elide: Text.ElideRight
                                }

                                Text {
                                    text: Icons.paperPlane
                                    font.family: Icons.font
                                    font.pixelSize: 15
                                    color: parent.parent.containsMouse ? Styling.srItem("overprimary") : root.softFg
                                }
                            }
                        }
                    }
                }

                LanShareAction {
                    visible: LanShareService.receiverEnabled && LanShareService.backendReady
                    label: LanShareService.scanPending ? "Scanning…" : "Rescan"
                    onClicked: LanShareService.rescan()
                }
            }

            // Send target
            ColumnLayout {
                visible: LanShareService.viewState === "target" && LanShareService.selectedPeer
                Layout.fillWidth: true
                spacing: 6

                Text {
                    text: "SEND"
                    color: root.strongFg
                    font.pixelSize: 12
                    font.bold: true
                }

                Text {
                    Layout.fillWidth: true
                    text: "To " + (LanShareService.selectedPeer ? LanShareService.selectedPeer.alias : "")
                    color: root.softFg
                    font.pixelSize: 13
                    elide: Text.ElideRight
                }

                LanShareAction {
                    label: "Send files"
                    primary: true
                    onClicked: LanShareService.selectFilesTo()
                }

                LanShareAction {
                    label: "Send clipboard"
                    primary: true
                    onClicked: LanShareService.sendTextTo(LanShareService.selectedPeer ? LanShareService.selectedPeer.fingerprint : "")
                }

                LanShareAction {
                    label: "Back"
                    onClicked: LanShareService.clearTarget()
                }
            }

            // Incoming prompt
            ColumnLayout {
                visible: LanShareService.viewState === "incoming" && LanShareService.incoming
                Layout.fillWidth: true
                spacing: 8

                Text {
                    Layout.fillWidth: true
                    text: LanShareService.incoming ? LanShareService.incoming.sender + " wants to send" : ""
                    color: root.strongFg
                    font.pixelSize: 15
                    font.bold: true
                    wrapMode: Text.WordWrap
                }

                Text {
                    Layout.fillWidth: true
                    text: LanShareService.incoming ? LanShareService.incomingSummary(LanShareService.incoming.files) : ""
                    color: root.softFg
                    font.pixelSize: 12
                    elide: Text.ElideRight
                }

                Text {
                    visible: LanShareService.incomingQueue.length > 1
                    Layout.fillWidth: true
                    text: (LanShareService.incomingQueue.length - 1) + (LanShareService.incomingQueue.length === 2 ? " more request" : " more requests")
                    color: root.softFg
                    font.pixelSize: 12
                }

                RowLayout {
                    Layout.fillWidth: true
                    spacing: 8

                    LanShareAction {
                        label: "Decline"
                        Layout.fillWidth: true
                        onClicked: LanShareService.declineIncoming()
                    }

                    LanShareAction {
                        label: "Accept"
                        primary: true
                        Layout.fillWidth: true
                        onClicked: LanShareService.acceptIncoming()
                    }
                }
            }

            // Transfer progress
            ColumnLayout {
                visible: LanShareService.viewState === "sending" || LanShareService.viewState === "receiving"
                Layout.fillWidth: true
                spacing: 8

                Text {
                    text: LanShareService.viewState === "sending" ? "SENDING" : "RECEIVING"
                    color: root.strongFg
                    font.pixelSize: 12
                    font.bold: true
                }

                Text {
                    Layout.fillWidth: true
                    text: LanShareService.transferName
                    color: root.strongFg
                    font.pixelSize: 14
                    font.bold: true
                    elide: Text.ElideMiddle
                }

                Rectangle {
                    Layout.fillWidth: true
                    Layout.preferredHeight: 4
                    radius: height / 2
                    color: Colors.overSurfaceVariant

                    Rectangle {
                        width: parent.width * Math.max(0, Math.min(1, LanShareService.progress))
                        height: parent.height
                        radius: height / 2
                        color: Styling.srItem("overprimary")
                    }
                }

                Text {
                    text: Math.round(LanShareService.progress * 100) + "% · " + (LanShareService.viewState === "sending" ? "to " : "from ") + LanShareService.transferPeer
                    color: root.softFg
                    font.pixelSize: 12
                }

                LanShareAction {
                    visible: LanShareService.viewState === "sending"
                    label: "Cancel"
                    onClicked: LanShareService.cancelOutgoing()
                }
            }

            // Received text
            ColumnLayout {
                visible: LanShareService.viewState === "text"
                Layout.fillWidth: true
                spacing: 8

                Text {
                    text: "RECEIVED TEXT"
                    color: root.strongFg
                    font.pixelSize: 12
                    font.bold: true
                }

                Text {
                    Layout.fillWidth: true
                    text: LanShareService.incomingText
                    color: root.strongFg
                    font.pixelSize: 13
                    wrapMode: Text.WordWrap
                    maximumLineCount: 6
                    elide: Text.ElideRight
                }

                RowLayout {
                    Layout.fillWidth: true
                    spacing: 8

                    LanShareAction {
                        label: "Copy"
                        Layout.fillWidth: true
                        onClicked: LanShareService.copyReceivedText()
                    }

                    LanShareAction {
                        label: "Done"
                        Layout.fillWidth: true
                        onClicked: LanShareService.finishText()
                    }
                }
            }

            // Terminal state
            ColumnLayout {
                visible: LanShareService.viewState === "success" || LanShareService.viewState === "error"
                Layout.fillWidth: true
                spacing: 8

                Text {
                    Layout.fillWidth: true
                    text: LanShareService.viewState === "success" ? LanShareService.statusText : LanShareService.errorText
                    color: root.strongFg
                    font.pixelSize: 14
                    font.bold: true
                    wrapMode: Text.WordWrap
                }

                Text {
                    visible: LanShareService.viewState === "success" && LanShareService.transferPeer !== ""
                    Layout.fillWidth: true
                    text: (LanShareService.statusText === "Sent" ? "to " : "from ") + LanShareService.transferPeer
                    color: root.softFg
                    font.pixelSize: 12
                    wrapMode: Text.WordWrap
                }

                LanShareAction {
                    label: "Done"
                    onClicked: LanShareService.finishTerminal()
                }
            }
        }
    }
}
