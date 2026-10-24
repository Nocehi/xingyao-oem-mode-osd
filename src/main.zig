//! fnx-oem-osd-listener
//!
//! Observes the systemd journal for the supported P916F-STX OEM-key ACPI WMI
//! notifications and drives the standalone Quickshell OSD through Quickshell
//! IPC.
//!
//! Design rules (see README.md for the full evidence chain):
//!   * No evdev listener, key grab, key injection, udev/hwdb remap or
//!     niri/keyd binding: on the calibrated host, the huawei-wmi path was
//!     observed logging the scancode without a usable input event. The
//!     journal is the deliberately retained event surface.
//!   * Native libsystemd journal API only; no `journalctl`, no file polling.
//!   * Startup seeks to the journal tail; only later entries are consumed.
//!   * Strict admission: kernel transport + kernel identifier + input
//!     subsystem + the dynamically resolved `Huawei WMI hotkeys` input device
//!     + exact message whose `inputN` agrees with that device and whose code is
//!     one of the seven display-only codes calibrated on this board, or one of
//!     the two OEM request codes below. The `N` in `inputN` is never
//!     hard-coded.
//!   * Fail-closed hardware preflight for the calibrated P916F-STX DMI, WMI
//!     GUID pair, huawei-wmi platform path, and input-device identity.
//!   * Exact-event monotonic debounce against duplicate WMI notifications.
//!   * Each admitted scancode maps directly to a typed state already formed by
//!     firmware/EC: keyboard backlight off/low/high, touchpad off/on, or OEM
//!     balanced/performance mode. For those codes the listener has no seed or
//!     toggle state and never performs the hardware action.
//!   * Two request codes (Fn+F7 microphone, Fn+F9 airplane mode) are not
//!     acted on by firmware; on Windows the OEM service performs the action.
//!     The listener performs the equivalent Linux action (PipeWire default
//!     source mute through `wpctl`, global rfkill through `/dev/rfkill`) and
//!     displays only the state read back afterwards, never a guessed state.
//!   * Quickshell IPC is invoked without a shell (argv-only) and its exit
//!     status is checked; a failure is reported, never claimed as shown.

const std = @import("std");
const jl = @import("c");

pub const version = "0.3.0-dev";

pub const default_debounce_ms: u64 = 250;
pub const default_wait_usec: u64 = 1_000_000; // journal wait wakeup, 1s
pub const exit_unsupported_hardware: u8 = 77;
pub const exit_runtime_unavailable: u8 = 78;

pub const PreflightOutcome = enum {
    passed,
    unsupported_hardware,
    runtime_unavailable,
    internal_error,
};

pub const RuntimeProbeResult = enum {
    ready,
    unavailable,
    internal_error,
};

/// One status contract is shared by the production preflight and the
/// deterministic fixture runner. A fixture never invents a second mapping.
pub fn preflightExitStatus(outcome: PreflightOutcome) u8 {
    return switch (outcome) {
        .passed => 0,
        .unsupported_hardware => exit_unsupported_hardware,
        .runtime_unavailable => exit_runtime_unavailable,
        .internal_error => 1,
    };
}

/// Production journal branches and the fixture runner share this decision.
/// The fixture supplies a deterministic observation; it does not supply an
/// exit status.
pub fn runtimePreflightOutcome(result: RuntimeProbeResult) PreflightOutcome {
    return switch (result) {
        .ready => .passed,
        .unavailable => .runtime_unavailable,
        .internal_error => .internal_error,
    };
}

// These are identity gates, not a compatibility database. They encode only
// the hardware and WMI path on which the scancode mapping was calibrated.
pub const SupportedSystemVendor = "MECHREVO";
pub const SupportedBoardName = "XINGYAO Series-P916F-STX";
pub const SupportedEventGuid = "ABBC0F5B-8EA1-11D1-A000-C90629100000";
pub const SupportedMethodGuid = "ABBC0F5C-8EA1-11D1-A000-C90629100000";
pub const SupportedInputName = "Huawei WMI hotkeys";

const DmiVendorPath = "sys/class/dmi/id/sys_vendor";
const DmiBoardPath = "sys/class/dmi/id/board_name";
const WmiDevicesPath = "sys/bus/wmi/devices";
const HuaweiInputPath = "sys/devices/platform/huawei-wmi/input";

// ---------------------------------------------------------------------------
// Typed OEM display events. This closed enum is the only production mapping
// from an admitted code to semantic state and from semantic state to IPC.
// ---------------------------------------------------------------------------

pub const OemFeature = enum {
    performance_mode,
    keyboard_backlight,
    touchpad,
};

pub const OemEvent = enum {
    mode_balanced,
    mode_performance,
    keyboard_backlight_off,
    keyboard_backlight_low,
    keyboard_backlight_high,
    touchpad_off,
    touchpad_on,

    pub fn token(event: OemEvent) []const u8 {
        return switch (event) {
            .mode_balanced => "balanced",
            .mode_performance => "performance",
            .keyboard_backlight_off => "keyboard-backlight-off",
            .keyboard_backlight_low => "keyboard-backlight-low",
            .keyboard_backlight_high => "keyboard-backlight-high",
            .touchpad_off => "touchpad-off",
            .touchpad_on => "touchpad-on",
        };
    }

    pub fn feature(event: OemEvent) OemFeature {
        return switch (event) {
            .mode_balanced, .mode_performance => .performance_mode,
            .keyboard_backlight_off, .keyboard_backlight_low, .keyboard_backlight_high => .keyboard_backlight,
            .touchpad_off, .touchpad_on => .touchpad,
        };
    }

    pub fn scancode(event: OemEvent) []const u8 {
        return switch (event) {
            .keyboard_backlight_off => "0x0020",
            .keyboard_backlight_low => "0x0021",
            .keyboard_backlight_high => "0x0022",
            .touchpad_off => "0x0030",
            .touchpad_on => "0x0031",
            .mode_balanced => "0x0041",
            .mode_performance => "0x0042",
        };
    }

    pub fn ipcFunction(event: OemEvent) []const u8 {
        return switch (event) {
            .mode_balanced => "showBalanced",
            .mode_performance => "showPerformance",
            .keyboard_backlight_off => "showKeyboardOff",
            .keyboard_backlight_low => "showKeyboardLow",
            .keyboard_backlight_high => "showKeyboardHigh",
            .touchpad_off => "showTouchpadOff",
            .touchpad_on => "showTouchpadOn",
        };
    }
};

// ---------------------------------------------------------------------------
// OEM request keys. Firmware forms no state for these codes; the listener
// performs the Linux action and displays only the state read back afterwards.
// ---------------------------------------------------------------------------

pub const OemRequest = enum {
    microphone_toggle,
    airplane_toggle,

    pub fn token(request: OemRequest) []const u8 {
        return switch (request) {
            .microphone_toggle => "microphone-toggle",
            .airplane_toggle => "airplane-toggle",
        };
    }

    pub fn scancode(request: OemRequest) []const u8 {
        return switch (request) {
            .microphone_toggle => "0x00a1",
            .airplane_toggle => "0x00a0",
        };
    }
};

/// The state read back after a request action. Only this read-back state is
/// ever displayed.
pub const RequestOutcome = enum {
    microphone_muted,
    microphone_on,
    airplane_on,
    airplane_off,

    pub fn token(outcome: RequestOutcome) []const u8 {
        return switch (outcome) {
            .microphone_muted => "microphone-muted",
            .microphone_on => "microphone-on",
            .airplane_on => "airplane-on",
            .airplane_off => "airplane-off",
        };
    }

    pub fn ipcFunction(outcome: RequestOutcome) []const u8 {
        return switch (outcome) {
            .microphone_muted => "showMicMuted",
            .microphone_on => "showMicOn",
            .airplane_on => "showAirplaneOn",
            .airplane_off => "showAirplaneOff",
        };
    }
};

/// An admitted journal record is either a firmware-formed display event or a
/// request the listener must act on.
pub const Admitted = union(enum) {
    display: OemEvent,
    request: OemRequest,

    pub fn token(admitted: Admitted) []const u8 {
        return switch (admitted) {
            .display => |event| event.token(),
            .request => |request| request.token(),
        };
    }

    pub fn scancode(admitted: Admitted) []const u8 {
        return switch (admitted) {
            .display => |event| event.scancode(),
            .request => |request| request.scancode(),
        };
    }
};

// ---------------------------------------------------------------------------
// Strict journal admission.
// ---------------------------------------------------------------------------

