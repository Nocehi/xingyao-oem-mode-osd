//! fnx-oem-osd-listener
//!
//! Observes the systemd journal for the P916F-STX Fn+X ACPI WMI notification
//! (`0x0041` / `0x0042` unknown-key records from the kernel input subsystem)
//! and
//! drives the standalone Quickshell OSD through Quickshell IPC.
//!
//! Design rules (see README.md for the full evidence chain):
//!   * No evdev listener, key grab, key injection, udev/hwdb remap or
//!     niri/keyd binding: the upstream huawei-wmi driver consumes the
//!     scancode and never reports an input event. The only observable is
//!     the journal.
//!   * Native libsystemd journal API only; no `journalctl`, no file polling.
//!   * Startup seeks to the journal tail; only later entries are consumed.
//!   * Strict admission: kernel transport + kernel identifier + input
//!     subsystem + dynamic `+input:inputN` device + exact message whose
//!     `inputN` agrees with that device and whose code is 0x0041 or 0x0042.
//!     The `N` in `inputN` is never hard-coded.
//!   * Monotonic debounce against duplicate WMI notifications.
//!   * Fn+X is an OEM mode namespace. Live A -> B -> A calibration on this
//!     host binds 0x0041 to balanced and 0x0042 to performance. The listener
//!     maps each admitted scancode directly; it has no seed or toggle state.
//!   * Quickshell IPC is invoked without a shell (argv-only) and its exit
//!     status is checked; a failure is reported, never claimed as shown.

const std = @import("std");
const jl = @cImport({
    @cInclude("systemd/sd-journal.h");
    @cInclude("string.h");
    @cInclude("time.h");
    @cInclude("unistd.h");
});

pub const version = "0.2.0";

pub const default_debounce_ms: u64 = 250;
pub const default_wait_usec: u64 = 1_000_000; // journal wait wakeup, 1s

// ---------------------------------------------------------------------------
// Mode — a separate OEM/firmware power namespace.
// ---------------------------------------------------------------------------

pub const Mode = enum {
    performance,
    balanced,

    pub fn label(m: Mode) []const u8 {
        return switch (m) {
            .performance => "performance",
            .balanced => "balanced",
        };
    }

    pub fn scancode(m: Mode) []const u8 {
        return switch (m) {
            .performance => "0x0042",
            .balanced => "0x0041",
        };
    }
};

// ---------------------------------------------------------------------------
// Strict journal admission.
// ---------------------------------------------------------------------------

pub const InputDevicePrefix = "+input:input";
pub const KernelDevicePrefix = "+input:";
pub const MessageDevicePrefix = "input ";
pub const MessageSuffix0041 = ": Unknown key pressed, code: 0x0041";
pub const MessageSuffix0042 = ": Unknown key pressed, code: 0x0042";
pub const MaxKernelDeviceLen = 64;

/// Returns the calibrated OEM mode only for the exact kernel/input record
/// shape captured on this host. All five fields must match.
pub fn modeForRecord(transport: []const u8, syslog_identifier: []const u8, kernel_subsystem: []const u8, kernel_device: []const u8, message: []const u8) ?Mode {
    if (!std.mem.eql(u8, transport, "kernel")) return null;
    if (!std.mem.eql(u8, syslog_identifier, "kernel")) return null;
    if (!std.mem.eql(u8, kernel_subsystem, "input")) return null;
    return modeForMessage(kernel_device, message);
}

pub fn isFnXRecord(transport: []const u8, syslog_identifier: []const u8, kernel_subsystem: []const u8, kernel_device: []const u8, message: []const u8) bool {
    return modeForRecord(transport, syslog_identifier, kernel_subsystem, kernel_device, message) != null;
}

/// Accepts only the two live-captured Fn+X message codes. The `inputN` in
/// MESSAGE must be identical to `_KERNEL_DEVICE=+input:inputN`; this preserves
/// strict admission without hard-coding the current dynamic input number.
pub fn modeForMessage(kernel_device: []const u8, message: []const u8) ?Mode {
    if (!isInputDevicePath(kernel_device)) return null;
    if (!std.mem.startsWith(u8, message, MessageDevicePrefix)) return null;

    const input_name = kernel_device[KernelDevicePrefix.len..];
    const after_prefix = message[MessageDevicePrefix.len..];
    if (!std.mem.startsWith(u8, after_prefix, input_name)) return null;

    const suffix = after_prefix[input_name.len..];
    if (std.mem.eql(u8, suffix, MessageSuffix0041)) return .balanced;
    if (std.mem.eql(u8, suffix, MessageSuffix0042)) return .performance;
    return null;
}

