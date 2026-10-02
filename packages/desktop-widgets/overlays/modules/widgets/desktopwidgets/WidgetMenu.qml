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
    // Centred in the room that is actually free: below the bar and above the dock. Both are
    // this desktop's own measured numbers (the same ones tests/designfit.js pins the widgets
    // with), and a panel that ignores them is a panel that starts under the notch and ends over
    // the dock — which is how it read on the 1366x768 output before this.
    margins.top: root.barClearance
                 + Math.round((screen.height - root.barClearance - root.dockClearance
                               - implicitHeight) / 2)
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
    // The shape is decided by WIDTH, not by height: the horizontal menu is the DEFAULT on
    // every screen wide enough for it. The panel is a control surface, and height is the
    // scarce axis on both outputs this desktop has (1366x768 and 1920x1080) — the same
    // overlay is drawn on both, and the vertical shape it used to get on the 1080 was 949px
    // tall (88% of the screen) and grew with every widget added, which is how the widget
    // list's bottom edge came to be clipped. Only a screen too narrow for two columns keeps
    // the single column; the height cap and the inner Flickable remain the backstop for a
    // screen shorter than anything measured here. Measured live: two columns are 808x656 on
    // the 1366x768 output and 808x700 on the 1920x1080 one, against the 412x949 the 1080
    // used to draw.
    readonly property bool twoColumns: root.screen.width >= (root.columnWidth * 2 + root.columnGap + 24)
    // Three columns are for a screen that is WIDE and SHORT: the same tree, with the settings
    // block standing beside the other two instead of crossing the bottom. It is chosen only when
    // the two-column shape does NOT fit the room and the three-column one does — the shape is a
    // consequence of the room, never a preference. (The comment above used to claim a third column
    // would not fit a 1366-wide output: 380*3 + 16*2 + 24 = 1196, and that output is 1366.)
    readonly property bool threeColumns: root.screen.width >= (root.columnWidth * 3 + root.columnGap * 2 + 24)
        && (root.shapeTwoHeight + 32) > root.maxMenuHeight
        && (root.shapeThreeHeight + 32) <= root.maxMenuHeight
    readonly property int menuColumns: root.threeColumns ? 3 : (root.twoColumns ? 2 : 1)
    // What each shape needs in height, taken from the three blocks themselves: they are the same
    // blocks in every shape and their own heights do not depend on how many columns they sit in,
    // so these two numbers cannot chase the shape they decide.
    readonly property int shapeTwoHeight: Math.max(widgetsColumn.implicitHeight,
                                                   calendarsColumn.implicitHeight)
                                          + 10 + settingsColumn.implicitHeight
    readonly property int shapeThreeHeight: Math.max(widgetsColumn.implicitHeight,
                                                     Math.max(calendarsColumn.implicitHeight,
                                                              settingsColumn.implicitHeight))
    // Row pitch of each list, measured on the running shell: a widget row is 40px, a
    // calendar row 42px. A cap expressed in ROWS rather than in pixels is what keeps a
    // change from slicing a row in half at the boundary.
    readonly property int widgetRowPitch: 40
    readonly property int sourceRowPitch: 42
    // How many rows each list draws at once. Both lists stop drawing past their cap (the
    // config files stay the full editors) so the panel's height cannot grow with how many
    // widgets or calendars are in them; past the cap the list scrolls and says how many are
    // left. Six of each is what the SHORT screen holds with the other column full: six
    // calendar rows put the two-column menu at 700px against the 744 it is allowed on the
    // 1366x768 output, and the widget cap binds first on a taller screen.
    readonly property int maxWidgetRows: 6
    readonly property int maxSourceRows: 6
    readonly property int menuWidth: root.columnWidth * root.menuColumns
                                     + root.columnGap * (root.menuColumns - 1)
    implicitWidth: DesktopWidgetsService.editMode ? 230 : (root.menuWidth + 32)
    // Whatever the shape, the menu has to fit the SMALLEST screen the user has — the layout
    // it edits is drawn on all of them. Past the cap it scrolls instead of running off the
    // edge, where its own title and its Done button would be unreachable.
    // The room is what is BETWEEN the bar and the dock, not the screen. Before this the cap was
    // `screen.height - 24`: on the 1366x768 output that is 744, centred into y 12..756 — starting
    // under the notch and ending over the dock, which is exactly where the user found it.
    readonly property int barClearance: 48
    readonly property int dockClearance: 71
    readonly property int maxMenuHeight: Math.max(240, root.screen.height - root.barClearance
                                                  - root.dockClearance - 24)
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
                    id: widgetsColumn
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
                    // 0x0 and the whole list renders invisible. Height comes from the
                    // column's implicit height, not from contentHeight, so there is no
                    // circular binding — and it is capped in WHOLE ROWS (never at a pixel
                    // offset that can slice one in half).
                    Flickable {
                        id: widgetList
                        interactive: true
                        clip: true
                        Layout.fillWidth: true
                        Layout.preferredHeight: Math.min(widgetListColumn.implicitHeight, root.maxWidgetRows * root.widgetRowPitch)
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

                                        ToggleSwitch {
                                            checked: widgetRow.modelData.enabled !== false
                                            onToggled: DesktopWidgetsService.setVisible(widgetRow.index, checked)
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

                        }
                    }

                    // The list stops drawing past the cap, and says how many rows are out of
                    // sight instead of hiding them: it scrolls (the wheel works over it) so
                    // nothing is unreachable, and the file stays the full editor.
                    Text {
                        Layout.fillWidth: true
                        visible: DesktopWidgetsService.widgets.length > root.maxWidgetRows
                        text: "+" + (DesktopWidgetsService.widgets.length - root.maxWidgetRows) + " more (scroll the list)"
                        textFormat: Text.PlainText
                        color: Colors.overSurfaceVariant
                        font.family: Config.theme.font
                        font.pixelSize: Styling.fontSize(-1)
                    }

                    // Add widget row — OUTSIDE the list's Flickable on purpose. This row is how
                    // a widget gets added, and while it lived inside a column capped at 220px it
                    // was the last thing in it: with five widgets the content measured 226px, so
                    // the cap sliced the row's bottom edge off (its border and both bottom
                    // corners) and the panel looked broken — on both screens, since the left
                    // column is the same in both shapes.
                    RowLayout {
                        Layout.fillWidth: true
                        spacing: 6

                        Repeater {
                            model: ["clock", "calendar", "weather", "system", "media"]

                            IconButton {
                                required property string modelData

                                icon: modelData === "clock" ? Icons.clock : modelData === "calendar" ? Icons.notepad : modelData === "weather" ? Icons.sunDim : modelData === "media" ? Icons.note : Icons.thermometer
                                label: root.widgetName(modelData)
                                onActivated: DesktopWidgetsService.addWidget(modelData, root.screen.width, root.screen.height)
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
                    id: calendarsColumn
                    // Right of the widgets unless there is only one column, in which case it goes
                    // under them. (`=== 2` was wrong the moment a third column existed: three
                    // columns put this block at row 1, column 0 — under the widgets, on top of
                    // nothing.)
                    Layout.row: root.menuColumns === 1 ? 1 : 0
                    Layout.column: root.menuColumns === 1 ? 0 : 1
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

                            ToggleSwitch {
                                checked: sourceRow.modelData.enabled !== false
                                // Only a real toggle: assigning `checked` from the binding (delegate
                                // creation, or a reload after an edit) also emits toggled, and a
                                // write triggered by merely opening the menu would save whatever
                                // this list happens to hold at that instant.
                                onToggled: {
                                    if (checked !== (sourceRow.modelData.enabled !== false))
                                        CalendarEventsService.setSourceEnabled(sourceRow.index, checked);
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
                    id: settingsColumn
                    // Across the bottom in the one- and two-column shapes; its own column in the
                    // three-column one, which is the whole point of that shape: a block that
                    // crosses the bottom is height the panel pays on top of the tallest column.
                    Layout.row: root.menuColumns === 3 ? 0 : (root.menuColumns === 2 ? 1 : 2)
                    Layout.column: root.menuColumns === 3 ? 2 : 0
                    Layout.columnSpan: root.menuColumns === 3 ? 1 : root.menuColumns
                    Layout.fillWidth: root.menuColumns !== 3
                    Layout.preferredWidth: root.menuColumns === 3 ? root.columnWidth : -1
                    spacing: 10
                    // The rule only means something when this block crosses the bottom; standing
                    // in a column of its own it would be a line under the title for no reason.
                    Separator {
                        visible: root.menuColumns !== 3
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

                        ToggleSwitch {
                            checked: DesktopWidgetsService.editMode
                            onToggled: DesktopWidgetsService.editMode = checked
                        }
                    }

                    // A BEHAVIOUR switch, next to the look's own: what the media card does
                    // while nothing is playing. `setKeepWhenIdle` and not the property, so
                    // the write is only real on a real toggle (the switch is bound to the
                    // same value and fires when the file's value lands).
                    RowLayout {
                        Layout.fillWidth: true

                        Text {
                            text: "Keep the media card"
                            textFormat: Text.PlainText
                            color: Colors.overBackground
                            font.family: Config.theme.font
                            font.pixelSize: Styling.fontSize(0)
                            Layout.fillWidth: true
                        }

                        ToggleSwitch {
                            checked: DesktopWidgetsService.keepWhenIdle
                            onToggled: DesktopWidgetsService.setKeepWhenIdle(checked)
                        }
                    }

                    Text {
                        text: "Off: the player card leaves the desktop while nothing is playing. "
                              + "On: it stays and says so on its cover, so the layout never moves."
                        textFormat: Text.PlainText
                        color: Colors.overSurfaceVariant
                        font.family: Config.theme.font
                        font.pixelSize: Styling.fontSize(-1)
                        wrapMode: Text.WordWrap
                        Layout.fillWidth: true
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

                    // The card's material: two options and no more, and the pick is live —
                    // the frames read the service, so a switch here repaints the desktop
                    // with no restart and nothing to reload.
                    RowLayout {
                        Layout.fillWidth: true
                        spacing: 8

                        Text {
                            text: "Card surface"
                            textFormat: Text.PlainText
                            color: Colors.overBackground
                            font.family: Config.theme.font
                            font.pixelSize: Styling.fontSize(0)
                            Layout.fillWidth: true
                        }

                        // Read back out of here by tests/widget-family-menu.py, so the
                        // expectation is an index into the ORDER the menu lists them in.
                        FamilySwitch {
                            options: ["Solid", "Glass"]
                            currentIndex: DesktopWidgetsService.background === "solid" ? 0 : 1
                            onPicked: index => DesktopWidgetsService.setBackground(
                                index === 0 ? "solid" : "glass")
                        }
                    }

                    Text {
                        text: "Solid: one flat colour, nothing of the wallpaper showing. "
                              + "Glass: the translucent card the wallpaper blurs behind it, at "
                              + "the opacity below."
                        textFormat: Text.PlainText
                        color: Colors.overSurfaceVariant
                        font.family: Config.theme.font
                        font.pixelSize: Styling.fontSize(-1)
                        wrapMode: Text.WordWrap
                        Layout.fillWidth: true
                    }

                    // The card surface's OWN slider: what a bare slider in a menu says nothing
                    // about. Labelled, because an unlabelled one says nothing.
                    // This is the card's OWN opacity — how much of the wallpaper shows
                    // through the glass — not the theme's color, which comes from the
                    // shell palette (colors.json / matugen). Hidden in `solid`, where there
                    // is no glass to see through: a control that does nothing is a control
                    // that lies about what the mode does.
                    ColumnLayout {
                        visible: DesktopWidgetsService.background !== "solid"
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

    // The menu's on/off switch. Its whole reason to exist is the bug it fixes: the knob
    // used to be bound to `parent.checked` INSIDE the indicator's own Rectangle, where
    // `parent` is that Rectangle — which has no `checked`, so the binding silently took
    // the false branch forever. The pill (bound one level up, where `parent` IS the
    // Switch) changed colour and position correctly, and the knob never did: reading the
    // live control, a checked Switch showed the ON pill with the OFF knob colour at the
    // OFF x. That is what "they look the same on and off" was. Here the Switch carries an
    // id, so every binding reads the control itself and there is no level to get wrong.
    // One component, one place to fix — the row, the calendar sources and Edit layout all
    // used to carry their own copy of those 25 broken lines.
    component ToggleSwitch: Switch {
        id: toggle

        indicator: Rectangle {
            implicitWidth: 36
            implicitHeight: 18
            x: toggle.leftPadding
            y: toggle.height / 2 - height / 2
            radius: height / 2
            color: toggle.checked ? Styling.srItem("primary") : Colors.surfaceBright
            // Hover is the only other feedback a switch this small can give: without it
            // the control reads as decoration, which is half of why the row felt dead.
            border.color: toggle.checked ? Styling.srItem("primary")
                                         : (toggle.hovered ? Colors.overBackground : Colors.outline)

            Rectangle {
                x: toggle.checked ? parent.width - width - 2 : 2
                y: 2
                width: parent.height - 4
                height: width
                radius: width / 2
                color: toggle.checked ? Colors.background : Colors.overSurfaceVariant

                Behavior on x {
                    enabled: Config.animDuration > 0
                    NumberAnimation {
                        duration: Config.animDuration / 2
                    }
                }
            }
        }
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