pub const InputDevicePrefix = "+input:input";
pub const KernelDevicePrefix = "+input:";
pub const MessageDevicePrefix = "input ";
pub const UnknownKeyCodePrefix = ": Unknown key pressed, code: ";
pub const MaxKernelDeviceLen = 64;

/// Returns a calibrated display-only event only for the exact kernel/input
/// record shape captured on this host. All five fields must match.
pub fn eventForRecord(transport: []const u8, syslog_identifier: []const u8, kernel_subsystem: []const u8, kernel_device: []const u8, message: []const u8) ?OemEvent {
    if (!std.mem.eql(u8, transport, "kernel")) return null;
    if (!std.mem.eql(u8, syslog_identifier, "kernel")) return null;
    if (!std.mem.eql(u8, kernel_subsystem, "input")) return null;
    return eventForMessage(kernel_device, message);
}

pub fn isOemEventRecord(transport: []const u8, syslog_identifier: []const u8, kernel_subsystem: []const u8, kernel_device: []const u8, message: []const u8) bool {
    return eventForRecord(transport, syslog_identifier, kernel_subsystem, kernel_device, message) != null;
}

/// Returns the exact scancode text of a well-formed record. The `inputN` in
/// MESSAGE must be identical to `_KERNEL_DEVICE=+input:inputN`; this preserves
/// strict admission without hard-coding the current dynamic input number.
pub fn scancodeForMessage(kernel_device: []const u8, message: []const u8) ?[]const u8 {
    if (kernel_device.len > MaxKernelDeviceLen) return null;
    if (!isInputDevicePath(kernel_device)) return null;
    if (!std.mem.startsWith(u8, message, MessageDevicePrefix)) return null;

    const input_name = kernel_device[KernelDevicePrefix.len..];
    const after_prefix = message[MessageDevicePrefix.len..];
    if (!std.mem.startsWith(u8, after_prefix, input_name)) return null;

    const suffix = after_prefix[input_name.len..];
    if (!std.mem.startsWith(u8, suffix, UnknownKeyCodePrefix)) return null;
    return suffix[UnknownKeyCodePrefix.len..];
}

/// Accepts only the seven current-board display-only codes.
pub fn eventForMessage(kernel_device: []const u8, message: []const u8) ?OemEvent {
    return eventForScancode(scancodeForMessage(kernel_device, message) orelse return null);
}

/// Accepts the seven display-only codes and the two request codes.
pub fn admittedForMessage(kernel_device: []const u8, message: []const u8) ?Admitted {
    const code = scancodeForMessage(kernel_device, message) orelse return null;
    if (eventForScancode(code)) |event| return .{ .display = event };
    if (requestForScancode(code)) |request| return .{ .request = request };
    return null;
}

pub fn admittedForRecord(transport: []const u8, syslog_identifier: []const u8, kernel_subsystem: []const u8, kernel_device: []const u8, message: []const u8) ?Admitted {
    if (!std.mem.eql(u8, transport, "kernel")) return null;
    if (!std.mem.eql(u8, syslog_identifier, "kernel")) return null;
    if (!std.mem.eql(u8, kernel_subsystem, "input")) return null;
    return admittedForMessage(kernel_device, message);
}

pub fn requestForScancode(scancode: []const u8) ?OemRequest {
    inline for (std.enums.values(OemRequest)) |request| {
        if (std.mem.eql(u8, scancode, request.scancode())) return request;
    }
    return null;
}

pub fn eventForScancode(scancode: []const u8) ?OemEvent {
    inline for (std.enums.values(OemEvent)) |event| {
        if (std.mem.eql(u8, scancode, event.scancode())) return event;
    }
    return null;
}

/// Production admission adds the resolved huawei-wmi input identity to the
/// exact journal-record checks. Keeping this as a pure function makes the
/// fail-closed source gate testable without a physical OEM-key event.
pub fn eventForSupportedRecord(expected_kernel_device: []const u8, transport: []const u8, syslog_identifier: []const u8, kernel_subsystem: []const u8, kernel_device: []const u8, message: []const u8) ?OemEvent {
    if (!std.mem.eql(u8, expected_kernel_device, kernel_device)) return null;
    return eventForRecord(transport, syslog_identifier, kernel_subsystem, kernel_device, message);
}

/// Matches `+input:input` followed by one or more digits. The dynamic
/// `inputN` suffix is validated, never hard-coded.
pub fn isInputDevicePath(dev: []const u8) bool {
    if (dev.len < InputDevicePrefix.len + 1) return false;
    if (!std.mem.eql(u8, dev[0..InputDevicePrefix.len], InputDevicePrefix)) return false;
    for (dev[InputDevicePrefix.len..]) |c| {
        if (!std.ascii.isDigit(c)) return false;
    }
    return true;
}

/// Strip only the `FIELD=` prefix from raw sd_journal_get_data bytes. The API
/// does not append a presentation newline; a newline in the value is payload
/// and must remain visible to strict admission.
pub fn fieldValue(data: []const u8) []const u8 {
    const eq = std.mem.indexOfScalar(u8, data, '=') orelse return data;
    return data[eq + 1 ..];
}

// ---------------------------------------------------------------------------
// Calibrated hardware support gate.
// ---------------------------------------------------------------------------

pub const SupportProbe = struct {
    kernel_device_buffer: [MaxKernelDeviceLen]u8 = undefined,
    kernel_device_len: usize,

    pub fn kernelDevice(self: *const SupportProbe) []const u8 {
        return self.kernel_device_buffer[0..self.kernel_device_len];
    }
};

pub const SupportProbeError = error{
    UnsupportedSystemVendor,
    UnsupportedBoardName,
    MissingEventGuid,
    MissingMethodGuid,
    MissingHuaweiInput,
    AmbiguousHuaweiInput,
};

/// Expected identity mismatches are unsupported hardware. Filesystem, memory,
/// or other tool failures are internal errors and must not be disguised as an
/// ordinary unsupported result.
pub fn supportProbeFailureOutcome(err: anyerror) PreflightOutcome {
    return switch (err) {
        SupportProbeError.UnsupportedSystemVendor,
        SupportProbeError.UnsupportedBoardName,
        SupportProbeError.MissingEventGuid,
        SupportProbeError.MissingMethodGuid,
        SupportProbeError.MissingHuaweiInput,
        SupportProbeError.AmbiguousHuaweiInput,
        => .unsupported_hardware,
        else => .internal_error,
    };
}

/// A WMI sysfs device is the exact calibrated UUID plus a decimal instance
/// suffix (for example `...10000000-0`). UUID prefixes alone are not enough.
pub fn isWmiGuidInstance(name: []const u8, guid: []const u8) bool {
    if (name.len < guid.len + 2) return false;
    if (!std.mem.eql(u8, name[0..guid.len], guid)) return false;
    if (name[guid.len] != '-') return false;
    for (name[guid.len + 1 ..]) |c| {
        if (!std.ascii.isDigit(c)) return false;
    }
    return true;
}

fn readSysfsValue(alloc: std.mem.Allocator, io: std.Io, root: std.Io.Dir, path: []const u8) ![]u8 {
    const raw = try root.readFileAlloc(io, path, alloc, .limited(4096));
    defer alloc.free(raw);
    return alloc.dupe(u8, std.mem.trimEnd(u8, raw, "\r\n"));
}

fn hasWmiGuid(io: std.Io, root: std.Io.Dir, guid: []const u8) !bool {
    var devices = try root.openDir(io, WmiDevicesPath, .{ .iterate = true });
    defer devices.close(io);
    var iterator = devices.iterate();
    while (try iterator.next(io)) |entry| {
        switch (entry.kind) {
            .directory, .sym_link => {},
            else => continue,
        }
        if (!isWmiGuidInstance(entry.name, guid)) continue;
        var path_buffer: [WmiDevicesPath.len + 1 + SupportedEventGuid.len + 24]u8 = undefined;
        const device_path = std.fmt.bufPrint(&path_buffer, "{s}/{s}", .{ WmiDevicesPath, entry.name }) catch continue;
        var device_dir = root.openDir(io, device_path, .{}) catch |err| switch (err) {
            error.FileNotFound, error.NotDir => continue,
            else => return err,
        };
        device_dir.close(io);
        return true;
    }
    return false;
}

