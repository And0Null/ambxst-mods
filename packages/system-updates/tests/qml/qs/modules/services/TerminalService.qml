pragma Singleton
import QtQuick

// Test stub: no terminal configured, so the service must refuse to launch.
QtObject {
    readonly property string binary: ""
    readonly property bool advanced: false
    readonly property string commandTemplate: "$TERMINAL -e $COMMAND"

    function execDetached(shellCmd) {
        console.warn("TerminalService stub execDetached called:", shellCmd);
    }
}
