pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import QtQuick.Controls
import Quickshell
import Quickshell.Wayland
import qs.modules.theme
import qs.modules.services
import qs.modules.components
import qs.config

// Management menu for the desktop widgets: per-entry visibility/removal, add
// widget rows, the layout edit toggle (drag mode), a global opacity slider and
// reset/done. Visibility is driven by the Visibilities "desktopwidgets" module
// (registered by the manifest's visibilities.patch), so opening it follows the
// usual active-module conventions (Esc / opening another module closes it).
PanelWindow {
    id: root

    // The Variants delegate declares `modelData` and passes it as `screen`.
    // Layer-shell anchors only support the four edges (the Anchors type has no
    // `center`), so the menu is centred by anchoring top-left and offsetting
    // with margins for its own size.
    anchors {
        top: true
        left: true
    }
    margins.top: Math.round((screen.height - implicitHeight) / 2)
    margins.left: Math.round((screen.width - implicitWidth) / 2)

    // A segmented switch with a sliding highlight, sized to its labels. NOT the stock
    // SegmentedSwitch: that one measures its highlight from the selected button before
    // the buttons exist, so the highlight starts as a buttonSize-wide blob at x = 0 —
    // off the selected label, and visibly wrong until the selection is clicked once —
    // and it assigns currentIndex on click, which cuts the binding that keeps a switch
    // on the family the file says. Same shape as the shell's own replacement for it
    // (modules/widgets/dashboard/controls/RoadiePanel.qml, `ModeSwitch`): the SELECTED
    // button reports its own geometry, and the index is only ever what the setting is.
    component FamilySwitch: StyledRect {
        id: seg
        property var options: []
        property int currentIndex: 0
        signal picked(int index)

        property real selX: 0
        property real selW: 0
        property bool ready: false
        Component.onCompleted: Qt.callLater(() => seg.ready = true)

        variant: "common"
        radius: Styling.radius(-4)
        enableShadow: false
        implicitWidth: segRow.implicitWidth + 4
        implicitHeight: 32

        StyledRect {
            variant: "focus"
            radius: Styling.radius(-6)
            enableShadow: false
            x: 2 + seg.selX
            y: 2
            width: seg.selW
            height: seg.height - 4
            visible: seg.selW > 0

            Behavior on x {
                enabled: seg.ready && Config.animDuration > 0
                NumberAnimation { duration: Config.animDuration / 2; easing.type: Easing.OutCubic }
            }
            Behavior on width {
                enabled: seg.ready && Config.animDuration > 0
                NumberAnimation { duration: Config.animDuration / 2; easing.type: Easing.OutCubic }
            }
        }

        Row {
            id: segRow
            x: 2
            y: 2
            height: seg.height - 4
            spacing: 2

            Repeater {
                model: seg.options

                Item {
                    id: segButton
                    required property var modelData
                    required property int index
                    readonly property bool selected: seg.currentIndex === index

                    width: segLabel.implicitWidth + 20
                    height: segRow.height

                    Binding {
                        target: seg
                        property: "selX"
                        value: segButton.x
                        when: segButton.selected
                    }
                    Binding {
                        target: seg
                        property: "selW"
                        value: segButton.width
                        when: segButton.selected
                    }

                    Text {
                        id: segLabel
                        anchors.centerIn: parent
                        text: String(segButton.modelData)
                        color: segButton.selected ? Styling.srItem("overprimary") : Colors.overBackground
                        font.family: Config.theme.font
                        font.pixelSize: Styling.fontSize(-1)
                        font.weight: segButton.selected ? Font.DemiBold : Font.Normal
                    }

                    Accessible.role: Accessible.RadioButton
                    Accessible.name: String(segButton.modelData)
                    Accessible.checked: segButton.selected

                    TapHandler {
                        onTapped: seg.picked(segButton.index)
                    }
                    HoverHandler {
                        cursorShape: Qt.PointingHandCursor
                    }
                }
            }
        }
    }

    color: "transparent"
    exclusionMode: ExclusionMode.Ignore

    // While editing, the widgets layer remaps to Top; this menu must stay
    // reachable above it, so the pill rides on the Overlay layer.
    WlrLayershell.layer: DesktopWidgetsService.editMode ? WlrLayer.Overlay : WlrLayer.Top
    WlrLayershell.namespace: "ambxst:desktopwidgets-menu"
    // Exclusive keyboard focus while the menu is open — EXCEPT while editing:
    // an exclusive-keyboard layer surface makes the compositor stop routing
    // pointer events to the widget layer, killing drag-to-move. The pill's
    // Done button stays clickable (pointer is unaffected by keyboard focus).
    WlrLayershell.keyboardFocus: (root.open && !DesktopWidgetsService.editMode)
        ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None

    readonly property var screenVisibilities: Visibilities.getForScreen(screen.name)
    readonly property bool open: screenVisibilities ? screenVisibilities.desktopwidgets : false

    visible: root.open
    // Collapsed to a small pill while editing so the panel does not sit on
    // top of the layout being edited; restored when Edit Layout turns off.
    // One column is 380: the add row (four icon+label buttons plus the column margins)
    // needs ~360px, and at 300 the last label elided to a single letter. Two of them plus
    // the gap and the panel's own margins come to 808, which is what has to fit a
    // 1366-wide output — a third column would not, which is why the menu never goes wider.
    readonly property int columnWidth: 380
    readonly property int columnGap: 16
    // The menu's natural shape is ONE column, holding three blocks: the widgets, the
    // calendars, the footer. A screen too short for that column gets two columns side by
    // side instead of a scrollbar. Both numbers below are measured on the running shell,
    // never guessed: one column is 807px with a single source and grows 42px per extra
    // source row (the list stops drawing rows past six, so a column tops out at 1017 and
    // a 1080-tall output still shows it whole). The two-column shape measures 808x574 on
    // the 1366x768 output — it is the LEFT block that is tall there (the designs plus four
    // widget rows), so it does not grow with the calendars at all. If a change makes these
    // wrong, the estimate is what is wrong: the Flickable below is the backstop, and
    // tests/desktop-widgets-menu-geometry.py checks the decision against the live shell.
    readonly property int oneColumnHeight: 807 + Math.max(0, CalendarEventsService.entries.length - 1) * 42
    readonly property bool twoColumns: (root.screen.height - 24) < root.oneColumnHeight
                                        && root.screen.width >= (root.columnWidth * 2 + root.columnGap + 24)
    readonly property int menuColumns: root.twoColumns ? 2 : 1
    // How many calendar rows are drawn at once. Fewer per column when the screen is short:
    // the shapes have to fit, and the file is always the full editor.
    readonly property int maxSourceRows: root.menuColumns === 2 ? 4 : 6
    readonly property int menuWidth: root.menuColumns === 1
                                     ? root.columnWidth
                                     : root.columnWidth * 2 + root.columnGap
    implicitWidth: DesktopWidgetsService.editMode ? 230 : (root.menuWidth + 32)
    // Whatever the shape, the menu has to fit the SMALLEST screen the user has — the layout
    // it edits is drawn on all of them. Past the cap it scrolls instead of running off the
    // edge, where its own title and its Done button would be unreachable.
    readonly property int maxMenuHeight: Math.max(240, root.screen.height - 24)
    implicitHeight: DesktopWidgetsService.editMode ? (pillRow.implicitHeight + 24) : Math.min(menuGrid.implicitHeight + 32, root.maxMenuHeight)

    onVisibleChanged: {
        if (visible)
            menuPanel.forceActiveFocus();
        else
            DesktopWidgetsService.editMode = false;
    }

    function widgetName(type) {
        return type.charAt(0).toUpperCase() + type.slice(1);
    }

    function close() {
        // Hand control back, the way Ambxst's own overlays do.
        Visibilities.setActiveModule("");
    }

    // Color picked for the NEXT calendar (empty means "the first free one"), and the
    // reason the last Add did not take.
    property string newColorName: ""
    property string addError: ""
    readonly property string newSourceColor: root.newColorName !== "" ? root.newColorName : CalendarEventsService.nextColorName()

    // Adds what is in the two fields, and clears them on success: the link lives in the
    // file, not on screen.
    function addNow() {
        var why = CalendarEventsService.addSource(nameInput.text, linkInput.text, root.newSourceColor);
        if (why === "") {
            nameInput.clear();
            linkInput.clear();
            root.newColorName = "";
            root.addError = "";
        } else {
            root.addError = why;
        }
    }

    function cycleNewColor() {
        var names = CalendarEventsService.paletteNames;
        var at = names.indexOf(root.newSourceColor);
        root.newColorName = names[(at + 1) % names.length];
    }

    // The shell's own compact text field: the shape RoadieQuotesEditor uses, 34px with a
    // StyledRect that swaps variant on focus. The menu first used SearchInput, which is
    // built for 48px (8px of layout margins around a 32px text area) — squeezed to 30 the
    // text drops to the bottom of the pill, because the component centres by having room.
    // verticalAlignment is set explicitly here so the text is centred at any height, and the
    // horizontal padding replaces what the old component's inner margins used to give.
    component Field: TextField {
        id: field
        implicitHeight: 34
        color: Colors.overBackground
        font.family: Config.theme.font
        font.pixelSize: Styling.fontSize(-1)
        selectByMouse: true
        placeholderTextColor: Colors.outline
        verticalAlignment: TextInput.AlignVCenter
        topPadding: 0
        bottomPadding: 0
        leftPadding: 10
        rightPadding: 10
        background: StyledRect {
            variant: field.activeFocus ? "focus" : "common"
            radius: Styling.radius(-2)
            enableShadow: false
        }
    }

    StyledRect {
        id: menuPanel
        anchors.fill: parent
        variant: "popup"
        enableShadow: true

        Keys.priority: Keys.BeforeItem
        Keys.onPressed: function (event) {
            if (event.key === Qt.Key_Escape) {
                // While editing, Esc restores the main menu first.
                if (DesktopWidgetsService.editMode)
                    DesktopWidgetsService.editMode = false;
                else
                    root.close();
                event.accepted = true;
            }
        }

        Flickable {
            id: menuFlick
            visible: !DesktopWidgetsService.editMode
            anchors.fill: parent
            anchors.margins: 16
            contentWidth: width
            contentHeight: menuGrid.implicitHeight
            boundsBehavior: Flickable.StopAtBounds
            clip: true

            // A GridLayout, not a Column: the three blocks are placed as cells, so the same
            // content is one column on a tall screen and two on a short one, without a second
            // copy of anything. columnSpan keeps the footer across the bottom in both shapes.
            GridLayout {
                id: menuGrid
                width: menuFlick.width
                columns: root.menuColumns
                columnSpacing: root.columnGap
                rowSpacing: 10

                // The widgets themselves: the design picker, the entries, the add row.
                ColumnLayout {
                    Layout.row: 0
                    Layout.column: 0
                    Layout.preferredWidth: root.columnWidth
                    spacing: 10

                    Text {
                        text: "Desktop widgets"
                        textFormat: Text.PlainText
                        font.family: Config.theme.font
                        font.pixelSize: Styling.fontSize(1)
                        font.weight: Font.Bold
                        color: Colors.overBackground
                    }

                    // Design picker: one button per built-in design. Thumbnails are drawn
                    // with the SAME placement arithmetic the desktop uses, on a 1920x1080
                    // reference, so a preview cannot show something the design does not do.
                    Text {
                        text: DesktopWidgetsService.design === "custom" ? "Design (custom)" : "Design"
                        textFormat: Text.PlainText
                        color: Colors.overBackground
                        font.family: Config.theme.font
                        font.pixelSize: Styling.fontSize(0)
                    }

                    Flow {
                        id: designFlow
                        Layout.fillWidth: true
                        Layout.preferredHeight: designFlow.implicitHeight
                        spacing: 8

                        Repeater {
                            model: DesktopWidgetsService.designs

                            delegate: Rectangle {
                                id: designButton

                                required property var modelData
                                readonly property bool current: DesktopWidgetsService.design === modelData.id

                                width: 78
                                height: 56
                                radius: Styling.radius(2)
                                color: ma.pressed ? Styling.srItem("primary")
                                    : (designButton.current ? Colors.surfaceBright : Colors.surfaceContainer)
                                border.width: designButton.current ? 2 : 1
                                border.color: designButton.current ? Colors.primary : Colors.outline

                                // The miniature: a fake 16:9 desktop with the design's cards on it.
                                Item {
                                    id: thumb
                                    width: 66
                                    height: 28
                                    anchors.horizontalCenter: parent.horizontalCenter
                                    anchors.top: parent.top
                                    anchors.topMargin: 5
                                    clip: true

                                    Rectangle {
                                        anchors.fill: parent
                                        color: Qt.rgba(Colors.background.r, Colors.background.g, Colors.background.b, 0.5)
                                        radius: 2
                                    }

                                    Repeater {
                                        model: designButton.modelData.entries

                                        delegate: Rectangle {
                                            required property var modelData
                                            readonly property var box: DesktopWidgetsService.previewRect(modelData, thumb.width, thumb.height)

                                            visible: modelData.enabled !== false
                                            x: box.x
                                            y: box.y
                                            width: box.w
                                            height: box.h
                                            radius: 1
                                            color: Colors.overBackground
                                            opacity: 0.5
                                        }
                                    }
                                }

                                Text {
                                    anchors.horizontalCenter: parent.horizontalCenter
                                    anchors.bottom: parent.bottom
                                    anchors.bottomMargin: 3
                                    text: designButton.modelData.name
                                    textFormat: Text.PlainText
                                    color: Colors.overBackground
                                    font.family: Config.theme.font
                                    font.pixelSize: Styling.fontSize(-1)
                                }

                                MouseArea {
                                    id: ma
                                    anchors.fill: parent
                                    hoverEnabled: true
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: DesktopWidgetsService.applyDesign(designButton.modelData.id)
                                }
                            }
                        }
                    }

                    // contentWidth/contentHeight MUST be bound here: a Flickable does not
                    // take them from its content, so an unbound one keeps its content at
                    // 0x0 and the whole list (rows and add row) renders invisible. Height
                    // comes from the column's implicit height, not from contentHeight, so
                    // there is no circular binding.
                    Flickable {
                        id: widgetList
                        interactive: true
                        clip: true
                        Layout.fillWidth: true
                        Layout.preferredHeight: Math.min(widgetListColumn.implicitHeight, 220)
                        contentWidth: width
                        contentHeight: widgetListColumn.implicitHeight

                        ColumnLayout {
                            id: widgetListColumn
                            width: widgetList.width
                            spacing: 8

                            // Existing layout entries: name, content family, visible
                            // toggle, remove. A "group" entry draws its children instead
                            // of itself, so its own family means nothing: the children get
                            // one sub-row each, since a child carries its own family.
                            Repeater {
                                model: DesktopWidgetsService.widgets

                                ColumnLayout {
                                    id: widgetRow
                                    required property var modelData
                                    required property int index

                                    readonly property bool isGroup: !!(modelData.children && modelData.children.length > 0)

                                    Layout.fillWidth: true
                                    spacing: 4

                                    RowLayout {
                                        Layout.fillWidth: true
                                        spacing: 6

                                        Text {
                                            textFormat: Text.PlainText
                                            text: (root.widgetName(widgetRow.modelData.type)
                                                + (widgetRow.isGroup ? " (group)" : ""))
                                            color: Colors.overBackground
                                            font.family: Config.theme.font
                                            font.pixelSize: Styling.fontSize(0)
                                            elide: Text.ElideRight
                                            Layout.fillWidth: true
                                            Layout.maximumWidth: 160
                                        }

                                        // The shell's own pick-one-of-N control. Hidden for
                                        // groups (they draw their children) and for a family
                                        // this mod does not know: the file keeps whatever a
                                        // hand edit put there, and the widget falls back to
                                        // its own full layout.
                                        FamilySwitch {
                                            visible: !widgetRow.isGroup
                                                && options.indexOf(widgetRow.modelData.family) >= 0
                                            options: DesktopWidgetsService.familiesFor(widgetRow.modelData.type)
                                            currentIndex: Math.max(0, options.indexOf(widgetRow.modelData.family))
                                            onPicked: index => DesktopWidgetsService.setFamily(widgetRow.index, -1, options[index])
                                        }

                                    Switch {
                                        checked: widgetRow.modelData.enabled !== false
                                        onToggled: DesktopWidgetsService.setVisible(widgetRow.index, checked)

                                        indicator: Rectangle {
                                            implicitWidth: 36
                                            implicitHeight: 18
                                            x: parent.leftPadding
                                            y: parent.height / 2 - height / 2
                                            radius: height / 2
                                            color: parent.checked ? Styling.srItem("primary") : Colors.surfaceBright
                                            border.color: parent.checked ? Styling.srItem("primary") : Colors.outline

                                            Rectangle {
                                                x: parent.checked ? parent.width - width - 2 : 2
                                                y: 2
                                                width: parent.height - 4
                                                height: width
                                                radius: width / 2
                                                color: parent.checked ? Colors.background : Colors.overSurfaceVariant

                                                Behavior on x {
                                                    enabled: Config.animDuration > 0
                                                    NumberAnimation {
                                                        duration: Config.animDuration / 2
                                                    }
                                                }
                                            }
                                        }
                                    }

                                        IconButton {
                                            icon: Icons.trash
                                            onActivated: DesktopWidgetsService.removeWidget(widgetRow.index)
                                        }
                                    }

                                    // One sub-row per group child. A child has its own
                                    // family but no visibility flag of its own (it shows
                                    // when its card does), so no toggle here.
                                    ColumnLayout {
                                        visible: widgetRow.isGroup
                                        Layout.fillWidth: true
                                        spacing: 4

                                        Repeater {
                                            model: widgetRow.modelData.children || []

                                            RowLayout {
                                                id: childRow
                                                required property var modelData
                                                required property int index

                                                Layout.fillWidth: true
                                                Layout.leftMargin: 14
                                                spacing: 6

                                                Text {
                                                    textFormat: Text.PlainText
                                                    text: root.widgetName(childRow.modelData.type)
                                                    color: Colors.overSurfaceVariant
                                                    font.family: Config.theme.font
                                                    font.pixelSize: Styling.fontSize(-1)
                                                    elide: Text.ElideRight
                                                    Layout.fillWidth: true
                                                    Layout.maximumWidth: 160
                                                }

                                                FamilySwitch {
                                                    visible: options.indexOf(childRow.modelData.family) >= 0
                                                    options: DesktopWidgetsService.familiesFor(childRow.modelData.type)
                                                    currentIndex: Math.max(0, options.indexOf(childRow.modelData.family))
                                                    onPicked: index => DesktopWidgetsService.setFamily(widgetRow.index, childRow.index, options[index])
                                                }
                                            }
                                        }
                                    }
                                }
                            }

                            // Add widget row.
                            RowLayout {
                                Layout.fillWidth: true
                                spacing: 6

                                Repeater {
                                    model: ["clock", "calendar", "weather", "system"]

                                    IconButton {
                                        required property string modelData

                                        icon: modelData === "clock" ? Icons.clock : modelData === "calendar" ? Icons.notepad : modelData === "weather" ? Icons.sunDim : Icons.thermometer
                                        label: root.widgetName(modelData)
                                        onActivated: DesktopWidgetsService.addWidget(modelData, root.screen.width, root.screen.height)
                                    }
                                }
                            }
                        }
                    }

                    Separator {
                        Layout.fillWidth: true
                    }

                }

                // The calendars: this block is what makes the menu tall, so it is the one
                // that moves to a second column when the screen is short.
                ColumnLayout {
                    Layout.row: root.menuColumns === 2 ? 0 : 1
                    Layout.column: root.menuColumns === 2 ? 1 : 0
                    Layout.preferredWidth: root.columnWidth
                    spacing: 10
                    // Calendars: the SAME file the service reads, edited here. The menu keeps no
                    // copy of anything, so a hand-edited entry and this list cannot disagree, and
                    // only the tail of a link is ever drawn — the shell's log is plain text.
                    Text {
                        text: "Calendars"
                        textFormat: Text.PlainText
                        color: Colors.overBackground
                        font.family: Config.theme.font
                        font.pixelSize: Styling.fontSize(0)
                    }

                    Text {
                        text: "Any iCal link works: Google's secret address, an iCloud published calendar, Outlook. Local .ics files too."
                        textFormat: Text.PlainText
                        color: Colors.overSurfaceVariant
                        font.family: Config.theme.font
                        font.pixelSize: Styling.fontSize(-1)
                        wrapMode: Text.WordWrap
                        Layout.fillWidth: true
                    }

                    Repeater {
                        // Rows are capped so the menu stays whole: a row is 42px, and past the
                        // cap the file is the editor. Four in the two-column shape - what a
                        // short screen gets - keep that shape's height independent of how many
                        // calendars are in the file (measured: 587px on a 768-tall output with
                        // one source and with six, against the 744 it is allowed there).
                        model: CalendarEventsService.entries.slice(0, root.maxSourceRows)

                        RowLayout {
                            id: sourceRow
                            required property var modelData
                            required property int index

                            Layout.fillWidth: true
                            spacing: 8

                            Rectangle {
                                Layout.preferredWidth: 12
                                Layout.preferredHeight: 12
                                Layout.alignment: Qt.AlignVCenter
                                radius: width / 2
                                color: CalendarEventsService.colorFor(sourceRow.modelData.color, sourceRow.index)
                                border.width: 1
                                border.color: Colors.outline

                                MouseArea {
                                    anchors.fill: parent
                                    hoverEnabled: true
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: CalendarEventsService.cycleSourceColor(sourceRow.index)
                                }
                            }

                            Text {
                                textFormat: Text.PlainText
                                text: sourceRow.modelData.name
                                color: Colors.overBackground
                                font.family: Config.theme.font
                                font.pixelSize: Styling.fontSize(0)
                                elide: Text.ElideRight
                                Layout.maximumWidth: 110
                                Layout.fillWidth: true
                            }

                            Text {
                                textFormat: Text.PlainText
                                text: CalendarEventsService.sourceTail(sourceRow.modelData)
                                color: Colors.overSurfaceVariant
                                font.family: Config.theme.font
                                font.pixelSize: Styling.fontSize(-1)
                                elide: Text.ElideMiddle
                                Layout.fillWidth: true
                            }

                            Switch {
                                checked: sourceRow.modelData.enabled !== false
                                // Only a real toggle: assigning `checked` from the binding (delegate
                                // creation, or a reload after an edit) also emits toggled, and a
                                // write triggered by merely opening the menu would save whatever
                                // this list happens to hold at that instant.
                                onToggled: {
                                    if (checked !== (sourceRow.modelData.enabled !== false))
                                        CalendarEventsService.setSourceEnabled(sourceRow.index, checked);
                                }

                                indicator: Rectangle {
                                    implicitWidth: 36
                                    implicitHeight: 18
                                    x: parent.leftPadding
                                    y: parent.height / 2 - height / 2
                                    radius: height / 2
                                    color: parent.checked ? Styling.srItem("primary") : Colors.surfaceBright
                                    border.color: parent.checked ? Styling.srItem("primary") : Colors.outline

                                    Rectangle {
                                        x: parent.checked ? parent.width - width - 2 : 2
                                        y: 2
                                        width: parent.height - 4
                                        height: width
                                        radius: width / 2
                                        color: parent.checked ? Colors.background : Colors.overSurfaceVariant

                                        Behavior on x {
                                            enabled: Config.animDuration > 0
                                            NumberAnimation {
                                                duration: Config.animDuration / 2
                                            }
                                        }
                                    }
                                }
                            }

                            IconButton {
                                icon: Icons.trash
                                onActivated: CalendarEventsService.removeSource(sourceRow.index)
                            }
                        }
                    }

                    Text {
                        visible: CalendarEventsService.entries.length > root.maxSourceRows
                        text: "+" + (CalendarEventsService.entries.length - root.maxSourceRows) + " more, in the file"
                        textFormat: Text.PlainText
                        color: Colors.overSurfaceVariant
                        font.family: Config.theme.font
                        font.pixelSize: Styling.fontSize(-1)
                    }

                    Text {
                        visible: CalendarEventsService.entries.length === 0
                        text: "No calendars yet. Paste a link below and the dots and the agenda fill in."
                        textFormat: Text.PlainText
                        color: Colors.overSurfaceVariant
                        font.family: Config.theme.font
                        font.pixelSize: Styling.fontSize(-1)
                        wrapMode: Text.WordWrap
                        Layout.fillWidth: true
                    }

                    RowLayout {
                        Layout.fillWidth: true
                        spacing: 6

                        Field {
                            id: nameInput
                            Layout.preferredWidth: 110
                            placeholderText: "Name"
                        }

                        Field {
                            id: linkInput
                            Layout.fillWidth: true
                            placeholderText: "Link or .ics path"
                            onAccepted: root.addNow()
                        }
                    }

                    RowLayout {
                        Layout.fillWidth: true
                        spacing: 8

                        Rectangle {
                            Layout.preferredWidth: 12
                            Layout.preferredHeight: 12
                            Layout.alignment: Qt.AlignVCenter
                            radius: width / 2
                            color: CalendarEventsService.palette[root.newSourceColor]
                            border.width: 1
                            border.color: Colors.outline

                            MouseArea {
                                anchors.fill: parent
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                onClicked: root.cycleNewColor()
                            }
                        }

                        Text {
                            text: "Color"
                            textFormat: Text.PlainText
                            color: Colors.overSurfaceVariant
                            font.family: Config.theme.font
                            font.pixelSize: Styling.fontSize(-1)
                            Layout.fillWidth: true
                        }

                        MenuButton {
                            text: "Add"
                            onActivated: root.addNow()
                        }
                    }

                    Text {
                        visible: root.addError !== "" || CalendarEventsService.saveError !== ""
                        text: root.addError !== "" ? root.addError : CalendarEventsService.saveError
                        textFormat: Text.PlainText
                        color: Colors.error
                        font.family: Config.theme.font
                        font.pixelSize: Styling.fontSize(-1)
                        wrapMode: Text.WordWrap
                        Layout.fillWidth: true
                    }

                    Text {
                        visible: CalendarEventsService.saveError !== ""
                        text: CalendarEventsService.saveError
                        textFormat: Text.PlainText
                        color: Colors.error
                        font.family: Config.theme.font
                        font.pixelSize: Styling.fontSize(-1)
                        wrapMode: Text.WordWrap
                        Layout.fillWidth: true
                    }

                    Text {
                        text: "Click a dot to change that calendar's color. Nothing is ever logged or shown in full."
                        textFormat: Text.PlainText
                        color: Colors.overSurfaceVariant
                        font.family: Config.theme.font
                        font.pixelSize: Styling.fontSize(-1)
                        wrapMode: Text.WordWrap
                        Layout.fillWidth: true
                    }

                }

                // The footer - layout editing, opacity, the buttons - across the bottom.
                ColumnLayout {
                    Layout.row: root.menuColumns === 2 ? 1 : 2
                    Layout.column: 0
                    Layout.columnSpan: root.menuColumns
                    Layout.fillWidth: true
                    spacing: 10
                    Separator {
                        Layout.fillWidth: true
                    }

                    // Drag-mode toggle: turns the editable highlight + drag areas on.
                    RowLayout {
                        Layout.fillWidth: true

                        Text {
                            text: "Edit layout"
                            textFormat: Text.PlainText
                            color: Colors.overBackground
                            font.family: Config.theme.font
                            font.pixelSize: Styling.fontSize(0)
                            Layout.fillWidth: true
                        }

                        Switch {
                            checked: DesktopWidgetsService.editMode
                            onToggled: DesktopWidgetsService.editMode = checked

                            indicator: Rectangle {
                                implicitWidth: 36
                                implicitHeight: 18
                                x: parent.leftPadding
                                y: parent.height / 2 - height / 2
                                radius: height / 2
                                color: parent.checked ? Styling.srItem("primary") : Colors.surfaceBright
                                border.color: parent.checked ? Styling.srItem("primary") : Colors.outline

                                Rectangle {
                                    x: parent.checked ? parent.width - width - 2 : 2
                                    y: 2
                                    width: parent.height - 4
                                    height: width
                                    radius: width / 2
                                    color: parent.checked ? Colors.background : Colors.overSurfaceVariant

                                    Behavior on x {
                                        enabled: Config.animDuration > 0
                                        NumberAnimation {
                                            duration: Config.animDuration / 2
                                        }
                                    }
                                }
                            }
                        }
                    }

                    Text {
                        text: "Drag the widgets on your desktop, then click Done."
                        textFormat: Text.PlainText
                        color: Colors.overSurfaceVariant
                        font.family: Config.theme.font
                        font.pixelSize: Styling.fontSize(-1)
                        wrapMode: Text.WordWrap
                        Layout.fillWidth: true
                    }

                    // Labelled: a bare slider in a menu says nothing about what it changes.
                    // This is the card's OWN opacity — how much of the wallpaper shows
                    // through the glass — not the theme's color, which comes from the
                    // shell palette (colors.json / matugen).
                    ColumnLayout {
                        Layout.fillWidth: true
                        spacing: 2

                        Text {
                            text: "Card opacity"
                            textFormat: Text.PlainText
                            color: Colors.overBackground
                            font.family: Config.theme.font
                            font.pixelSize: Styling.fontSize(0)
                        }

                        RowLayout {
                            Layout.fillWidth: true
                            spacing: 8

                            StyledSlider {
                                Layout.fillWidth: true
                                resizeParent: false
                                vertical: false
                                smoothDrag: true
                                wavy: false
                                scroll: true
                                tooltip: false
                                value: DesktopWidgetsService.opacity
                                progressColor: Styling.srItem("primary")

                                onValueChanged: DesktopWidgetsService.setOpacity(value)
                            }

                            Text {
                                text: Math.round(DesktopWidgetsService.opacity * 100) + "%"
                                color: Colors.overSurfaceVariant
                                font.family: Config.theme.font
                                font.pixelSize: Styling.fontSize(-1)
                                Layout.preferredWidth: 40
                                horizontalAlignment: Text.AlignRight
                            }
                        }
                    }

                    RowLayout {
                        Layout.fillWidth: true
                        spacing: 8

                        MenuButton {
                            text: "Align"
                            Layout.fillWidth: true
                            onActivated: DesktopWidgetsService.alignWidgets()
                        }
                        MenuButton {
                            text: "Reset layout"
                            Layout.fillWidth: true
                            onActivated: DesktopWidgetsService.resetLayout()
                        }
                        MenuButton {
                            text: "Done"
                            Layout.fillWidth: true
                            onActivated: root.close()
                        }
                    }
                }
            }
        }

        // Edit mode: the main menu collapses to this small pill so it does
        // not sit on top of the layout being edited. Clicking Done (or Esc)
        // restores the main menu.
        RowLayout {
            id: pillRow
            visible: DesktopWidgetsService.editMode
            anchors.centerIn: parent
            spacing: 10

            Text {
                text: "Editing layout"
                textFormat: Text.PlainText
                color: Colors.overBackground
                font.family: Config.theme.font
                font.pixelSize: Styling.fontSize(0)
            }

            MenuButton {
                text: "Done"
                onActivated: DesktopWidgetsService.editMode = false
            }
        }
    }

    component Separator: Rectangle {
        height: 1
        color: Colors.outline
        opacity: 0.4
    }

    // Small themed push button, local to this menu.
    component MenuButton: Rectangle {
        id: button

        property string text: ""
        signal activated()

        height: 26
        radius: Styling.radius(2)
        color: ma.pressed ? Styling.srItem("primary") : (ma.containsMouse ? Colors.surfaceBright : "transparent")
        border.color: Colors.outline
        border.width: 1
        implicitWidth: Math.max(row.implicitWidth + 20, 60)

        Behavior on color {
            enabled: Config.animDuration > 0
            ColorAnimation {
                duration: Config.animDuration / 2
            }
        }

        Row {
            id: row
            anchors.centerIn: parent
            spacing: 4

            Text {
                anchors.verticalCenter: parent.verticalCenter
                textFormat: Text.PlainText
                text: button.text
                font.family: Config.theme.font
                font.pixelSize: Styling.fontSize(0)
                color: ma.containsMouse || ma.pressed ? Colors.background : Colors.overBackground
            }
        }

        MouseArea {
            id: ma
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: button.activated()
        }
    }

    // Square icon button (remove / add widget rows).
    component IconButton: Rectangle {
        id: iconButton

        property string icon: ""
        property string label: ""
        signal activated()

        height: 26
        width: labelRow.implicitWidth + 16
        radius: Styling.radius(2)
        color: ma.pressed ? Styling.srItem("primary") : (ma.containsMouse ? Colors.surfaceBright : Colors.surfaceContainer)
        border.color: Colors.outline
        border.width: 1

        Behavior on color {
            enabled: Config.animDuration > 0
            ColorAnimation {
                duration: Config.animDuration / 2
            }
        }

        Row {
            id: labelRow
            anchors.centerIn: parent
            spacing: 4

            Text {
                anchors.verticalCenter: parent.verticalCenter
                textFormat: Text.PlainText
                visible: iconButton.icon !== ""
                text: iconButton.icon
                font.family: Icons.font
                font.pixelSize: Styling.fontSize(0)
                color: ma.containsMouse || ma.pressed ? Colors.background : Colors.overBackground
            }

            Text {
                anchors.verticalCenter: parent.verticalCenter
                textFormat: Text.PlainText
                visible: iconButton.label !== ""
                text: iconButton.label
                font.family: Config.theme.font
                font.pixelSize: Styling.fontSize(-1)
                color: ma.containsMouse || ma.pressed ? Colors.background : Colors.overBackground
            }
        }

        MouseArea {
            id: ma
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: iconButton.activated()
        }
    }
}