/// Probe a filesystem root for the exact calibrated identity and dynamically
/// resolve its huawei-wmi inputN. Production passes `/`; tests pass a fixture
/// root, so no test-only runtime bypass is exposed.
pub fn probeSupportedHardware(alloc: std.mem.Allocator, io: std.Io, root: std.Io.Dir) !SupportProbe {
    const vendor = try readSysfsValue(alloc, io, root, DmiVendorPath);
    defer alloc.free(vendor);
    if (!std.mem.eql(u8, vendor, SupportedSystemVendor)) return SupportProbeError.UnsupportedSystemVendor;

    const board = try readSysfsValue(alloc, io, root, DmiBoardPath);
    defer alloc.free(board);
    if (!std.mem.eql(u8, board, SupportedBoardName)) return SupportProbeError.UnsupportedBoardName;

    if (!try hasWmiGuid(io, root, SupportedEventGuid)) return SupportProbeError.MissingEventGuid;
    if (!try hasWmiGuid(io, root, SupportedMethodGuid)) return SupportProbeError.MissingMethodGuid;

    var input_dir = try root.openDir(io, HuaweiInputPath, .{ .iterate = true });
    defer input_dir.close(io);
    var iterator = input_dir.iterate();
    var result = SupportProbe{ .kernel_device_len = 0 };
    var found = false;
    while (try iterator.next(io)) |entry| {
        if (!isInputDeviceName(entry.name)) continue;
        const name_path = try std.fmt.allocPrint(alloc, "{s}/{s}/name", .{ HuaweiInputPath, entry.name });
        defer alloc.free(name_path);
        const input_name = readSysfsValue(alloc, io, root, name_path) catch |err| switch (err) {
            error.FileNotFound => continue,
            else => return err,
        };
        defer alloc.free(input_name);
        if (!std.mem.eql(u8, input_name, SupportedInputName)) continue;
        if (found) return SupportProbeError.AmbiguousHuaweiInput;
        const kernel_device = try std.fmt.bufPrint(&result.kernel_device_buffer, "+input:{s}", .{entry.name});
        result.kernel_device_len = kernel_device.len;
        found = true;
    }
    if (!found) return SupportProbeError.MissingHuaweiInput;
    return result;
}

fn isInputDeviceName(name: []const u8) bool {
    if (name.len < "input".len + 1) return false;
    if (!std.mem.startsWith(u8, name, "input")) return false;
    for (name["input".len..]) |c| {
        if (!std.ascii.isDigit(c)) return false;
    }
    return true;
}

fn supportFailureHint(err: anyerror) []const u8 {
    return switch (err) {
        SupportProbeError.UnsupportedSystemVendor => "DMI sys_vendor is not the calibrated MECHREVO value",
        SupportProbeError.UnsupportedBoardName => "DMI board_name is not the calibrated XINGYAO Series-P916F-STX value",
        SupportProbeError.MissingEventGuid => "calibrated ABBC0F5B WMI event GUID is missing",
        SupportProbeError.MissingMethodGuid => "calibrated ABBC0F5C WMI method GUID is missing",
        SupportProbeError.MissingHuaweiInput => "calibrated Huawei WMI hotkeys input device is missing",
        SupportProbeError.AmbiguousHuaweiInput => "more than one Huawei WMI hotkeys input device was found",
        else => "required DMI/WMI/sysfs evidence could not be read",
    };
}

// ---------------------------------------------------------------------------
// Monotonic debounce.
// ---------------------------------------------------------------------------

pub fn Debouncer(comptime Key: type) type {
    return struct {
        window_ns: u64,
        last_accept_ns: ?u64 = null,
        last_key: ?Key = null,

        /// Rejects only an identical semantic event inside the window. A
        /// distinct state or feature is a new report and must not be dropped.
        /// For a request this also prevents a duplicate WMI notification from
        /// toggling the state twice.
        pub fn accept(self: *@This(), key: Key, now_ns: u64) bool {
            if (self.last_accept_ns) |t| {
                if (self.last_key) |last| {
                    if (std.meta.eql(last, key) and now_ns -| t < self.window_ns) return false;
                }
            }
            self.last_accept_ns = now_ns;
            self.last_key = key;
            return true;
        }
    };
}

fn monotonicNanos() ?u64 {
    var ts: jl.struct_timespec = undefined;
    if (jl.clock_gettime(jl.CLOCK_MONOTONIC, &ts) != 0) return null;
    if (ts.tv_sec < 0 or ts.tv_nsec < 0) return null;
    return @as(u64, @intCast(ts.tv_sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.tv_nsec));
}

pub fn debounceWindowNanos(milliseconds: u64) !u64 {
    return std.math.mul(u64, milliseconds, std.time.ns_per_ms);
}

// ---------------------------------------------------------------------------
// IPC argv construction (no shell involved). OemEvent.ipcFunction() above is
// the one canonical semantic-event-to-QML mapping.
// ---------------------------------------------------------------------------

/// argv equivalent of:
/// qs -p <qml-config-path> ipc call fnx-oem-osd <zero-argument-wrapper>
///
/// noctalia-qs 0.0.12 rejects positional function arguments on `ipc call`
/// (exit 109), although its deprecated `msg` path accepts them. Zero-argument
/// wrappers retain the supported `ipc call` transport without relying on that
/// deprecated fallback.
pub fn ipcArgv(alloc: std.mem.Allocator, qs_bin: []const u8, qml_config: []const u8, function_name: []const u8) ![][]const u8 {
    return alloc.dupe([]const u8, &.{
        qs_bin,
        "-p",
        qml_config,
        "ipc",
        "call",
        "fnx-oem-osd",
        function_name,
    });
}

// ---------------------------------------------------------------------------
// Request actions. The pure parsing/decision functions are the test seam; the
// thin process and device wrappers perform the action.
// ---------------------------------------------------------------------------

pub const WpctlDefaultSource = "@DEFAULT_AUDIO_SOURCE@";

/// Parses `wpctl get-volume` output, for example `Volume: 1.00 [MUTED]`.
/// Anything other than one recognised line is not a readable state.
pub fn micMutedFromWpctl(output: []const u8) ?bool {
    const line = std.mem.trim(u8, output, " \t\r\n");
    if (!std.mem.startsWith(u8, line, "Volume: ")) return null;
    if (std.mem.indexOfAny(u8, line, "\r\n") != null) return null;
    return std.mem.endsWith(u8, line, " [MUTED]");
}

pub const RadioSummary = struct {
    total: usize = 0,
    /// Radios with neither a soft nor a hard block.
    enabled: usize = 0,
};

const RfkillClassPath = "sys/class/rfkill";

fn readBlockFlag(alloc: std.mem.Allocator, io: std.Io, root: std.Io.Dir, device: []const u8, attribute: []const u8) !bool {
    const path = try std.fmt.allocPrint(alloc, "{s}/{s}/{s}", .{ RfkillClassPath, device, attribute });
    defer alloc.free(path);
    const value = try readSysfsValue(alloc, io, root, path);
    defer alloc.free(value);
    if (std.mem.eql(u8, value, "0")) return false;
    if (std.mem.eql(u8, value, "1")) return true;
    return error.MalformedRfkillState;
}

/// Reads every `rfkillN` switch below a filesystem root. Production passes
/// `/`; tests pass a fixture root.
pub fn readRadioSummary(alloc: std.mem.Allocator, io: std.Io, root: std.Io.Dir) !RadioSummary {
    var summary = RadioSummary{};
    var class_dir = root.openDir(io, RfkillClassPath, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return summary,
        else => return err,
    };
    defer class_dir.close(io);
    var iterator = class_dir.iterate();
    while (try iterator.next(io)) |entry| {
        if (!std.mem.startsWith(u8, entry.name, "rfkill")) continue;
        const soft = try readBlockFlag(alloc, io, root, entry.name, "soft");
        const hard = try readBlockFlag(alloc, io, root, entry.name, "hard");
        summary.total += 1;
        if (!soft and !hard) summary.enabled += 1;
    }
    return summary;
}

/// Windows-like airplane toggle: while any radio is enabled, block all;
/// otherwise unblock all. Returns the soft-block target, or null without radios.
pub fn airplaneBlockTarget(summary: RadioSummary) ?bool {
    if (summary.total == 0) return null;
    return summary.enabled > 0;
}

/// Airplane mode is on exactly when no radio is enabled.
pub fn airplaneOutcome(summary: RadioSummary) ?RequestOutcome {
    if (summary.total == 0) return null;
    return if (summary.enabled == 0) .airplane_on else .airplane_off;
}

/// `struct rfkill_event` (RFKILL_EVENT_SIZE_V1, linux/rfkill.h): idx u32,
/// type u8, op u8, soft u8, hard u8. RFKILL_TYPE_ALL is 0 and
/// RFKILL_OP_CHANGE_ALL is 3.
pub fn rfkillChangeAllEvent(block: bool) [8]u8 {
    return .{ 0, 0, 0, 0, 0, 3, @intFromBool(block), 0 };
}