pub fn isFnXMessage(kernel_device: []const u8, message: []const u8) bool {
    return modeForMessage(kernel_device, message) != null;
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

/// sd_journal_get_data returns raw `FIELD=value` bytes, possibly with a
/// trailing newline. Strip both the field name and any trailing newline.
pub fn fieldValue(data: []const u8) []const u8 {
    const eq = std.mem.indexOfScalar(u8, data, '=') orelse return data;
    var v = data[eq + 1 ..];
    if (v.len > 0 and v[v.len - 1] == '\n') v = v[0 .. v.len - 1];
    return v;
}

// ---------------------------------------------------------------------------
// Monotonic debounce.
// ---------------------------------------------------------------------------

pub const Debouncer = struct {
    window_ns: u64,
    last_accept_ns: ?u64 = null,

    /// Accepts the first notification, then rejects duplicates until the
    /// monotonic window has elapsed.
    pub fn accept(self: *Debouncer, now_ns: u64) bool {
        if (self.last_accept_ns) |t| {
            if (now_ns -| t < self.window_ns) return false;
        }
        self.last_accept_ns = now_ns;
        return true;
    }
};

fn monotonicNanos() u64 {
    var ts: jl.struct_timespec = undefined;
    if (jl.clock_gettime(jl.CLOCK_MONOTONIC, &ts) != 0) return 0;
    return @as(u64, @intCast(ts.tv_sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.tv_nsec));
}

// ---------------------------------------------------------------------------
// IPC argv construction (no shell involved).
// ---------------------------------------------------------------------------

pub fn ipcFunction(mode: Mode) []const u8 {
    return switch (mode) {
        .performance => "showPerformance",
        .balanced => "showBalanced",
    };
}

/// argv equivalent of:
/// qs -p <qml-config-path> ipc call fnx-oem-osd showPerformance|showBalanced
///
/// noctalia-qs 0.0.12 rejects positional function arguments on `ipc call`
/// (exit 109), although its deprecated `msg` path accepts them. Zero-argument
/// wrappers retain the supported `ipc call` transport without relying on that
/// deprecated fallback.
pub fn ipcArgv(alloc: std.mem.Allocator, qs_bin: []const u8, qml_config: []const u8, mode: Mode) ![][]const u8 {
    return alloc.dupe([]const u8, &.{
        qs_bin,
        "-p",
        qml_config,
        "ipc",
        "call",
        "fnx-oem-osd",
        ipcFunction(mode),
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
    return fieldValue(raw[0..len]);
}

fn fieldEquals(j: *jl.sd_journal, field: [:0]const u8, expected: []const u8) bool {
    const value = readField(j, field) orelse return false;
    return std.mem.eql(u8, value, expected);
}

fn currentRecordMode(j: *jl.sd_journal) ?Mode {
    // libsystemd only guarantees a value returned by sd_journal_get_data()
    // until the next get-data call. Consume each value before requesting the
    // next field instead of retaining borrowed slices in a JournalEntry.
    if (!fieldEquals(j, "_TRANSPORT", "kernel")) return null;
    if (!fieldEquals(j, "SYSLOG_IDENTIFIER", "kernel")) return null;
    if (!fieldEquals(j, "_KERNEL_SUBSYSTEM", "input")) return null;

    const borrowed_device = readField(j, "_KERNEL_DEVICE") orelse return null;
    if (!isInputDevicePath(borrowed_device)) return null;
    if (borrowed_device.len > MaxKernelDeviceLen) return null;

    // Keep a local copy before requesting MESSAGE. This preserves the
    // sd_journal_get_data borrowed-value lifetime discipline above while still
    // requiring MESSAGE's inputN to agree with _KERNEL_DEVICE.
    var device_buffer: [MaxKernelDeviceLen]u8 = undefined;
    @memcpy(device_buffer[0..borrowed_device.len], borrowed_device);
    const device = device_buffer[0..borrowed_device.len];

    const message = readField(j, "MESSAGE") orelse return null;
    return modeForMessage(device, message);
}

fn spawnIpc(gpa: std.mem.Allocator, io: std.Io, qs_bin: []const u8, qml_config: []const u8, mode: Mode) !void {
    const argv = try ipcArgv(gpa, qs_bin, qml_config, mode);
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
    \\Observes the systemd journal for the P916F-STX Fn+X ACPI WMI notification and
    \\drives the standalone Quickshell OSD via IPC.
    \\
    \\Usage: fnx-oem-osd-listener [options]
    \\
    \\Options:
    \\  --qs-bin PATH          `qs` executable used for IPC (default: qs)
    \\  --qml-path PATH        Quickshell config path passed as `qs -p PATH`
    \\                         (the standalone OSD shell; required)
    \\  --debounce-ms N        monotonic debounce window (default: {d})
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

    const args = init.minimal.args.vector; // []const [*:0]const u8 (Linux + libc)
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const a = std.mem.span(args[i]);
        if (std.mem.eql(u8, a, "-h") or std.mem.eql(u8, a, "--help")) {
            usage();
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
        } else {
            argError("unknown argument");
        }
    }
    const qml = qml_config orelse argError("--qml-path is required");

    // ---- journal: seek to tail, then consume only later entries ----
    var journal: ?*jl.sd_journal = null;
    const rc = jl.sd_journal_open(&journal, jl.SD_JOURNAL_LOCAL_ONLY);
    if (rc < 0) {
        std.debug.print("fnx-oem-osd-listener: cannot open system journal: {s}\n", .{std.mem.span(jl.strerror(-rc))});
        std.process.exit(1);
    }
    defer jl.sd_journal_close(journal.?);

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

    std.debug.print("fnx-oem-osd-listener {s}: listening (mapping=0x0041:balanced,0x0042:performance, qs={s}, qml={s}, debounce={d}ms); consuming only journal entries newer than startup.\n", .{ version, qs_bin, qml, debounce_ms });

    var debouncer = Debouncer{ .window_ns = debounce_ms * std.time.ns_per_ms };

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

        const mode = currentRecordMode(journal.?) orelse continue;
        if (!debouncer.accept(monotonicNanos())) {
            std.debug.print("fnx-oem-osd-listener: duplicate Fn+X WMI notification within debounce window; ignored.\n", .{});
            continue;
        }

        std.debug.print("fnx-oem-osd-listener: Fn+X confirmed; scancode {s} maps to {s}.\n", .{ mode.scancode(), mode.label() });
        spawnIpc(alloc, init.io, qs_bin, qml, mode) catch |err| {
            std.debug.print("fnx-oem-osd-listener: IPC invocation failed ({s}); not claiming the OSD displayed.\n", .{@errorName(err)});
        };
    }
}

// ---------------------------------------------------------------------------
// Unit tests — the test seam. All parsing/mapping/IPC logic is exercised here
// without touching the real journal; the production journal path is not
// weakened in any way.
// ---------------------------------------------------------------------------

const test_msg_0041 = "input input8: Unknown key pressed, code: 0x0041";
const test_msg_0042 = "input input8: Unknown key pressed, code: 0x0042";

test "admission: exact positive kernel/input records for both live codes" {
    try std.testing.expect(isFnXRecord("kernel", "kernel", "input", "+input:input8", test_msg_0041));
    try std.testing.expect(isFnXRecord("kernel", "kernel", "input", "+input:input8", test_msg_0042));
}

test "mapping: 0x0041 is balanced and 0x0042 is performance" {
    try std.testing.expectEqual(Mode.balanced, modeForRecord("kernel", "kernel", "input", "+input:input8", test_msg_0041).?);
    try std.testing.expectEqual(Mode.performance, modeForRecord("kernel", "kernel", "input", "+input:input8", test_msg_0042).?);
}

test "admission: rejects non-kernel transport" {
    try std.testing.expect(!isFnXRecord("stdout", "kernel", "input", "+input:input8", test_msg_0042));
}

test "admission: rejects wrong syslog identifier" {
    try std.testing.expect(!isFnXRecord("kernel", "systemd-coredump", "input", "+input:input8", test_msg_0042));
}

test "admission: rejects wrong kernel subsystem" {
    try std.testing.expect(!isFnXRecord("kernel", "kernel", "block", "+input:input8", test_msg_0042));
    try std.testing.expect(!isFnXRecord("kernel", "kernel", "", "+input:input8", test_msg_0042));
}

test "admission: rejects wrong message" {
    try std.testing.expect(!isFnXRecord("kernel", "kernel", "input", "+input:input8", "input input8: Unknown key pressed, code: 0x0043"));
    try std.testing.expect(!isFnXRecord("kernel", "kernel", "input", "+input:input8", "input input8: Unknown key pressed, code: 0x00410"));
    try std.testing.expect(!isFnXRecord("kernel", "kernel", "input", "+input:input8", "input input8: Unknown key pressed, code: 0x41"));
    try std.testing.expect(!isFnXRecord("kernel", "kernel", "input", "+input:input8", "Unknown key pressed, code: 0x0042"));
    try std.testing.expect(!isFnXRecord("kernel", "kernel", "input", "+input:input8", "input input8: Unknown key pressed"));
    try std.testing.expect(!isFnXRecord("kernel", "kernel", "input", "+input:input8", ""));
}

test "admission: message inputN must agree with kernel device" {
    try std.testing.expect(!isFnXRecord("kernel", "kernel", "input", "+input:input8", "input input9: Unknown key pressed, code: 0x0042"));
    try std.testing.expect(!isFnXRecord("kernel", "kernel", "input", "+input:input8", "input input80: Unknown key pressed, code: 0x0042"));
    try std.testing.expect(!isFnXRecord("kernel", "kernel", "input", "+input:input8", "input input08: Unknown key pressed, code: 0x0042"));
}

test "admission: rejects missing or malformed kernel device" {
    try std.testing.expect(!isFnXRecord("kernel", "kernel", "input", "", test_msg_0042));
    try std.testing.expect(!isFnXRecord("kernel", "kernel", "input", "+input:input", test_msg_0042));
    try std.testing.expect(!isFnXRecord("kernel", "kernel", "input", "+input:input8x", test_msg_0042));
    try std.testing.expect(!isFnXRecord("kernel", "kernel", "input", "+input:input-1", test_msg_0042));
    try std.testing.expect(!isFnXRecord("kernel", "kernel", "input", "input8", test_msg_0042));
}

test "admission: dynamic inputN suffix is accepted, never hard-coded" {
    try std.testing.expect(isInputDevicePath("+input:input0"));
    try std.testing.expect(isInputDevicePath("+input:input8"));
    try std.testing.expect(isInputDevicePath("+input:input42"));
    try std.testing.expect(isInputDevicePath("+input:input12345"));
    try std.testing.expect(isFnXRecord("kernel", "kernel", "input", "+input:input42", "input input42: Unknown key pressed, code: 0x0041"));
}

test "fieldValue strips FIELD= prefix and trailing newline" {
    try std.testing.expectEqualStrings("kernel", fieldValue("_TRANSPORT=kernel\n"));
    try std.testing.expectEqualStrings("kernel", fieldValue("SYSLOG_IDENTIFIER=kernel\n"));
    try std.testing.expectEqualStrings("+input:input8", fieldValue("_KERNEL_DEVICE=+input:input8\n"));
    try std.testing.expectEqualStrings(test_msg_0042, fieldValue("MESSAGE=" ++ test_msg_0042 ++ "\n"));
    // values without trailing newline are handled too
    try std.testing.expectEqualStrings("kernel", fieldValue("_TRANSPORT=kernel"));
}

test "mapping: malformed or unsupported messages have no mode" {
    try std.testing.expectEqual(@as(?Mode, null), modeForMessage("+input:input8", "input input8: Unknown key pressed, code: 0x0043"));
    try std.testing.expectEqual(@as(?Mode, null), modeForMessage("+input:input9", test_msg_0041));
    try std.testing.expectEqual(@as(?Mode, null), modeForRecord("stdout", "kernel", "input", "+input:input8", test_msg_0042));
}

test "labels are the exact IPC tokens" {
    try std.testing.expectEqualStrings("performance", Mode.performance.label());
    try std.testing.expectEqualStrings("balanced", Mode.balanced.label());
    try std.testing.expectEqualStrings("0x0042", Mode.performance.scancode());
    try std.testing.expectEqualStrings("0x0041", Mode.balanced.scancode());
}

test "debounce: first accept, duplicate rejected, window elapse accepts" {
    var d = Debouncer{ .window_ns = 1_000_000_000 };
    try std.testing.expect(d.accept(100));
    try std.testing.expect(!d.accept(500)); // within window
    try std.testing.expect(!d.accept(1_000)); // within window
    try std.testing.expect(d.accept(1_000_000_100)); // 1s+ window elapsed
    // a fresh debouncer accepts immediately
    var d2 = Debouncer{ .window_ns = 0 };
    try std.testing.expect(d2.accept(1));
    try std.testing.expect(d2.accept(2));
}

test "ipc argv: exact zero-argument wrapper argv for noctalia-qs 0.0.12" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    const argv = try ipcArgv(alloc, "/usr/bin/qs", "/opt/fnx-oem-osd/qml", Mode.performance);
    defer alloc.free(argv);
    const expected = [_][]const u8{ "/usr/bin/qs", "-p", "/opt/fnx-oem-osd/qml", "ipc", "call", "fnx-oem-osd", "showPerformance" };
    try std.testing.expectEqual(expected.len, argv.len);
    for (expected, argv) |e, a| try std.testing.expectEqualStrings(e, a);
}

test "ipc argv: all modes map to their exact zero-argument wrapper" {
    try std.testing.expectEqualStrings("showPerformance", ipcFunction(.performance));
    try std.testing.expectEqualStrings("showBalanced", ipcFunction(.balanced));
}
