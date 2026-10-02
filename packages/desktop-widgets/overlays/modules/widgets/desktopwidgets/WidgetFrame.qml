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
    // The card's MATERIAL, from the user's switch in the menu: `glass` is the translucent
    // surface the compositor blurs behind it, `solid` is one flat colour with nothing of the
    // wallpaper in it — the same card, painted instead of glazed. The fill is the theme's own
    // container colour either way, so a solid card follows a light or dark theme.
    readonly property bool solid: DesktopWidgetsService.background === "solid"
    readonly property color fill: root.solid ? Colors.surfaceContainer : Colors.surface
    // Solid is opaque by definition, which is why the card-opacity slider belongs to the
    // glass: a "solid" fill at 42% is a tinted window, not a solid colour. The menu hides
    // that slider while this mode is on, so nothing on screen promises an effect it does not
    // have.

    // Edit-mode affordance: a solid primary hairline so cards read as
    // draggable. (Dashed strokes need Shape/ShapePath — not worth it here.)
    property bool highlighted: false
    readonly property real alpha: Math.min(1, Math.max(0.3, DesktopWidgetsService.opacity))

    radius: Config.theme.roundness > 0 ? Config.theme.roundness + 6 : 18
    color: root.solid ? root.fill
        : Qt.rgba(root.fill.r, root.fill.g, root.fill.b, glassAlpha)
    border.width: highlighted ? 2 : 1
    border.color: highlighted
        ? Colors.primary
        : Qt.rgba(Colors.overBackground.r, Colors.overBackground.g, Colors.overBackground.b, 0.12)
    opacity: root.solid ? 1 : alpha

    // A soft top highlight, the way real glass catches light. Only glass has a light to
    // catch: a solid colour with a gradient over it is a gradient, not a solid colour.
    Rectangle {
        visible: !root.solid
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