fn writeRfkillChangeAll(block: bool) !void {
    const linux = std.os.linux;
    const open_rc = linux.open("/dev/rfkill", .{ .ACCMODE = .WRONLY, .CLOEXEC = true }, 0);
    if (linux.errno(open_rc) != .SUCCESS) return error.RfkillOpenFailed;
    const fd: i32 = @intCast(open_rc);
    defer _ = linux.close(fd);
    const event = rfkillChangeAllEvent(block);
    const write_rc = linux.write(fd, &event, event.len);
    if (linux.errno(write_rc) != .SUCCESS or write_rc != event.len) return error.RfkillWriteFailed;
}

/// Runs a tool without a shell and returns its stdout on exit 0.
fn runTool(gpa: std.mem.Allocator, io: std.Io, argv: []const []const u8) ![]u8 {
    const res = try std.process.run(gpa, io, .{
        .argv = argv,
        .stdout_limit = .limited(16 * 1024),
        .stderr_limit = .limited(16 * 1024),
    });
    defer gpa.free(res.stderr);
    switch (res.term) {
        .exited => |code| if (code == 0) return res.stdout,
        else => {},
    }
    gpa.free(res.stdout);
    std.debug.print("fnx-oem-osd-listener: {s} {s} failed ({s}). stderr: {s}\n", .{ argv[0], argv[1], @tagName(res.term), std.mem.trim(u8, res.stderr, " \t\r\n") });
    return error.ToolFailed;
}

fn performRequest(gpa: std.mem.Allocator, io: std.Io, root: std.Io.Dir, wpctl_bin: []const u8, request: OemRequest) !RequestOutcome {
    switch (request) {
        .microphone_toggle => {
            gpa.free(try runTool(gpa, io, &.{ wpctl_bin, "set-mute", WpctlDefaultSource, "toggle" }));
            const output = try runTool(gpa, io, &.{ wpctl_bin, "get-volume", WpctlDefaultSource });
            defer gpa.free(output);
            const muted = micMutedFromWpctl(output) orelse return error.UnrecognizedWpctlOutput;
            return if (muted) .microphone_muted else .microphone_on;
        },
        .airplane_toggle => {
            const block = airplaneBlockTarget(try readRadioSummary(gpa, io, root)) orelse return error.NoRadios;
            try writeRfkillChangeAll(block);
            return airplaneOutcome(try readRadioSummary(gpa, io, root)) orelse error.NoRadios;
        },
    }
}

// ---------------------------------------------------------------------------
// Journal plumbing (thin; the pure functions above are the test seam).
// ---------------------------------------------------------------------------

fn readField(j: *jl.sd_journal, field: [:0]const u8) ?[]const u8 {
    var data: ?*const anyopaque = null;
    var len: usize = 0;
    if (jl.sd_journal_get_data(j, field, &data, &len) < 0) return null;
    const raw: [*]const u8 = @ptrCast(data.?);
    const bytes = raw[0..len];
    if (bytes.len <= field.len) return null;
    if (!std.mem.eql(u8, bytes[0..field.len], field)) return null;
    if (bytes[field.len] != '=') return null;
    return bytes[field.len + 1 ..];
}

fn fieldEquals(j: *jl.sd_journal, field: [:0]const u8, expected: []const u8) bool {
    const value = readField(j, field) orelse return false;
    return std.mem.eql(u8, value, expected);
}

fn currentRecordAdmission(j: *jl.sd_journal, expected_kernel_device: []const u8) ?Admitted {
    // libsystemd only guarantees a value returned by sd_journal_get_data()
    // until the next get-data call. Consume each value before requesting the
    // next field instead of retaining borrowed slices in a JournalEntry.
    if (!fieldEquals(j, "_TRANSPORT", "kernel")) return null;
    if (!fieldEquals(j, "SYSLOG_IDENTIFIER", "kernel")) return null;
    if (!fieldEquals(j, "_KERNEL_SUBSYSTEM", "input")) return null;

    const borrowed_device = readField(j, "_KERNEL_DEVICE") orelse return null;
    if (!isInputDevicePath(borrowed_device)) return null;
    if (borrowed_device.len > MaxKernelDeviceLen) return null;
    if (!std.mem.eql(u8, borrowed_device, expected_kernel_device)) return null;

    // Keep a local copy before requesting MESSAGE. This preserves the
    // sd_journal_get_data borrowed-value lifetime discipline above while still
    // requiring MESSAGE's inputN to agree with _KERNEL_DEVICE.
    var device_buffer: [MaxKernelDeviceLen]u8 = undefined;
    @memcpy(device_buffer[0..borrowed_device.len], borrowed_device);
    const device = device_buffer[0..borrowed_device.len];

    const message = readField(j, "MESSAGE") orelse return null;
    return admittedForMessage(device, message);
}

fn addJournalMatch(j: *jl.sd_journal, match: []const u8) bool {
    const rc = jl.sd_journal_add_match(j, match.ptr, match.len);
    if (rc < 0) {
        std.debug.print("fnx-oem-osd-listener: cannot add journal match '{s}': {s}\n", .{ match, std.mem.span(jl.strerror(-rc)) });
        return false;
    }
    return true;
}

/// sd_journal_open silently ignores journal files the caller cannot read.
/// Confirm that at least one kernel entry is visible before entering the
/// long-running loop, otherwise a permission failure would look healthy.
fn kernelJournalIsVisible(j: *jl.sd_journal) !bool {
    const kernel_match = "_TRANSPORT=kernel";
    if (!addJournalMatch(j, kernel_match)) return error.JournalMatchFailed;
    defer jl.sd_journal_flush_matches(j);

    const seek_rc = jl.sd_journal_seek_head(j);
    if (seek_rc < 0) return error.JournalSeekFailed;
    const next_rc = jl.sd_journal_next(j);
    if (next_rc < 0) return error.JournalReadFailed;
    return next_rc > 0;
}

fn addProductionJournalMatches(alloc: std.mem.Allocator, j: *jl.sd_journal, kernel_device: []const u8) !void {
    const device_match = try std.fmt.allocPrint(alloc, "_KERNEL_DEVICE={s}", .{kernel_device});
    defer alloc.free(device_match);
    for ([_][]const u8{
        "_TRANSPORT=kernel",
        "SYSLOG_IDENTIFIER=kernel",
        "_KERNEL_SUBSYSTEM=input",
        device_match,
    }) |match| {
        if (!addJournalMatch(j, match)) return error.JournalMatchFailed;
    }
}

fn spawnIpc(gpa: std.mem.Allocator, io: std.Io, qs_bin: []const u8, qml_config: []const u8, function_name: []const u8) !void {
    const argv = try ipcArgv(gpa, qs_bin, qml_config, function_name);
    defer gpa.free(argv);
    const res = try std.process.run(gpa, io, .{
        .argv = argv,
        .stdout_limit = .limited(16 * 1024),
        .stderr_limit = .limited(16 * 1024),
    });
    defer gpa.free(res.stdout);
    defer gpa.free(res.stderr);
    switch (res.term) {
        .exited => |code| {
            if (code != 0) {
                std.debug.print("fnx-oem-osd-listener: qs IPC exited {d}; not claiming the OSD displayed. stderr: {s}\n", .{ code, std.mem.trim(u8, res.stderr, " \t\r\n") });
            } else {
                std.debug.print("fnx-oem-osd-listener: qs IPC accepted; stdout: {s}\n", .{std.mem.trim(u8, res.stdout, " \t\r\n")});
            }
        },
        else => {
            std.debug.print("fnx-oem-osd-listener: qs IPC terminated abnormally ({s}); not claiming the OSD displayed.\n", .{@tagName(res.term)});
        },
    }
}

fn usage() void {
    _ = jl.write(1, usage_text.ptr, usage_text.len);
}

