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
//!     one of the seven display-only codes calibrated on this board. The `N`
//!     in `inputN` is never hard-coded.
//!   * Fail-closed hardware preflight for the calibrated P916F-STX DMI, WMI
//!     GUID pair, huawei-wmi platform path, and input-device identity.
//!   * Exact-event monotonic debounce against duplicate WMI notifications.
//!   * Each admitted scancode maps directly to a typed state already formed by
//!     firmware/EC: keyboard backlight off/low/high, touchpad off/on, or OEM
//!     balanced/performance mode. The listener has no seed or toggle state and
//!     never performs the hardware action.
//!   * Quickshell IPC is invoked without a shell (argv-only) and its exit
//!     status is checked; a failure is reported, never claimed as shown.

const std = @import("std");
const jl = @cImport({
    @cInclude("systemd/sd-journal.h");
    @cInclude("string.h");
    @cInclude("time.h");
    @cInclude("unistd.h");
});

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

/// Accepts only the seven current-board display-only codes. The `inputN` in
/// MESSAGE must be identical to `_KERNEL_DEVICE=+input:inputN`; this preserves
/// strict admission without hard-coding the current dynamic input number.
pub fn eventForMessage(kernel_device: []const u8, message: []const u8) ?OemEvent {
    if (kernel_device.len > MaxKernelDeviceLen) return null;
    if (!isInputDevicePath(kernel_device)) return null;
    if (!std.mem.startsWith(u8, message, MessageDevicePrefix)) return null;

    const input_name = kernel_device[KernelDevicePrefix.len..];
    const after_prefix = message[MessageDevicePrefix.len..];
    if (!std.mem.startsWith(u8, after_prefix, input_name)) return null;

    const suffix = after_prefix[input_name.len..];
    if (!std.mem.startsWith(u8, suffix, UnknownKeyCodePrefix)) return null;
    return eventForScancode(suffix[UnknownKeyCodePrefix.len..]);
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

pub const Debouncer = struct {
    window_ns: u64,
    last_accept_ns: ?u64 = null,
    last_event: ?OemEvent = null,

    /// Rejects only an identical semantic event inside the window. A distinct
    /// state or feature is a new report and must not be dropped.
    pub fn accept(self: *Debouncer, event: OemEvent, now_ns: u64) bool {
        if (self.last_accept_ns) |t| {
            if (self.last_event == event and now_ns -| t < self.window_ns) return false;
        }
        self.last_accept_ns = now_ns;
        self.last_event = event;
        return true;
    }
};

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
pub fn ipcArgv(alloc: std.mem.Allocator, qs_bin: []const u8, qml_config: []const u8, event: OemEvent) ![][]const u8 {
    return alloc.dupe([]const u8, &.{
        qs_bin,
        "-p",
        qml_config,
        "ipc",
        "call",
        "fnx-oem-osd",
        event.ipcFunction(),
    });
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

fn currentRecordEvent(j: *jl.sd_journal, expected_kernel_device: []const u8) ?OemEvent {
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
    return eventForMessage(device, message);
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

fn spawnIpc(gpa: std.mem.Allocator, io: std.Io, qs_bin: []const u8, qml_config: []const u8, event: OemEvent) !void {
    const argv = try ipcArgv(gpa, qs_bin, qml_config, event);
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
    \\Observes the systemd journal for supported P916F-STX display-only OEM-key
    \\notifications and drives the standalone Quickshell OSD via IPC.
    \\
    \\Usage: fnx-oem-osd-listener [options]
    \\
    \\Options:
    \\  --qs-bin PATH          `qs` executable used for IPC (default: qs)
    \\  --qml-path PATH        Quickshell config path passed as `qs -p PATH`
    \\                         (the standalone OSD shell; required)
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

    std.debug.print("fnx-oem-osd-listener {s}: listening (hardware=P916F-STX, device={s}, mapping=0x0020:keyboard-off,0x0021:keyboard-low,0x0022:keyboard-high,0x0030:touchpad-off,0x0031:touchpad-on,0x0041:balanced,0x0042:performance, qs={s}, qml={s}, debounce={d}ms); consuming only journal entries newer than startup.\n", .{ version, support.kernelDevice(), qs_bin, qml, debounce_ms });

    var debouncer = Debouncer{ .window_ns = debounce_ns };

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

        const event = currentRecordEvent(journal.?, support.kernelDevice()) orelse continue;
        if (monotonicNanos()) |now_ns| {
            if (!debouncer.accept(event, now_ns)) {
                std.debug.print("fnx-oem-osd-listener: duplicate {s} OEM event within debounce window; ignored.\n", .{event.token()});
                continue;
            }
        } else {
            std.debug.print("fnx-oem-osd-listener: monotonic clock unavailable; processing event without debounce.\n", .{});
        }

        std.debug.print("fnx-oem-osd-listener: OEM event confirmed; scancode {s} maps to {s} ({s}).\n", .{ event.scancode(), event.token(), @tagName(event.feature()) });
        spawnIpc(alloc, init.io, qs_bin, qml, event) catch |err| {
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

test "admission: unsupported request and donor codes remain rejected" {
    const unsupported_codes = [_][]const u8{
        "0x0040",
        "0x0050",
        "0x0051",
        "0x00a0",
        "0x00a1",
        "0x00a2",
        "0x00A0",
        "0x00A1",
        "0x00A2",
    };
    for (unsupported_codes) |code| {
        var message_buffer: [128]u8 = undefined;
        const message = try std.fmt.bufPrint(&message_buffer, "input input8{s}{s}", .{ UnknownKeyCodePrefix, code });
        try std.testing.expectEqual(@as(?OemEvent, null), eventForScancode(code));
        try std.testing.expectEqual(@as(?OemEvent, null), eventForRecord("kernel", "kernel", "input", "+input:input8", message));
    }
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

    var transition = Debouncer{ .window_ns = window };
    try std.testing.expect(transition.accept(.keyboard_backlight_low, 0));
    try std.testing.expect(transition.accept(.keyboard_backlight_high, 224 * std.time.ns_per_ms));

    var duplicate = Debouncer{ .window_ns = window };
    try std.testing.expect(duplicate.accept(.keyboard_backlight_low, 0));
    try std.testing.expect(!duplicate.accept(.keyboard_backlight_low, 224 * std.time.ns_per_ms));
    try std.testing.expect(duplicate.accept(.keyboard_backlight_low, 250 * std.time.ns_per_ms));

    var cross_feature = Debouncer{ .window_ns = window };
    try std.testing.expect(cross_feature.accept(.keyboard_backlight_low, 0));
    try std.testing.expect(cross_feature.accept(.touchpad_off, std.time.ns_per_ms));

    var no_window = Debouncer{ .window_ns = 0 };
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

    const argv = try ipcArgv(alloc, "/usr/bin/qs", "/opt/fnx-oem-osd/qml", .mode_performance);
    defer alloc.free(argv);
    const expected = [_][]const u8{ "/usr/bin/qs", "-p", "/opt/fnx-oem-osd/qml", "ipc", "call", "fnx-oem-osd", "showPerformance" };
    try std.testing.expectEqual(expected.len, argv.len);
    for (expected, argv) |e, a| try std.testing.expectEqualStrings(e, a);
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
