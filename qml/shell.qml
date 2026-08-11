// fnx-oem-osd — standalone Quickshell OSD reached via Quickshell IPC.
// Run it with:   qs -p <this-directory>
// Then:          qs -p <this-directory> ipc call fnx-oem-osd showPerformance
// The OSD is display-only: no keyboard focus, no pointer capture, no
// exclusive zone reservation. Display labels follow the system locale; IPC
// mode tokens remain stable English identifiers.

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
    property string currentMode: "unknown"
    property string modeLabel: ""
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
        switch (root.currentMode) {
        case "performance":
            return root.colorOrFallback("primary_container");
        case "balanced":
            return root.colorOrFallback("tertiary_container");
        default:
            return root.colorOrFallback("secondary_container");
        }
    }
    readonly property color accentForegroundColor: {
        switch (root.currentMode) {
        case "performance":
            return root.colorOrFallback("on_primary_container");
        case "balanced":
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

    function labelForMode(mode: string): string {
        switch (mode) {
        case "performance":
            return root.useChinese ? "性能模式" : "Performance mode";
        case "balanced":
            return root.useChinese ? "均衡模式" : "Balanced mode";
        default:
            // Compatibility fallback for direct/manual IPC callers. The
            // production listener maps both admitted scancodes to named modes.
            return root.useChinese ? "OEM 模式已切換" : "OEM mode switched";
        }
    }

    function barHeightFor(mode: string, index: int): real {
        if (mode === "performance")
            return [8, 14, 20][index];

        if (mode === "balanced")
            return [11, 17, 11][index];

        return 5;
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

    function showMode(mode: string): string {
        if (mode !== "performance" && mode !== "balanced" && mode !== "unknown") {
            console.warn(`fnx-oem-osd: rejected mode '${mode}'`);
            return "FNX_OSD_SHOW_REJECTED_INVALID_MODE";
        }
        root.currentMode = mode;
        root.modeLabel = root.labelForMode(mode);
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
    WlrLayershell.layer: WlrLayershell.Overlay
    WlrLayershell.exclusiveZone: -1
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.None

    IpcHandler {
        function show(mode: string): string {
            return root.showMode(mode);
        }

        // noctalia-qs 0.0.12 rejects arguments on the new `ipc call` CLI.
        // These wrappers keep the typed central handler while providing a
        // zero-argument production path that works with `ipc call`.
        function showPerformance(): string {
            return root.showMode("performance");
        }

        function showBalanced(): string {
            return root.showMode("balanced");
        }

        function showUnknown(): string {
            return root.showMode("unknown");
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
                    width: 19
                    height: 22

                    Row {
                        anchors.fill: parent
                        spacing: 3

                        Repeater {
                            model: 3

                            Rectangle {
                                required property int index

                                y: parent.height - height
                                width: 4
                                height: root.barHeightFor(root.currentMode, index)
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
                    text: "Fn+X · OEM"
                    color: root.surfaceMutedColor
                    font.family: root.themeFontFamily
                    font.pixelSize: Math.round(11 * root.themeFontScale)
                    font.weight: root.themeFontWeight
                    font.letterSpacing: 0.35
                }

                Text {
                    text: root.modeLabel
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