const usage_text = std.fmt.comptimePrint(
    \\fnx-oem-osd-listener {s}
    \\Observes the systemd journal for supported P916F-STX OEM-key notifications
    \\and drives the standalone Quickshell OSD via IPC. Fn+F7 toggles the
    \\default PipeWire source mute and Fn+F9 toggles all rfkill radios.
    \\
    \\Usage: fnx-oem-osd-listener [options]
    \\
    \\Options:
    \\  --qs-bin PATH          `qs` executable used for IPC (default: qs)
    \\  --qml-path PATH        Quickshell config path passed as `qs -p PATH`
    \\                         (the standalone OSD shell; required)
    \\  --wpctl-bin PATH       `wpctl` executable for Fn+F7 (default: wpctl)
    \\  --debounce-ms N        monotonic debounce window (default: {d})
    \\  --check-support        validate the calibrated DMI/WMI/input identity,
    \\                         print the resolved input device, and exit
    \\  --check-runtime        validate support plus kernel-journal visibility
    \\                         and strict journal filters, then exit
    \\  --version              print the listener version and exit
    \\  -h, --help             show this help
    \\
    \\Example:
    \\  fnx-oem-osd-listener --qs-bin /usr/bin/qs \
    \\    --qml-path /opt/fnx-oem-osd/qml
    \\
, .{ version, default_debounce_ms });

fn argError(msg: []const u8) noreturn {
    std.debug.print("fnx-oem-osd-listener: {s}\n", .{msg});
    std.process.exit(2);
}

pub fn main(init: std.process.Init) !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    var qs_bin: []const u8 = "qs";
    var wpctl_bin: []const u8 = "wpctl";
    var qml_config: ?[]const u8 = null;
    var debounce_ms: u64 = default_debounce_ms;
    var check_support = false;
    var check_runtime = false;

    const args = init.minimal.args.vector; // []const [*:0]const u8 (Linux + libc)
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const a = std.mem.span(args[i]);
        if (std.mem.eql(u8, a, "-h") or std.mem.eql(u8, a, "--help")) {
            usage();
            return;
        } else if (std.mem.eql(u8, a, "--version")) {
            const text = "fnx-oem-osd-listener " ++ version ++ "\n";
            _ = jl.write(1, text.ptr, text.len);
            return;
        } else if (std.mem.eql(u8, a, "--qs-bin")) {
            i += 1;
            if (i >= args.len) argError("--qs-bin requires a value");
            qs_bin = std.mem.span(args[i]);
        } else if (std.mem.eql(u8, a, "--wpctl-bin")) {
            i += 1;
            if (i >= args.len) argError("--wpctl-bin requires a value");
            wpctl_bin = std.mem.span(args[i]);
        } else if (std.mem.eql(u8, a, "--qml-path")) {
            i += 1;
            if (i >= args.len) argError("--qml-path requires a value");
            qml_config = std.mem.span(args[i]);
        } else if (std.mem.eql(u8, a, "--debounce-ms")) {
            i += 1;
            if (i >= args.len) argError("--debounce-ms requires a value");
            debounce_ms = std.fmt.parseInt(u64, std.mem.span(args[i]), 10) catch argError("invalid --debounce-ms");
        } else if (std.mem.eql(u8, a, "--check-support")) {
            check_support = true;
        } else if (std.mem.eql(u8, a, "--check-runtime")) {
            check_runtime = true;
        } else {
            argError("unknown argument");
        }
    }
    const debounce_ns = debounceWindowNanos(debounce_ms) catch argError("--debounce-ms is too large");
    if (check_support and check_runtime) argError("--check-support and --check-runtime are mutually exclusive");
    if (!check_support and !check_runtime) {
        if (qs_bin.len == 0) argError("--qs-bin requires a non-empty value");
        if (wpctl_bin.len == 0) argError("--wpctl-bin requires a non-empty value");
        if (qml_config == null or qml_config.?.len == 0) argError("--qml-path is required and must be non-empty");
    }

    var system_root = std.Io.Dir.openDirAbsolute(init.io, "/", .{}) catch |err| {
        std.debug.print("fnx-oem-osd-listener: cannot open filesystem root for support preflight ({s})\n", .{@errorName(err)});
        std.process.exit(preflightExitStatus(.internal_error));
    };
    defer system_root.close(init.io);
    const support = probeSupportedHardware(alloc, init.io, system_root) catch |err| {
        const outcome = supportProbeFailureOutcome(err);
        switch (outcome) {
            .unsupported_hardware => std.debug.print("fnx-oem-osd-listener: unsupported hardware identity ({s}): {s}. This build remains calibrated for P916F-STX only.\n", .{ @errorName(err), supportFailureHint(err) }),
            .internal_error => std.debug.print("fnx-oem-osd-listener: cannot verify hardware identity ({s}): {s}\n", .{ @errorName(err), supportFailureHint(err) }),
            else => unreachable,
        }
        std.process.exit(preflightExitStatus(outcome));
    };

    if (check_support) {
        std.debug.print("fnx-oem-osd-listener: calibrated P916F-STX support identity passed (kernel_device={s}). This does not re-run physical OEM-event calibration.\n", .{support.kernelDevice()});
        return;
    }

    // ---- journal: seek to tail, then consume only later entries ----
    var journal: ?*jl.sd_journal = null;
    const rc = jl.sd_journal_open(&journal, jl.SD_JOURNAL_LOCAL_ONLY | jl.SD_JOURNAL_SYSTEM);
    if (rc < 0) {
        std.debug.print("fnx-oem-osd-listener: cannot open system journal: {s}\n", .{std.mem.span(jl.strerror(-rc))});
        std.process.exit(preflightExitStatus(runtimePreflightOutcome(.internal_error)));
    }
    defer jl.sd_journal_close(journal.?);

    const kernel_visible = kernelJournalIsVisible(journal.?) catch |err| {
        std.debug.print("fnx-oem-osd-listener: cannot verify kernel-journal visibility ({s})\n", .{@errorName(err)});
        std.process.exit(preflightExitStatus(runtimePreflightOutcome(.internal_error)));
    };
    if (!kernel_visible) {
        std.debug.print("fnx-oem-osd-listener: no kernel journal entries are visible to this user; supported OEM-key records cannot be observed. Fix journal permissions and log in again.\n", .{});
        std.process.exit(preflightExitStatus(runtimePreflightOutcome(.unavailable)));
    }
    addProductionJournalMatches(alloc, journal.?, support.kernelDevice()) catch |err| {
        std.debug.print("fnx-oem-osd-listener: cannot install strict journal matches ({s})\n", .{@errorName(err)});
        std.process.exit(preflightExitStatus(runtimePreflightOutcome(.internal_error)));
    };
    if (check_runtime) {
        std.debug.print("fnx-oem-osd-listener: runtime prerequisites passed (hardware=P916F-STX, kernel_device={s}, kernel_journal=visible, strict_filters=installed). This does not trigger an OEM key, change hardware state, call IPC, or prove visible presentation.\n", .{support.kernelDevice()});
        return;
    }

    const qml = qml_config.?;

    const seek_rc = jl.sd_journal_seek_tail(journal.?);
    if (seek_rc < 0) {
        std.debug.print("fnx-oem-osd-listener: cannot seek to journal tail: {s}\n", .{std.mem.span(jl.strerror(-seek_rc))});
        std.process.exit(1);
    }
    const previous_rc = jl.sd_journal_previous(journal.?); // position at last existing entry
    if (previous_rc < 0) {
        std.debug.print("fnx-oem-osd-listener: cannot position at last existing journal entry: {s}\n", .{std.mem.span(jl.strerror(-previous_rc))});
        std.process.exit(1);
    }

    std.debug.print("fnx-oem-osd-listener {s}: listening (hardware=P916F-STX, device={s}, mapping=0x0020:keyboard-off,0x0021:keyboard-low,0x0022:keyboard-high,0x0030:touchpad-off,0x0031:touchpad-on,0x0041:balanced,0x0042:performance,0x00a0:airplane-toggle,0x00a1:microphone-toggle, qs={s}, qml={s}, debounce={d}ms); consuming only journal entries newer than startup.\n", .{ version, support.kernelDevice(), qs_bin, qml, debounce_ms });

    var debouncer = Debouncer(Admitted){ .window_ns = debounce_ns };

    while (true) {
        const n = jl.sd_journal_next(journal.?);
        if (n == 0) {
            // No newer entries yet; wait for the journal to grow.
            const wait_rc = jl.sd_journal_wait(journal.?, default_wait_usec);
            if (wait_rc < 0) {
                std.debug.print("fnx-oem-osd-listener: journal wait error: {s}\n", .{std.mem.span(jl.strerror(-wait_rc))});
                std.process.exit(1);
            }
            continue;
        }
        if (n < 0) {
            std.debug.print("fnx-oem-osd-listener: journal read error: {s}\n", .{std.mem.span(jl.strerror(-n))});
            std.process.exit(1);
        }

        const admitted = currentRecordAdmission(journal.?, support.kernelDevice()) orelse continue;
        if (monotonicNanos()) |now_ns| {
            if (!debouncer.accept(admitted, now_ns)) {
                std.debug.print("fnx-oem-osd-listener: duplicate {s} OEM event within debounce window; ignored.\n", .{admitted.token()});
                continue;
            }
        } else {
            std.debug.print("fnx-oem-osd-listener: monotonic clock unavailable; processing event without debounce.\n", .{});
        }

        const function_name = switch (admitted) {
            .display => |event| blk: {
                std.debug.print("fnx-oem-osd-listener: OEM event confirmed; scancode {s} maps to {s} ({s}).\n", .{ event.scancode(), event.token(), @tagName(event.feature()) });
                break :blk event.ipcFunction();
            },
            .request => |request| blk: {
                const outcome = performRequest(alloc, init.io, system_root, wpctl_bin, request) catch |err| {
                    std.debug.print("fnx-oem-osd-listener: OEM request {s} ({s}) failed ({s}); OSD not shown.\n", .{ request.token(), request.scancode(), @errorName(err) });
                    continue;
                };
                std.debug.print("fnx-oem-osd-listener: OEM request {s} ({s}) performed; read-back state {s}.\n", .{ request.token(), request.scancode(), outcome.token() });
                break :blk outcome.ipcFunction();
            },
        };
        spawnIpc(alloc, init.io, qs_bin, qml, function_name) catch |err| {
            std.debug.print("fnx-oem-osd-listener: IPC invocation failed ({s}); not claiming the OSD displayed.\n", .{@errorName(err)});
        };
    }
}

