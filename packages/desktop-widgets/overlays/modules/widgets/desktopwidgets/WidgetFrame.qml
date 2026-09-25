pragma ComponentBehavior: Bound
import QtQuick
import qs.modules.theme
import qs.modules.services
import qs.config

// Liquid-glass card the desktop widgets sit in: a translucent surface over the
// blurred wallpaper (the `ambxst:*` layer rule blurs this namespace), with a
// hairline highlight so the edge reads even over a bright wallpaper.
Rectangle {
    id: root

    property real glassAlpha: 0.42
    // Edit-mode affordance: a solid primary hairline so cards read as
    // draggable. (Dashed strokes need Shape/ShapePath — not worth it here.)
    property bool highlighted: false
    readonly property real alpha: Math.min(1, Math.max(0.3, DesktopWidgetsService.opacity))

    radius: Config.theme.roundness > 0 ? Config.theme.roundness + 6 : 18
    color: Qt.rgba(Colors.surface.r, Colors.surface.g, Colors.surface.b, glassAlpha)
    border.width: highlighted ? 2 : 1
    border.color: highlighted
        ? Colors.primary
        : Qt.rgba(Colors.overBackground.r, Colors.overBackground.g, Colors.overBackground.b, 0.12)
    opacity: alpha

    // A soft top highlight, the way real glass catches light.
    Rectangle {
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.right: parent.right
        height: parent.height * 0.5
        radius: parent.radius
        gradient: Gradient {
            GradientStop { position: 0.0; color: Qt.rgba(Colors.overBackground.r, Colors.overBackground.g, Colors.overBackground.b, 0.06) }
            GradientStop { position: 1.0; color: "transparent" }
        }
    }

    default property alias content: body.data

    Item {
        id: body
        anchors.fill: parent
        anchors.margins: 16
    }
}
