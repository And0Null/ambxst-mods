pragma ComponentBehavior: Bound
import QtQuick
import qs.modules.components
import qs.modules.theme
import qs.modules.services

// Bar button for the desktop widgets management menu (ToolsButton pattern).
// Click toggles the "desktopwidgets" module, which drives the WidgetMenu.
ToggleButton {
    id: widgetsButton
    buttonIcon: Icons.widgets
    tooltipText: "Desktop widgets"
    onToggle: function () {
        if (Visibilities.currentActiveModule === "desktopwidgets") {
            Visibilities.setActiveModule("");
        } else {
            Visibilities.setActiveModule("desktopwidgets");
        }
    }
}
