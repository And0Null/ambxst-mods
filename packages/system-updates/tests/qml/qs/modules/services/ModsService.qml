pragma Singleton
import QtQuick

// Test stub for ModsService: no stored settings, records writes.
QtObject {
    signal settingChanged(string modId, string key, var value)

    property var written: []

    function getSettings(id, callback) {
        callback({ values: {} });
    }

    function setSetting(id, key, value) {
        written = written.concat([key + "=" + value]);
    }
}