// ---------------------------------------------------------------------------
// Unit tests — the test seam. All parsing/mapping/IPC logic is exercised here
// without touching the real journal; the production journal path is not
// weakened in any way.
// ---------------------------------------------------------------------------

const SupportedTestCase = struct {
    event: OemEvent,
    message: []const u8,
};

const supported_test_cases = [_]SupportedTestCase{
    .{ .event = .keyboard_backlight_off, .message = "input input8: Unknown key pressed, code: 0x0020" },
    .{ .event = .keyboard_backlight_low, .message = "input input8: Unknown key pressed, code: 0x0021" },
    .{ .event = .keyboard_backlight_high, .message = "input input8: Unknown key pressed, code: 0x0022" },
    .{ .event = .touchpad_off, .message = "input input8: Unknown key pressed, code: 0x0030" },
    .{ .event = .touchpad_on, .message = "input input8: Unknown key pressed, code: 0x0031" },
    .{ .event = .mode_balanced, .message = "input input8: Unknown key pressed, code: 0x0041" },
    .{ .event = .mode_performance, .message = "input input8: Unknown key pressed, code: 0x0042" },
};

const test_msg_0042 = supported_test_cases[6].message;

test "admission: every supported code requires the exact kernel journal source" {
    for (supported_test_cases) |case| {
        try std.testing.expectEqual(case.event, eventForRecord("kernel", "kernel", "input", "+input:input8", case.message).?);
        try std.testing.expect(isOemEventRecord("kernel", "kernel", "input", "+input:input8", case.message));
        try std.testing.expectEqual(case.event, eventForSupportedRecord("+input:input8", "kernel", "kernel", "input", "+input:input8", case.message).?);

        try std.testing.expectEqual(@as(?OemEvent, null), eventForRecord("stdout", "kernel", "input", "+input:input8", case.message));
        try std.testing.expectEqual(@as(?OemEvent, null), eventForRecord("kernel", "systemd-coredump", "input", "+input:input8", case.message));
        try std.testing.expectEqual(@as(?OemEvent, null), eventForRecord("kernel", "kernel", "block", "+input:input8", case.message));
        try std.testing.expectEqual(@as(?OemEvent, null), eventForSupportedRecord("+input:input5", "kernel", "kernel", "input", "+input:input8", case.message));

        var mismatch_buffer: [128]u8 = undefined;
        const mismatch = try std.fmt.bufPrint(&mismatch_buffer, "input input9{s}{s}", .{ UnknownKeyCodePrefix, case.event.scancode() });
        try std.testing.expectEqual(@as(?OemEvent, null), eventForRecord("kernel", "kernel", "input", "+input:input8", mismatch));
    }
}

test "mapping: the seven admitted codes have exact typed semantics" {
    try std.testing.expectEqual(@as(usize, 7), std.enums.values(OemEvent).len);
    for (supported_test_cases) |case| {
        try std.testing.expectEqual(case.event, eventForScancode(case.event.scancode()).?);
        try std.testing.expectEqual(case.event, eventForMessage("+input:input8", case.message).?);
    }
    try std.testing.expectEqual(OemFeature.keyboard_backlight, OemEvent.keyboard_backlight_low.feature());
    try std.testing.expectEqual(OemFeature.touchpad, OemEvent.touchpad_on.feature());
    try std.testing.expectEqual(OemFeature.performance_mode, OemEvent.mode_balanced.feature());
}

test "admission: donor and non-canonical codes remain rejected" {
    const unsupported_codes = [_][]const u8{
        "0x0040",
        "0x0050",
        "0x0051",
        "0x00a2",
        "0x00A0",
        "0x00A1",
        "0x00A2",
    };
    for (unsupported_codes) |code| {
        var message_buffer: [128]u8 = undefined;
        const message = try std.fmt.bufPrint(&message_buffer, "input input8{s}{s}", .{ UnknownKeyCodePrefix, code });
        try std.testing.expectEqual(@as(?OemEvent, null), eventForScancode(code));
        try std.testing.expectEqual(@as(?OemRequest, null), requestForScancode(code));
        try std.testing.expectEqual(@as(?OemEvent, null), eventForRecord("kernel", "kernel", "input", "+input:input8", message));
        try std.testing.expectEqual(@as(?Admitted, null), admittedForRecord("kernel", "kernel", "input", "+input:input8", message));
    }
}

test "admission: request codes are admitted only as requests from the exact source" {
    const cases = [_]struct { request: OemRequest, message: []const u8 }{
        .{ .request = .airplane_toggle, .message = "input input8: Unknown key pressed, code: 0x00a0" },
        .{ .request = .microphone_toggle, .message = "input input8: Unknown key pressed, code: 0x00a1" },
    };
    for (cases) |case| {
        try std.testing.expectEqual(Admitted{ .request = case.request }, admittedForRecord("kernel", "kernel", "input", "+input:input8", case.message).?);
        try std.testing.expectEqual(@as(?OemEvent, null), eventForRecord("kernel", "kernel", "input", "+input:input8", case.message));
        try std.testing.expectEqual(@as(?Admitted, null), admittedForRecord("stdout", "kernel", "input", "+input:input8", case.message));
        try std.testing.expectEqual(@as(?Admitted, null), admittedForRecord("kernel", "kernel", "input", "+input:input9", case.message));
    }
    for (supported_test_cases) |case| {
        try std.testing.expectEqual(Admitted{ .display = case.event }, admittedForRecord("kernel", "kernel", "input", "+input:input8", case.message).?);
    }
}

test "request: duplicate notification inside the window never toggles twice" {
    var debouncer = Debouncer(Admitted){ .window_ns = 250 * std.time.ns_per_ms };
    const mic = Admitted{ .request = .microphone_toggle };
    try std.testing.expect(debouncer.accept(mic, 0));
    try std.testing.expect(!debouncer.accept(mic, 100 * std.time.ns_per_ms));
    try std.testing.expect(debouncer.accept(.{ .request = .airplane_toggle }, 110 * std.time.ns_per_ms));
    try std.testing.expect(debouncer.accept(.{ .display = .touchpad_on }, 120 * std.time.ns_per_ms));
    try std.testing.expect(debouncer.accept(mic, 130 * std.time.ns_per_ms));
}

test "request: wpctl mute parsing accepts only one recognised line" {
    try std.testing.expectEqual(@as(?bool, true), micMutedFromWpctl("Volume: 1.00 [MUTED]\n"));
    try std.testing.expectEqual(@as(?bool, false), micMutedFromWpctl("Volume: 0.45\n"));
    try std.testing.expectEqual(@as(?bool, null), micMutedFromWpctl(""));
    try std.testing.expectEqual(@as(?bool, null), micMutedFromWpctl("Translate ID error: @DEFAULT_AUDIO_SOURCE@ is not a valid ID\n"));
    try std.testing.expectEqual(@as(?bool, null), micMutedFromWpctl("Volume: 1.00\nVolume: 1.00 [MUTED]\n"));
}

