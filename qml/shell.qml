pragma ComponentBehavior: Bound

// fnx-oem-osd — standalone Quickshell OSD reached via Quickshell IPC.
// Run it with:   qs -p <this-directory>
// Then:          qs -p <this-directory> ipc call fnx-oem-osd showPerformance
// The OSD is display-only: no keyboard focus, no pointer capture, no
// exclusive zone reservation. Display labels follow the system locale; IPC
// event tokens remain stable English identifiers.

import QtCore
import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland

PanelWindow {
    id: root

    // How long a shown OSD stays fully visible (ms).
    property int hideAfterMs: 1500
    property int animationDuration: 150
    property string currentEvent: "unknown"
    property string currentFeature: "unknown"
    property string featureLabel: "OEM"
    property string eventLabel: ""
    property bool shouldBeVisible: false
    // The DMS files are optional inputs. Keeping complete local fallbacks means
    // this config remains usable as a standalone Quickshell package.
    property var matugenData: ({})
    property var dmsSettings: ({})
    property bool isLightMode: false
    readonly property var fallbackDark: ({
            "surface_container_high": "#261e18",
            "surface_container_highest": "#302921",
            "on_surface": "#eee0d5",
            "on_surface_variant": "#d5c3b5",
            "primary": "#fcb974",
            "primary_container": "#693c00",
            "on_primary_container": "#ffdcbd",
            "secondary_container": "#59422c",
            "on_secondary_container": "#fedcbe",
            "tertiary_container": "#404b25",
            "on_tertiary_container": "#dbe8b5",
            "outline_variant": "#50453a"
        })
    readonly property var fallbackLight: ({
            "surface_container_high": "#faebe0",
            "surface_container_highest": "#f4e6da",
            "on_surface": "#211a14",
            "on_surface_variant": "#50453a",
            "primary": "#855317",
            "primary_container": "#ffdcbd",
            "on_primary_container": "#2c1600",
            "secondary_container": "#fedcbe",
            "on_secondary_container": "#291806",
            "tertiary_container": "#dbe8b5",
            "on_tertiary_container": "#161f01",
            "outline_variant": "#d5c3b5"
        })
    readonly property var fallbackColors: root.isLightMode ? root.fallbackLight : root.fallbackDark
    readonly property var activeColors: {
        const variants = root.matugenData && root.matugenData.colors;
        const selected = variants && variants[root.isLightMode ? "light" : "dark"];
        return selected || root.fallbackColors;
    }
    readonly property color surfaceColor: root.colorOrFallback("surface_container_high")
    readonly property color surfaceForegroundColor: root.colorOrFallback("on_surface")
    readonly property color surfaceMutedColor: root.colorOrFallback("on_surface_variant")
    readonly property color outlineColor: root.colorOrFallback("outline_variant")
    readonly property color accentColor: {
        switch (root.currentEvent) {
        case "performance":
            return root.colorOrFallback("primary_container");
        case "balanced":
        case "touchpad-on":
            return root.colorOrFallback("tertiary_container");
        default:
            return root.colorOrFallback("secondary_container");
        }
    }
    readonly property color accentForegroundColor: {
        switch (root.currentEvent) {
        case "performance":
            return root.colorOrFallback("on_primary_container");
        case "balanced":
        case "touchpad-on":
            return root.colorOrFallback("on_tertiary_container");
        default:
            return root.colorOrFallback("on_secondary_container");
        }
    }
    readonly property string localeName: Qt.locale().name.toLowerCase().split("_").join("-")
    readonly property bool useChinese: root.localeName === "zh" || root.localeName.startsWith("zh-")
    readonly property string themeFontFamily: root.dmsSettings.fontFamily || "sans-serif"
    readonly property int themeFontWeight: {
        const configured = Number(root.dmsSettings.fontWeight);
        return Number.isFinite(configured) ? configured : Font.Normal;
    }
    readonly property real themeFontScale: {
        const configured = Number(root.dmsSettings.fontScale);
        return Number.isFinite(configured) ? Math.max(0.85, Math.min(1.35, configured)) : 1;
    }
    readonly property real themeCornerRadius: {
        const configured = Number(root.dmsSettings.cornerRadius);
        return Number.isFinite(configured) ? Math.max(16, Math.min(30, configured)) : 24;
    }

    function colorOrFallback(name: string): color {
        return root.activeColors[name] || root.fallbackColors[name];
    }

    function isSupportedEvent(event: string): bool {
        switch (event) {
        case "performance":
        case "balanced":
        case "keyboard-backlight-off":
        case "keyboard-backlight-low":
        case "keyboard-backlight-high":
        case "touchpad-off":
        case "touchpad-on":
        case "unknown":
            return true;
        default:
            return false;
        }
    }

    function featureForEvent(event: string): string {
        switch (event) {
        case "performance":
        case "balanced":
            return "performance-mode";
        case "keyboard-backlight-off":
        case "keyboard-backlight-low":
        case "keyboard-backlight-high":
            return "keyboard-backlight";
        case "touchpad-off":
        case "touchpad-on":
            return "touchpad";
        default:
            return "unknown";
        }
    }

    function featureLabelForEvent(event: string): string {
        switch (root.featureForEvent(event)) {
        case "performance-mode":
            return "Fn+X · OEM";
        case "keyboard-backlight":
            return root.useChinese ? "Fn+F8 · 鍵盤背光" : "Fn+F8 · Keyboard backlight";
        case "touchpad":
            return root.useChinese ? "Fn+F3 · 觸控板" : "Fn+F3 · Touchpad";
        default:
            return "OEM";
        }
    }

    function labelForEvent(event: string): string {
        switch (event) {
        case "performance":
            return root.useChinese ? "性能模式" : "Performance mode";
        case "balanced":
            return root.useChinese ? "均衡模式" : "Balanced mode";
        case "keyboard-backlight-off":
            return root.useChinese ? "鍵盤背光關閉" : "Backlight off";
        case "keyboard-backlight-low":
            return root.useChinese ? "鍵盤背光低亮度" : "Backlight low";
        case "keyboard-backlight-high":
            return root.useChinese ? "鍵盤背光高亮度" : "Backlight high";
        case "touchpad-off":
            return root.useChinese ? "觸控板關閉" : "Touchpad off";
        case "touchpad-on":
            return root.useChinese ? "觸控板開啟" : "Touchpad on";
        default:
            // Compatibility fallback for direct/manual IPC callers. The
            // production listener maps every admitted code to a named event.
            return root.useChinese ? "OEM 狀態已切換" : "OEM state changed";
        }
    }

    function barHeightFor(event: string, index: int): real {
        if (event === "performance")
            return [8, 14, 20][index];

        if (event === "balanced")
            return [11, 17, 11][index];

        return 5;
    }

    function keyboardGlowWidthFor(event: string): real {
        switch (event) {
        case "keyboard-backlight-low":
            return 10;
        case "keyboard-backlight-high":
            return 20;
        default:
            return 0;
        }
    }

    function parseMatugen(content: string) {
        try {
            const parsed = JSON.parse(content);
            if (!parsed || !parsed.colors || !parsed.colors.dark || !parsed.colors.light)
                throw new Error("missing colors.dark/colors.light");

            root.matugenData = parsed;
        } catch (error) {
            console.warn("fnx-oem-osd: invalid DMS color cache; using fallback palette:", error);
            root.matugenData = {};
        }
    }

    function parseSettings(content: string) {
        try {
            const parsed = JSON.parse(content);
            root.dmsSettings = parsed || {};
        } catch (error) {
            console.warn("fnx-oem-osd: invalid DMS settings; using fallback typography:", error);
            root.dmsSettings = {};
        }
    }

    function parseSession(content: string) {
        try {
            const parsed = JSON.parse(content);
            root.isLightMode = Boolean(parsed && parsed.isLightMode);
        } catch (error) {
            console.warn("fnx-oem-osd: invalid DMS session; using dark palette:", error);
            root.isLightMode = false;
        }
    }

    function showEvent(event: string): string {
        if (!root.isSupportedEvent(event)) {
            console.warn(`fnx-oem-osd: rejected event '${event}'`);
            return "FNX_OSD_SHOW_REJECTED_INVALID_EVENT";
        }
        root.currentEvent = event;
        root.currentFeature = root.featureForEvent(event);
        root.featureLabel = root.featureLabelForEvent(event);
        root.eventLabel = root.labelForEvent(event);
        closeTimer.stop();
        root.visible = true;
        root.shouldBeVisible = true;
        hideTimer.restart(); // restart the hide timer on repeated calls
        return "FNX_OSD_SHOW_OK";
    }

    function hide() {
        root.shouldBeVisible = false;
        closeTimer.restart();
    }

    implicitWidth: 286
    implicitHeight: 90
    visible: false
    color: "transparent"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.exclusiveZone: -1
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.None

    IpcHandler {
        function show(mode: string): string {
            return root.showEvent(mode);
        }

        // noctalia-qs 0.0.12 rejects arguments on the new `ipc call` CLI.
        // These wrappers keep the typed central handler while providing a
        // zero-argument production path that works with `ipc call`.
        function showPerformance(): string {
            return root.showEvent("performance");
        }

        function showBalanced(): string {
            return root.showEvent("balanced");
        }

        function showKeyboardOff(): string {
            return root.showEvent("keyboard-backlight-off");
        }

        function showKeyboardLow(): string {
            return root.showEvent("keyboard-backlight-low");
        }

        function showKeyboardHigh(): string {
            return root.showEvent("keyboard-backlight-high");
        }

        function showTouchpadOff(): string {
            return root.showEvent("touchpad-off");
        }

        function showTouchpadOn(): string {
            return root.showEvent("touchpad-on");
        }

        function showUnknown(): string {
            return root.showEvent("unknown");
        }

        target: "fnx-oem-osd"
    }

    FileView {
        id: colorsFile

        path: StandardPaths.writableLocation(StandardPaths.GenericCacheLocation) + "/DankMaterialShell/dms-colors.json"
        blockLoading: false
        watchChanges: true
        onLoaded: root.parseMatugen(colorsFile.text())
        onFileChanged: colorsFile.reload()
        onLoadFailed: error => {
            return console.warn("fnx-oem-osd: DMS color cache unavailable; using fallback palette:", error);
        }
    }

    FileView {
        id: settingsFile

        path: StandardPaths.writableLocation(StandardPaths.ConfigLocation) + "/DankMaterialShell/settings.json"
        blockLoading: false
        watchChanges: true
        onLoaded: root.parseSettings(settingsFile.text())
        onFileChanged: settingsFile.reload()
        onLoadFailed: error => {
            return console.warn("fnx-oem-osd: DMS settings unavailable; using fallback typography:", error);
        }
    }

    FileView {
        id: sessionFile

        path: StandardPaths.writableLocation(StandardPaths.GenericStateLocation) + "/DankMaterialShell/session.json"
        blockLoading: false
        watchChanges: true
        onLoaded: root.parseSession(sessionFile.text())
        onFileChanged: sessionFile.reload()
        onLoadFailed: error => {
            return console.warn("fnx-oem-osd: DMS session unavailable; using dark palette:", error);
        }
    }

    Timer {
        id: hideTimer

        interval: root.hideAfterMs
        repeat: false
        onTriggered: root.hide()
    }

    Timer {
        id: closeTimer

        interval: root.animationDuration + 40
        repeat: false
        onTriggered: {
            if (!root.shouldBeVisible)
                root.visible = false;
        }
    }

    Item {
        id: card

        anchors.centerIn: parent
        width: 264
        height: 66
        opacity: root.shouldBeVisible ? 1 : 0
        scale: root.shouldBeVisible ? 1 : 0.94
        y: root.shouldBeVisible ? 0 : 5

        Rectangle {
            anchors.fill: parent
            radius: Math.min(root.themeCornerRadius, height / 2)
            color: root.surfaceColor
            border.color: root.outlineColor
            border.width: 1
        }

        Row {
            spacing: 12

            anchors {
                fill: parent
                leftMargin: 12
                rightMargin: 16
                topMargin: 12
                bottomMargin: 12
            }

            Rectangle {
                width: 42
                height: 42
                radius: 14
                color: root.accentColor

                Item {
                    anchors.centerIn: parent
                    width: 24
                    height: 22

                    Row {
                        id: modeIcon

                        x: 2
                        width: 19
                        height: parent.height
                        spacing: 3
                        visible: root.currentFeature === "performance-mode"

                        Repeater {
                            model: 3

                            Rectangle {
                                required property int index

                                y: parent.height - height
                                width: 4
                                height: root.barHeightFor(root.currentEvent, index)
                                radius: 2
                                color: root.accentForegroundColor

                                Behavior on height {
                                    NumberAnimation {
                                        duration: root.animationDuration
                                        easing.type: Easing.OutCubic
                                    }
                                }
                            }
                        }
                    }

                    Item {
                        id: keyboardIcon

                        anchors.fill: parent
                        visible: root.currentFeature === "keyboard-backlight"

                        Rectangle {
                            x: 1
                            y: 3
                            width: 22
                            height: 14
                            radius: 3
                            color: "transparent"
                            border.color: root.accentForegroundColor
                            border.width: 2
                        }

                        Row {
                            x: 5
                            y: 7
                            spacing: 2

                            Repeater {
                                model: 4

                                Rectangle {
                                    width: 2
                                    height: 3
                                    radius: 1
                                    color: root.accentForegroundColor
                                }
                            }
                        }

                        Rectangle {
                            anchors.horizontalCenter: parent.horizontalCenter
                            y: 20
                            width: root.keyboardGlowWidthFor(root.currentEvent)
                            height: 2
                            radius: 1
                            color: root.accentForegroundColor

                            Behavior on width {
                                NumberAnimation {
                                    duration: root.animationDuration
                                    easing.type: Easing.OutCubic
                                }
                            }
                        }
                    }

                    Item {
                        id: touchpadIcon

                        anchors.centerIn: parent
                        width: 19
                        height: 22
                        visible: root.currentFeature === "touchpad"

                        Rectangle {
                            anchors.fill: parent
                            radius: 3
                            color: "transparent"
                            border.color: root.accentForegroundColor
                            border.width: 2
                        }

                        Rectangle {
                            x: 3
                            y: 15
                            width: 13
                            height: 1
                            color: root.accentForegroundColor
                        }

                        Rectangle {
                            anchors.centerIn: parent
                            width: 2
                            height: 25
                            radius: 1
                            rotation: -42
                            color: root.accentForegroundColor
                            visible: root.currentEvent === "touchpad-off"
                        }
                    }
                }

                Behavior on color {
                    ColorAnimation {
                        duration: root.animationDuration
                    }
                }
            }

            Column {
                anchors.verticalCenter: parent.verticalCenter
                spacing: 1

                Text {
                    text: root.featureLabel
                    color: root.surfaceMutedColor
                    font.family: root.themeFontFamily
                    font.pixelSize: Math.round(11 * root.themeFontScale)
                    font.weight: root.themeFontWeight
                    font.letterSpacing: 0.35
                }

                Text {
                    text: root.eventLabel
                    color: root.surfaceForegroundColor
                    font.family: root.themeFontFamily
                    font.pixelSize: Math.round(17 * root.themeFontScale)
                    font.weight: Math.max(root.themeFontWeight, Font.DemiBold)
                }
            }
        }

        Behavior on opacity {
            NumberAnimation {
                duration: root.animationDuration
                easing.type: root.shouldBeVisible ? Easing.OutCubic : Easing.InCubic
            }
        }

        Behavior on scale {
            NumberAnimation {
                duration: root.animationDuration
                easing.type: Easing.OutCubic
            }
        }

        Behavior on y {
            NumberAnimation {
                duration: root.animationDuration
                easing.type: Easing.OutCubic
            }
        }
    }

    // An empty input region lets pointer events pass through to clients
    // underneath the OSD instead of making this display-only surface a dead
    // zone while it is visible.
    mask: Region {}
}
