pragma ComponentBehavior: Bound

// fnx-oem-osd — standalone Quickshell OSD reached via Quickshell IPC.
// Run it with:   qs -p <this-directory>
// Then:          qs -p <this-directory> ipc call fnx-oem-osd showPerformance
// The OSD is display-only: no keyboard focus, no pointer capture, no
// exclusive zone reservation. Microphone and airplane states are shown only
// after the listener has performed the request and read the state back. Display labels follow the system locale; IPC
// event tokens remain stable English identifiers.

import QtCore
import QtQuick
import QtQuick.Effects
import QtQuick.Shapes
import Quickshell
import Quickshell.Io
import Quickshell.Wayland

PanelWindow {
    id: root

    // Native glyph rasterisation while stationary; distance-field rendering while
    // the item or any ancestor is scaled or rotated, so the card's 0.9 -> 1
    // entrance does not make the labels shimmer. Bindings that call this
    // re-evaluate when any ancestor's scale/rotation changes.
    function textRenderType(item: Item): int {
        return root.isTransformed(item) ? Text.QtRendering : Text.NativeRendering;
    }

    function isTransformed(item: Item): bool {
        if (!item)
            return false;
        return item.scale !== 1 || item.rotation !== 0 || root.isTransformed(item.parent);
    }

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
    // Fallbacks mirror the current matugen scheme from DMS's dms-colors.json.
    readonly property var fallbackDark: ({
            "surface": "#11140e",
            "surface_container_high": "#282b24",
            "surface_container_highest": "#33362e",
            "on_surface": "#e2e3d9",
            "on_surface_variant": "#c4c8ba",
            "primary": "#aed18d",
            "primary_container": "#324e18",
            "on_primary_container": "#caeea6",
            "secondary_container": "#3f4a34",
            "on_secondary_container": "#dae7c9",
            "tertiary": "#f1bc96",
            "tertiary_container": "#1e4e4c",
            "on_tertiary_container": "#bbece9",
            "outline": "#8e9286",
            "outline_variant": "#44483e"
        })
    readonly property var fallbackLight: ({
            "surface": "#f9faef",
            "surface_container_high": "#e7e9de",
            "surface_container_highest": "#e2e3d9",
            "on_surface": "#1a1d16",
            "on_surface_variant": "#44483e",
            "primary": "#49672e",
            "primary_container": "#caeea6",
            "on_primary_container": "#0d2000",
            "secondary_container": "#dae7c9",
            "on_secondary_container": "#151e0c",
            "tertiary": "#7e5537",
            "tertiary_container": "#bbece9",
            "on_tertiary_container": "#00201f",
            "outline": "#74796d",
            "outline_variant": "#c4c8ba"
        })
    readonly property var fallbackColors: root.isLightMode ? root.fallbackLight : root.fallbackDark
    readonly property var activeColors: {
        const variants = root.matugenData && root.matugenData.colors;
        const selected = variants && variants[root.isLightMode ? "light" : "dark"];
        return selected || root.fallbackColors;
    }
    // Frost tier needs both a valid DMS colour cache and compositor blur that
    // DMS reports as supported and enabled; otherwise the card stays opaque.
    property bool blurSupported: false
    readonly property bool hasDmsColors: Boolean(root.matugenData && root.matugenData.colors)
    readonly property bool frostActive: root.hasDmsColors && root.blurSupported && root.dmsSettings.blurEnabled === true
    readonly property color surfaceColor: root.frostActive ? Qt.alpha(root.colorOrFallback("surface"), 0.9) : root.colorOrFallback("surface_container_high")
    readonly property color surfaceForegroundColor: root.colorOrFallback("on_surface")
    readonly property color surfaceMutedColor: root.colorOrFallback("on_surface_variant")
    readonly property color outlineColor: Qt.alpha(root.colorOrFallback("outline"), 0.35)
    // Directional rim lit from 233 degrees (y-down): upper-left edges at 22%,
    // lower-right at 65% of that.
    readonly property color rimLitColor: Qt.alpha(root.colorOrFallback("on_surface"), 0.22)
    readonly property color rimShadeColor: Qt.alpha(root.colorOrFallback("on_surface"), 0.143)
    // The glyph sits directly on the glass and carries the state in its colour.
    readonly property color glyphColor: {
        switch (root.currentEvent) {
        case "performance":
        case "keyboard-backlight-high":
            return root.colorOrFallback("primary");
        case "balanced":
        case "touchpad-on":
        case "microphone-on":
        case "airplane-off":
        case "keyboard-backlight-low":
            return root.colorOrFallback("tertiary");
        default:
            return root.colorOrFallback("on_surface_variant");
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
        case "microphone-muted":
        case "microphone-on":
        case "airplane-on":
        case "airplane-off":
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
        case "microphone-muted":
        case "microphone-on":
            return "microphone";
        case "airplane-on":
        case "airplane-off":
            return "airplane-mode";
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
        case "microphone":
            return root.useChinese ? "Fn+F7 · 麥克風" : "Fn+F7 · Microphone";
        case "airplane-mode":
            return root.useChinese ? "Fn+F9 · 飛航模式" : "Fn+F9 · Airplane mode";
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
        case "microphone-muted":
            return root.useChinese ? "麥克風已靜音" : "Microphone muted";
        case "microphone-on":
            return root.useChinese ? "麥克風已開啟" : "Microphone on";
        case "airplane-on":
            return root.useChinese ? "飛航模式開啟" : "Airplane mode on";
        case "airplane-off":
            return root.useChinese ? "飛航模式關閉" : "Airplane mode off";
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
    BackgroundEffect.blurRegion: root.frostActive ? blurRegion : null

    Region {
        id: blurRegion

        // Follow the card's entrance/exit animation: scale with it and slide
        // with it. Opacity is kept near 1 whenever the region is non-empty
        // (fast fade-in, late fade-out), so compositor blur (which cannot fade)
        // stays covered by the tinted card. Positions are taken from the
        // card's centre because the card is anchored, so card.y is already
        // absolute.
        readonly property real s: card.scale
        readonly property real w: card.width * s
        readonly property real h: card.height * s

        x: card.x + (card.width - w) / 2
        y: card.y + (card.height - h) / 2
        width: Math.max(0, w)
        height: Math.max(0, h)
        radius: Math.min(card.radius * s, h / 2)
    }

    // Same probe DMS uses for ext-background-effect-v1. A missing `dms`
    // binary or any other answer keeps the opaque fallback.
    Process {
        id: blurProbe

        command: ["dms", "blur", "check"]
        running: true

        stdout: StdioCollector {
            onStreamFinished: root.blurSupported = text.trim() === "supported"
        }
    }

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

        function showMicMuted(): string {
            return root.showEvent("microphone-muted");
        }

        function showMicOn(): string {
            return root.showEvent("microphone-on");
        }

        function showAirplaneOn(): string {
            return root.showEvent("airplane-on");
        }

        function showAirplaneOff(): string {
            return root.showEvent("airplane-off");
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
        readonly property real radius: Math.min(root.themeCornerRadius, height / 2)
        readonly property real rimWidth: 1.5

        width: 264
        height: 66
        opacity: root.shouldBeVisible ? 1 : 0
        scale: root.shouldBeVisible ? 1 : 0.9
        anchors.verticalCenterOffset: root.shouldBeVisible ? 0 : 5

        Rectangle {
            anchors.fill: parent
            radius: card.radius
            color: root.surfaceColor
            border.color: root.outlineColor
            border.width: 1
        }

        // Inner highlight ring just inside the 1 px border: an odd-even fill
        // between two rounded rectangles, shaded along the light direction.
        Shape {
            anchors.fill: parent
            anchors.margins: 1
            preferredRendererType: Shape.CurveRenderer
            visible: root.frostActive

            ShapePath {
                id: rimPath

                readonly property real w: card.width - 2
                readonly property real h: card.height - 2
                readonly property real r: Math.max(0, card.radius - 1)
                readonly property real t: card.rimWidth
                readonly property real ir: Math.max(0, r - t)

                strokeColor: "transparent"
                fillRule: ShapePath.OddEvenFill
                fillGradient: LinearGradient {
                    // 233 degrees y-down points up-left: (cos, sin) = (-0.60, -0.80).
                    x1: rimPath.w / 2 - 0.6 * rimPath.w / 2
                    y1: rimPath.h / 2 - 0.8 * rimPath.h / 2
                    x2: rimPath.w / 2 + 0.6 * rimPath.w / 2
                    y2: rimPath.h / 2 + 0.8 * rimPath.h / 2

                    GradientStop {
                        position: 0
                        color: root.rimLitColor
                    }

                    GradientStop {
                        position: 1
                        color: root.rimShadeColor
                    }
                }

                PathRectangle {
                    width: rimPath.w
                    height: rimPath.h
                    radius: rimPath.r
                }

                PathRectangle {
                    x: rimPath.t
                    y: rimPath.t
                    width: rimPath.w - 2 * rimPath.t
                    height: rimPath.h - 2 * rimPath.t
                    radius: rimPath.ir
                }
            }
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

            Item {
                width: 42
                height: 42

                Item {
                    anchors.centerIn: parent
                    width: 24
                    height: 22
                    // Render glyphs at 28 px without touching their path coordinates.
                    scale: 28 / 24
                    transformOrigin: Item.Center

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
                                color: root.glyphColor

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
                            border.color: root.glyphColor
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
                                    color: root.glyphColor
                                }
                            }
                        }

                        Rectangle {
                            anchors.horizontalCenter: parent.horizontalCenter
                            y: 20
                            width: root.keyboardGlowWidthFor(root.currentEvent)
                            height: 2
                            radius: 1
                            color: root.glyphColor

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
                        width: 24
                        height: 24
                        visible: root.currentFeature === "touchpad"

                        Item {
                            id: touchpadGlyph

                            anchors.fill: parent
                            layer.enabled: root.currentEvent === "touchpad-off"
                            layer.effect: MultiEffect {
                                maskEnabled: true
                                maskSource: slashCutMask
                                maskInverted: true
                                maskThresholdMin: 0.5
                                maskSpreadAtMin: 0.0
                                maskThresholdMax: 1.0
                                maskSpreadAtMax: 0.0
                            }

                            Rectangle {
                                anchors.centerIn: parent
                                width: 23
                                height: 17
                                radius: 3
                                color: "transparent"
                                border.color: root.glyphColor
                                border.width: 2

                                Rectangle {
                                    anchors.horizontalCenter: parent.horizontalCenter
                                    y: 11
                                    width: parent.width - 4
                                    height: 1
                                    color: root.glyphColor
                                }
                            }
                        }

                        Shape {
                            anchors.fill: parent
                            preferredRendererType: Shape.CurveRenderer
                            visible: root.currentEvent === "touchpad-off"

                            ShapePath {
                                strokeColor: root.glyphColor
                                strokeWidth: 2
                                fillColor: "transparent"
                                capStyle: ShapePath.RoundCap
                                startX: 4
                                startY: 3
                                PathLine {
                                    x: 20
                                    y: 21
                                }
                            }
                        }
                    }

                    Item {
                        id: microphoneIcon

                        anchors.centerIn: parent
                        width: 24
                        height: 24
                        visible: root.currentFeature === "microphone"

                        Shape {
                            id: microphoneGlyph

                            anchors.fill: parent
                            preferredRendererType: Shape.CurveRenderer
                            layer.enabled: root.currentEvent === "microphone-muted"
                            layer.effect: MultiEffect {
                                maskEnabled: true
                                maskSource: slashCutMask
                                maskInverted: true
                                maskThresholdMin: 0.5
                                maskSpreadAtMin: 0.0
                                maskThresholdMax: 1.0
                                maskSpreadAtMax: 0.0
                            }

                            ShapePath {
                                strokeColor: "transparent"
                                fillColor: root.glyphColor

                                PathSvg {
                                    path: "M12 2.5 C13.66 2.5 15 3.84 15 5.5 L15 11 C15 12.66 13.66 14 12 14 C10.34 14 9 12.66 9 11 L9 5.5 C9 3.84 10.34 2.5 12 2.5 Z"
                                }
                            }

                            ShapePath {
                                strokeColor: root.glyphColor
                                strokeWidth: 2
                                fillColor: "transparent"
                                capStyle: ShapePath.RoundCap

                                PathSvg {
                                    path: "M6.5 10.5 C6.5 13.8 9 16.5 12 16.5 C15 16.5 17.5 13.8 17.5 10.5 M12 16.5 L12 20.5 M9 20.5 L15 20.5"
                                }
                            }
                        }

                        Shape {
                            anchors.fill: parent
                            preferredRendererType: Shape.CurveRenderer
                            visible: root.currentEvent === "microphone-muted"

                            ShapePath {
                                strokeColor: root.glyphColor
                                strokeWidth: 2
                                fillColor: "transparent"
                                capStyle: ShapePath.RoundCap
                                startX: 4
                                startY: 3
                                PathLine {
                                    x: 20
                                    y: 21
                                }
                            }
                        }
                    }

                    Item {
                        id: airplaneIcon

                        anchors.centerIn: parent
                        width: 24
                        height: 24
                        visible: root.currentFeature === "airplane-mode"

                        Shape {
                            id: airplaneGlyph

                            anchors.fill: parent
                            preferredRendererType: Shape.CurveRenderer
                            layer.enabled: root.currentEvent === "airplane-off"
                            layer.effect: MultiEffect {
                                maskEnabled: true
                                maskSource: slashCutMask
                                maskInverted: true
                                maskThresholdMin: 0.5
                                maskSpreadAtMin: 0.0
                                maskThresholdMax: 1.0
                                maskSpreadAtMax: 0.0
                            }

                            ShapePath {
                                strokeColor: "transparent"
                                fillColor: root.glyphColor

                                PathSvg {
                                    path: "M12 2 C12.9 2 13.5 2.9 13.5 4 L13.5 9.3 L21 13.6 L21 15.6 L13.5 13.4 L13.5 18 L16 19.8 L16 21.5 L12 20.4 L8 21.5 L8 19.8 L10.5 18 L10.5 13.4 L3 15.6 L3 13.6 L10.5 9.3 L10.5 4 C10.5 2.9 11.1 2 12 2 Z"
                                }
                            }
                        }

                        Shape {
                            anchors.fill: parent
                            preferredRendererType: Shape.CurveRenderer
                            visible: root.currentEvent === "airplane-off"

                            ShapePath {
                                strokeColor: root.glyphColor
                                strokeWidth: 2
                                fillColor: "transparent"
                                capStyle: ShapePath.RoundCap
                                startX: 4
                                startY: 3
                                PathLine {
                                    x: 20
                                    y: 21
                                }
                            }
                        }
                    }

                    // Thick slash used as an inverted mask to cut the slashed glyphs.
                    Shape {
                        id: slashCutMask

                        width: 24
                        height: 24
                        visible: false
                        layer.enabled: true
                        preferredRendererType: Shape.CurveRenderer

                        ShapePath {
                            strokeColor: "white"
                            strokeWidth: 6
                            fillColor: "transparent"
                            capStyle: ShapePath.RoundCap
                            startX: 4
                            startY: 3
                            PathLine {
                                x: 20
                                y: 21
                            }
                        }
                    }
                }
            }

            Column {
                anchors.verticalCenter: parent.verticalCenter
                spacing: 1

                Text {
                    id: featureText

                    text: root.featureLabel
                    renderType: root.textRenderType(featureText)
                    color: root.surfaceMutedColor
                    font.family: root.themeFontFamily
                    font.pixelSize: Math.round(11 * root.themeFontScale)
                    font.weight: root.themeFontWeight
                    font.letterSpacing: 0.35
                }

                Text {
                    id: eventText

                    text: root.eventLabel
                    renderType: root.textRenderType(eventText)
                    color: root.surfaceForegroundColor
                    font.family: root.themeFontFamily
                    font.pixelSize: Math.round(17 * root.themeFontScale)
                    font.weight: Math.max(root.themeFontWeight, Font.DemiBold)
                }
            }
        }

        // Key on the Behavior's own target: a shouldBeVisible binding here can
        // still hold the previous direction when the animation starts.
        Behavior on opacity {
            id: opacityBehavior

            NumberAnimation {
                duration: opacityBehavior.targetValue > 0.5 ? 60 : root.animationDuration
                easing.type: opacityBehavior.targetValue > 0.5 ? Easing.OutCubic : Easing.InExpo
            }
        }

        Behavior on scale {
            NumberAnimation {
                duration: root.animationDuration
                easing.type: Easing.OutCubic
            }
        }

        Behavior on anchors.verticalCenterOffset {
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