test "request: airplane decision blocks while any radio is enabled" {
    try std.testing.expectEqual(@as(?bool, null), airplaneBlockTarget(.{}));
    try std.testing.expectEqual(@as(?bool, true), airplaneBlockTarget(.{ .total = 2, .enabled = 1 }));
    try std.testing.expectEqual(@as(?bool, false), airplaneBlockTarget(.{ .total = 2, .enabled = 0 }));
    try std.testing.expectEqual(@as(?RequestOutcome, null), airplaneOutcome(.{}));
    try std.testing.expectEqual(RequestOutcome.airplane_on, airplaneOutcome(.{ .total = 2, .enabled = 0 }).?);
    try std.testing.expectEqual(RequestOutcome.airplane_off, airplaneOutcome(.{ .total = 2, .enabled = 2 }).?);
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0, 0, 3, 1, 0 }, &rfkillChangeAllEvent(true));
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0, 0, 3, 0, 0 }, &rfkillChangeAllEvent(false));
}

test "request: rfkill fixture counts soft and hard blocks" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try std.testing.expectEqual(RadioSummary{}, try readRadioSummary(std.testing.allocator, io, tmp.dir));

    try tmp.dir.createDirPath(io, RfkillClassPath ++ "/rfkill0");
    try tmp.dir.createDirPath(io, RfkillClassPath ++ "/rfkill1");
    try tmp.dir.createDirPath(io, RfkillClassPath ++ "/rfkill2");
    try tmp.dir.writeFile(io, .{ .sub_path = RfkillClassPath ++ "/rfkill0/soft", .data = "0\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = RfkillClassPath ++ "/rfkill0/hard", .data = "0\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = RfkillClassPath ++ "/rfkill1/soft", .data = "1\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = RfkillClassPath ++ "/rfkill1/hard", .data = "0\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = RfkillClassPath ++ "/rfkill2/soft", .data = "0\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = RfkillClassPath ++ "/rfkill2/hard", .data = "1\n" });
    try std.testing.expectEqual(RadioSummary{ .total = 3, .enabled = 1 }, try readRadioSummary(std.testing.allocator, io, tmp.dir));

    try tmp.dir.writeFile(io, .{ .sub_path = RfkillClassPath ++ "/rfkill0/soft", .data = "2\n" });
    try std.testing.expectError(error.MalformedRfkillState, readRadioSummary(std.testing.allocator, io, tmp.dir));
}

test "admission: rejects malformed records and messages" {
    try std.testing.expectEqual(@as(?OemEvent, null), eventForRecord("kernel", "kernel", "", "+input:input8", test_msg_0042));
    try std.testing.expectEqual(@as(?OemEvent, null), eventForRecord("kernel", "kernel", "input", "+input:input8", "input input8: Unknown key pressed, code: 0x0043"));
    try std.testing.expectEqual(@as(?OemEvent, null), eventForRecord("kernel", "kernel", "input", "+input:input8", "input input8: Unknown key pressed, code: 0x00410"));
    try std.testing.expectEqual(@as(?OemEvent, null), eventForRecord("kernel", "kernel", "input", "+input:input8", "input input8: Unknown key pressed, code: 0x42"));
    try std.testing.expectEqual(@as(?OemEvent, null), eventForRecord("kernel", "kernel", "input", "+input:input8", "Unknown key pressed, code: 0x0042"));
    try std.testing.expectEqual(@as(?OemEvent, null), eventForRecord("kernel", "kernel", "input", "+input:input8", "input input8: Unknown key pressed"));
    try std.testing.expectEqual(@as(?OemEvent, null), eventForRecord("kernel", "kernel", "input", "+input:input8", test_msg_0042 ++ "\n"));
    try std.testing.expectEqual(@as(?OemEvent, null), eventForRecord("kernel", "kernel", "input", "+input:input8", ""));
}

test "admission: message inputN must agree with kernel device" {
    try std.testing.expectEqual(@as(?OemEvent, null), eventForRecord("kernel", "kernel", "input", "+input:input8", "input input9: Unknown key pressed, code: 0x0042"));
    try std.testing.expectEqual(@as(?OemEvent, null), eventForRecord("kernel", "kernel", "input", "+input:input8", "input input80: Unknown key pressed, code: 0x0042"));
    try std.testing.expectEqual(@as(?OemEvent, null), eventForRecord("kernel", "kernel", "input", "+input:input8", "input input08: Unknown key pressed, code: 0x0042"));
}

test "admission: rejects missing or malformed kernel device" {
    try std.testing.expectEqual(@as(?OemEvent, null), eventForRecord("kernel", "kernel", "input", "", test_msg_0042));
    try std.testing.expectEqual(@as(?OemEvent, null), eventForRecord("kernel", "kernel", "input", "+input:input", test_msg_0042));
    try std.testing.expectEqual(@as(?OemEvent, null), eventForRecord("kernel", "kernel", "input", "+input:input8x", test_msg_0042));
    try std.testing.expectEqual(@as(?OemEvent, null), eventForRecord("kernel", "kernel", "input", "+input:input-1", test_msg_0042));
    try std.testing.expectEqual(@as(?OemEvent, null), eventForRecord("kernel", "kernel", "input", "input8", test_msg_0042));
}

test "admission: dynamic inputN suffix is accepted, never hard-coded" {
    try std.testing.expect(isInputDevicePath("+input:input0"));
    try std.testing.expect(isInputDevicePath("+input:input8"));
    try std.testing.expect(isInputDevicePath("+input:input42"));
    try std.testing.expect(isInputDevicePath("+input:input12345"));
    try std.testing.expectEqual(OemEvent.mode_balanced, eventForRecord("kernel", "kernel", "input", "+input:input42", "input input42: Unknown key pressed, code: 0x0041").?);
}

test "admission: oversized kernel-device identity is rejected by the pure seam" {
    const oversized = "+input:input123456789012345678901234567890123456789012345678901234567890";
    const message = "input input123456789012345678901234567890123456789012345678901234567890: Unknown key pressed, code: 0x0042";
    try std.testing.expect(oversized.len > MaxKernelDeviceLen);
    try std.testing.expectEqual(@as(?OemEvent, null), eventForMessage(oversized, message));
}

test "fieldValue strips only FIELD= and preserves value bytes exactly" {
    try std.testing.expectEqualStrings("kernel", fieldValue("_TRANSPORT=kernel"));
    try std.testing.expectEqualStrings("kernel\n", fieldValue("_TRANSPORT=kernel\n"));
    try std.testing.expectEqualStrings(test_msg_0042, fieldValue("MESSAGE=" ++ test_msg_0042));
    try std.testing.expectEqualStrings(test_msg_0042 ++ "\n", fieldValue("MESSAGE=" ++ test_msg_0042 ++ "\n"));
}

test "typed events expose exact stable tokens and scancodes" {
    const expected_tokens = [_][]const u8{
        "keyboard-backlight-off",
        "keyboard-backlight-low",
        "keyboard-backlight-high",
        "touchpad-off",
        "touchpad-on",
        "balanced",
        "performance",
    };
    for (supported_test_cases, expected_tokens) |case, token| {
        try std.testing.expectEqualStrings(token, case.event.token());
        try std.testing.expect(std.mem.endsWith(u8, case.message, case.event.scancode()));
    }
}

test "debounce: only an identical semantic event inside 250 ms is suppressed" {
    const window = 250 * std.time.ns_per_ms;

    var transition = Debouncer(OemEvent){ .window_ns = window };
    try std.testing.expect(transition.accept(.keyboard_backlight_low, 0));
    try std.testing.expect(transition.accept(.keyboard_backlight_high, 224 * std.time.ns_per_ms));

    var duplicate = Debouncer(OemEvent){ .window_ns = window };
    try std.testing.expect(duplicate.accept(.keyboard_backlight_low, 0));
    try std.testing.expect(!duplicate.accept(.keyboard_backlight_low, 224 * std.time.ns_per_ms));
    try std.testing.expect(duplicate.accept(.keyboard_backlight_low, 250 * std.time.ns_per_ms));

    var cross_feature = Debouncer(OemEvent){ .window_ns = window };
    try std.testing.expect(cross_feature.accept(.keyboard_backlight_low, 0));
    try std.testing.expect(cross_feature.accept(.touchpad_off, std.time.ns_per_ms));

    var no_window = Debouncer(OemEvent){ .window_ns = 0 };
    try std.testing.expect(no_window.accept(.mode_balanced, 1));
    try std.testing.expect(no_window.accept(.mode_balanced, 2));
}

test "debounce window conversion rejects overflow" {
    try std.testing.expectEqual(@as(u64, 250 * std.time.ns_per_ms), try debounceWindowNanos(250));
    try std.testing.expectError(error.Overflow, debounceWindowNanos(std.math.maxInt(u64)));
}

test "support gate: WMI identity requires the complete UUID and decimal instance" {
    try std.testing.expect(isWmiGuidInstance(SupportedEventGuid ++ "-0", SupportedEventGuid));
    try std.testing.expect(isWmiGuidInstance(SupportedMethodGuid ++ "-12", SupportedMethodGuid));
    try std.testing.expect(!isWmiGuidInstance("ABBC0F5B-0", SupportedEventGuid));
    try std.testing.expect(!isWmiGuidInstance(SupportedEventGuid, SupportedEventGuid));
    try std.testing.expect(!isWmiGuidInstance(SupportedEventGuid ++ "-x", SupportedEventGuid));
    try std.testing.expect(!isWmiGuidInstance(SupportedEventGuid ++ "-0-extra", SupportedEventGuid));
}

test "preflight status contract is exact and fail-closed" {
    try std.testing.expectEqual(@as(u8, 0), preflightExitStatus(.passed));
    try std.testing.expectEqual(@as(u8, 77), preflightExitStatus(.unsupported_hardware));
    try std.testing.expectEqual(@as(u8, 78), preflightExitStatus(.runtime_unavailable));
    try std.testing.expectEqual(@as(u8, 1), preflightExitStatus(.internal_error));
    try std.testing.expectEqual(PreflightOutcome.passed, runtimePreflightOutcome(.ready));
    try std.testing.expectEqual(PreflightOutcome.runtime_unavailable, runtimePreflightOutcome(.unavailable));
    try std.testing.expectEqual(PreflightOutcome.internal_error, runtimePreflightOutcome(.internal_error));

    try std.testing.expectEqual(PreflightOutcome.unsupported_hardware, supportProbeFailureOutcome(SupportProbeError.UnsupportedSystemVendor));
    try std.testing.expectEqual(PreflightOutcome.unsupported_hardware, supportProbeFailureOutcome(SupportProbeError.AmbiguousHuaweiInput));
    try std.testing.expectEqual(PreflightOutcome.internal_error, supportProbeFailureOutcome(error.FileNotFound));
    try std.testing.expectEqual(PreflightOutcome.internal_error, supportProbeFailureOutcome(error.AccessDenied));
}

test "support gate: filesystem fixture resolves only the calibrated input" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, "sys/class/dmi/id");
    try tmp.dir.createDirPath(io, "sys/bus/wmi/devices/" ++ SupportedEventGuid ++ "-0");
    try tmp.dir.createDirPath(io, "sys/bus/wmi/devices/" ++ SupportedMethodGuid ++ "-1");
    try tmp.dir.createDirPath(io, "sys/devices/platform/huawei-wmi/input/input42");
    try tmp.dir.writeFile(io, .{ .sub_path = DmiVendorPath, .data = SupportedSystemVendor ++ "\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = DmiBoardPath, .data = SupportedBoardName ++ "\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = HuaweiInputPath ++ "/input42/name", .data = SupportedInputName ++ "\n" });

    const support = try probeSupportedHardware(std.testing.allocator, io, tmp.dir);
    try std.testing.expectEqualStrings("+input:input42", support.kernelDevice());
}

