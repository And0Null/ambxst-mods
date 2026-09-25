import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import qs.modules.services
import qs.modules.components
import qs.modules.theme

// Nearby presence card (inside BarPopup): hero + receiver toggle + peer list
// + rescan + file/clipboard send + incoming accept/decline. Outgoing file
// send (v1.1) goes through the service-owned zenity picker
// (NearbyService.selectFilesTo); the card owns no picker Process.
// No PIN, no updater UI.
ColumnLayout {
    id: root

    anchors.fill: parent
    spacing: 10

    // Soft body text only for this card (theme globals untouched):
    // overSurfaceVariant in body, overSurface in titles.
    readonly property color softFg: Colors.overSurfaceVariant
    readonly property color strongFg: Colors.overSurface

    component NearbyAction: Button {
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
                    color: (NearbyService.receiverEnabled && NearbyService.backendReady) ? Styling.srItem("overprimary") : Colors.overSurfaceVariant
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
                        text: NearbyService.statusMeta
                        color: root.softFg
                        font.pixelSize: 12
                    }
                }

                NearbyAction {
                    label: NearbyService.receiverEnabled ? "ON" : "OFF"
                    primary: NearbyService.receiverEnabled
                    Layout.fillWidth: false
                    Layout.preferredWidth: 64
                    onClicked: NearbyService.toggleReceiver()
                }
            }

            // Error line
            Text {
                visible: NearbyService.errorText !== ""
                Layout.fillWidth: true
                text: NearbyService.errorText
                color: root.softFg
                font.pixelSize: 11
                wrapMode: Text.WordWrap
            }

            // Devices
            ColumnLayout {
                visible: NearbyService.viewState === "nearby"
                Layout.fillWidth: true
                spacing: 6

                Text {
                    text: "DEVICES"
                    color: root.strongFg
                    font.pixelSize: 12
                    font.bold: true
                }

                Text {
                    visible: NearbyService.peers.length === 0
                    Layout.fillWidth: true
                    text: !NearbyService.receiverEnabled
                        ? "LAN Share is turned off"
                        : (!NearbyService.backendReady ? NearbyService.statusText : (NearbyService.scanPending ? NearbyService.statusText : (NearbyService.discoveryActive ? "Finding devices…" : "No devices nearby")))
                    color: root.softFg
                    font.pixelSize: 13
                    wrapMode: Text.WordWrap
                    topPadding: 12
                    bottomPadding: 12
                }

                Repeater {
                    model: NearbyService.peers

                    delegate: MouseArea {
                        required property var modelData
                        required property int index

                        Layout.fillWidth: true
                        Layout.preferredHeight: 40
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: NearbyService.choosePeer(index)

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

                NearbyAction {
                    visible: NearbyService.receiverEnabled && NearbyService.backendReady
                    label: NearbyService.scanPending ? "Scanning…" : "Rescan"
                    onClicked: NearbyService.rescan()
                }
            }

            // Send target
            ColumnLayout {
                visible: NearbyService.viewState === "target" && NearbyService.selectedPeer
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
                    text: "To " + (NearbyService.selectedPeer ? NearbyService.selectedPeer.alias : "")
                    color: root.softFg
                    font.pixelSize: 13
                    elide: Text.ElideRight
                }

                NearbyAction {
                    label: "Send files"
                    primary: true
                    onClicked: NearbyService.selectFilesTo()
                }

                NearbyAction {
                    label: "Send clipboard"
                    primary: true
                    onClicked: NearbyService.sendTextTo(NearbyService.selectedPeer ? NearbyService.selectedPeer.fingerprint : "")
                }

                NearbyAction {
                    label: "Back"
                    onClicked: NearbyService.clearTarget()
                }
            }

            // Incoming prompt
            ColumnLayout {
                visible: NearbyService.viewState === "incoming" && NearbyService.incoming
                Layout.fillWidth: true
                spacing: 8

                Text {
                    Layout.fillWidth: true
                    text: NearbyService.incoming ? NearbyService.incoming.sender + " wants to send" : ""
                    color: root.strongFg
                    font.pixelSize: 15
                    font.bold: true
                    wrapMode: Text.WordWrap
                }

                Text {
                    Layout.fillWidth: true
                    text: NearbyService.incoming ? NearbyService.incomingSummary(NearbyService.incoming.files) : ""
                    color: root.softFg
                    font.pixelSize: 12
                    elide: Text.ElideRight
                }

                Text {
                    visible: NearbyService.incomingQueue.length > 1
                    Layout.fillWidth: true
                    text: (NearbyService.incomingQueue.length - 1) + (NearbyService.incomingQueue.length === 2 ? " more request" : " more requests")
                    color: root.softFg
                    font.pixelSize: 12
                }

                RowLayout {
                    Layout.fillWidth: true
                    spacing: 8

                    NearbyAction {
                        label: "Decline"
                        Layout.fillWidth: true
                        onClicked: NearbyService.declineIncoming()
                    }

                    NearbyAction {
                        label: "Accept"
                        primary: true
                        Layout.fillWidth: true
                        onClicked: NearbyService.acceptIncoming()
                    }
                }
            }

            // Transfer progress
            ColumnLayout {
                visible: NearbyService.viewState === "sending" || NearbyService.viewState === "receiving"
                Layout.fillWidth: true
                spacing: 8

                Text {
                    text: NearbyService.viewState === "sending" ? "SENDING" : "RECEIVING"
                    color: root.strongFg
                    font.pixelSize: 12
                    font.bold: true
                }

                Text {
                    Layout.fillWidth: true
                    text: NearbyService.transferName
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
                        width: parent.width * Math.max(0, Math.min(1, NearbyService.progress))
                        height: parent.height
                        radius: height / 2
                        color: Styling.srItem("overprimary")
                    }
                }

                Text {
                    text: Math.round(NearbyService.progress * 100) + "% · " + (NearbyService.viewState === "sending" ? "to " : "from ") + NearbyService.transferPeer
                    color: root.softFg
                    font.pixelSize: 12
                }

                NearbyAction {
                    visible: NearbyService.viewState === "sending"
                    label: "Cancel"
                    onClicked: NearbyService.cancelOutgoing()
                }
            }

            // Received text
            ColumnLayout {
                visible: NearbyService.viewState === "text"
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
                    text: NearbyService.incomingText
                    color: root.strongFg
                    font.pixelSize: 13
                    wrapMode: Text.WordWrap
                    maximumLineCount: 6
                    elide: Text.ElideRight
                }

                RowLayout {
                    Layout.fillWidth: true
                    spacing: 8

                    NearbyAction {
                        label: "Copy"
                        Layout.fillWidth: true
                        onClicked: NearbyService.copyReceivedText()
                    }

                    NearbyAction {
                        label: "Done"
                        Layout.fillWidth: true
                        onClicked: NearbyService.finishText()
                    }
                }
            }

            // Terminal state
            ColumnLayout {
                visible: NearbyService.viewState === "success" || NearbyService.viewState === "error"
                Layout.fillWidth: true
                spacing: 8

                Text {
                    Layout.fillWidth: true
                    text: NearbyService.viewState === "success" ? NearbyService.statusText : NearbyService.errorText
                    color: root.strongFg
                    font.pixelSize: 14
                    font.bold: true
                    wrapMode: Text.WordWrap
                }

                Text {
                    visible: NearbyService.viewState === "success" && NearbyService.transferPeer !== ""
                    Layout.fillWidth: true
                    text: (NearbyService.statusText === "Sent" ? "to " : "from ") + NearbyService.transferPeer
                    color: root.softFg
                    font.pixelSize: 12
                    wrapMode: Text.WordWrap
                }

                NearbyAction {
                    label: "Done"
                    onClicked: NearbyService.finishTerminal()
                }
            }
        }
    }
}