test "support gate: every missing or ambiguous identity layer fails closed" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, "sys/class/dmi/id");
    try tmp.dir.createDirPath(io, WmiDevicesPath);
    try tmp.dir.createDirPath(io, HuaweiInputPath);
    try tmp.dir.writeFile(io, .{ .sub_path = DmiVendorPath, .data = "OTHER" });
    try tmp.dir.writeFile(io, .{ .sub_path = DmiBoardPath, .data = "some-other-board" });
    try std.testing.expectError(SupportProbeError.UnsupportedSystemVendor, probeSupportedHardware(std.testing.allocator, io, tmp.dir));

    try tmp.dir.writeFile(io, .{ .sub_path = DmiVendorPath, .data = SupportedSystemVendor ++ " \n" });
    try std.testing.expectError(SupportProbeError.UnsupportedSystemVendor, probeSupportedHardware(std.testing.allocator, io, tmp.dir));

    try tmp.dir.writeFile(io, .{ .sub_path = DmiVendorPath, .data = SupportedSystemVendor });
    try std.testing.expectError(SupportProbeError.UnsupportedBoardName, probeSupportedHardware(std.testing.allocator, io, tmp.dir));

    try tmp.dir.writeFile(io, .{ .sub_path = DmiBoardPath, .data = SupportedBoardName });
    try std.testing.expectError(SupportProbeError.MissingEventGuid, probeSupportedHardware(std.testing.allocator, io, tmp.dir));

    // Neither a dangling symlink nor a regular file whose basename resembles
    // the GUID is a WMI device.
    try tmp.dir.symLink(io, "missing-wmi-device", WmiDevicesPath ++ "/" ++ SupportedEventGuid ++ "-0", .{ .is_directory = true });
    try std.testing.expectError(SupportProbeError.MissingEventGuid, probeSupportedHardware(std.testing.allocator, io, tmp.dir));
    try tmp.dir.deleteFile(io, WmiDevicesPath ++ "/" ++ SupportedEventGuid ++ "-0");

    try tmp.dir.writeFile(io, .{ .sub_path = WmiDevicesPath ++ "/" ++ SupportedEventGuid ++ "-0", .data = "not a device" });
    try std.testing.expectError(SupportProbeError.MissingEventGuid, probeSupportedHardware(std.testing.allocator, io, tmp.dir));
    try tmp.dir.deleteFile(io, WmiDevicesPath ++ "/" ++ SupportedEventGuid ++ "-0");

    try tmp.dir.createDirPath(io, WmiDevicesPath ++ "/" ++ SupportedEventGuid ++ "-0");
    try std.testing.expectError(SupportProbeError.MissingMethodGuid, probeSupportedHardware(std.testing.allocator, io, tmp.dir));

    try tmp.dir.createDirPath(io, WmiDevicesPath ++ "/" ++ SupportedMethodGuid ++ "-1");
    try std.testing.expectError(SupportProbeError.MissingHuaweiInput, probeSupportedHardware(std.testing.allocator, io, tmp.dir));

    try tmp.dir.createDirPath(io, HuaweiInputPath ++ "/input5");
    try tmp.dir.writeFile(io, .{ .sub_path = HuaweiInputPath ++ "/input5/name", .data = SupportedInputName });
    const support = try probeSupportedHardware(std.testing.allocator, io, tmp.dir);
    try std.testing.expectEqualStrings("+input:input5", support.kernelDevice());

    try tmp.dir.createDirPath(io, HuaweiInputPath ++ "/input6");
    try tmp.dir.writeFile(io, .{ .sub_path = HuaweiInputPath ++ "/input6/name", .data = SupportedInputName });
    try std.testing.expectError(SupportProbeError.AmbiguousHuaweiInput, probeSupportedHardware(std.testing.allocator, io, tmp.dir));
}

test "ipc argv: exact zero-argument wrapper argv for noctalia-qs 0.0.12" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    const argv = try ipcArgv(alloc, "/usr/bin/qs", "/opt/fnx-oem-osd/qml", OemEvent.mode_performance.ipcFunction());
    defer alloc.free(argv);
    const expected = [_][]const u8{ "/usr/bin/qs", "-p", "/opt/fnx-oem-osd/qml", "ipc", "call", "fnx-oem-osd", "showPerformance" };
    try std.testing.expectEqual(expected.len, argv.len);
    for (expected, argv) |e, a| try std.testing.expectEqualStrings(e, a);
}

test "ipc argv: every request outcome maps to its exact zero-argument wrapper" {
    const expected = [_][]const u8{ "showMicMuted", "showMicOn", "showAirplaneOn", "showAirplaneOff" };
    for (std.enums.values(RequestOutcome), expected) |outcome, function_name| {
        try std.testing.expectEqualStrings(function_name, outcome.ipcFunction());
    }
}

test "ipc argv: every supported event maps to its exact zero-argument wrapper" {
    const expected_functions = [_][]const u8{
        "showKeyboardOff",
        "showKeyboardLow",
        "showKeyboardHigh",
        "showTouchpadOff",
        "showTouchpadOn",
        "showBalanced",
        "showPerformance",
    };
    for (supported_test_cases, expected_functions) |case, function_name| {
        try std.testing.expectEqualStrings(function_name, case.event.ipcFunction());
    }
}
