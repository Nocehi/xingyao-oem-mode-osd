const std = @import("std");
const listener = @import("src/main.zig");

// Importing the listener includes its unit tests. This root-level suite can
// also embed repository evidence without weakening Zig's package-path guard.

const CalibrationEvidence = struct {
    schema_version: u8,
    evidence_class: []const u8,
    raw_capture_in_repository: bool,
    support_identity: struct {
        sys_vendor: []const u8,
        board_name: []const u8,
        event_guid: []const u8,
        method_guid: []const u8,
        input_name: []const u8,
    },
    audit_identity_observation: struct {
        observed_on: []const u8,
        product_name: []const u8,
        bios_version: []const u8,
        scope: []const u8,
    },
    mappings: []const struct {
        scancode: []const u8,
        mode: []const u8,
    },
    calibration_samples: []const struct {
        local_time: []const u8,
        scancode: []const u8,
        mode: []const u8,
        stapm_w: u8,
        fast_ppt_w: u8,
        slow_ppt_w: u8,
    },
    controlled_linux_state: struct {
        ac_online: bool,
        platform_profile: []const u8,
        energy_performance_preference: []const u8,
        cpu_governor: []const u8,
    },
    limitations: []const []const u8,
};

test "calibration evidence: JSON is parseable and bound to code constants" {
    const bytes = @embedFile("evidence/p916f-stx-calibration-v1.json");
    var parsed = try std.json.parseFromSlice(CalibrationEvidence, std.testing.allocator, bytes, .{});
    defer parsed.deinit();
    const evidence = parsed.value;

    try std.testing.expectEqual(@as(u8, 1), evidence.schema_version);
    try std.testing.expectEqualStrings("author-transcribed-calibration-summary", evidence.evidence_class);
    try std.testing.expect(!evidence.raw_capture_in_repository);
    try std.testing.expectEqualStrings(listener.SupportedSystemVendor, evidence.support_identity.sys_vendor);
    try std.testing.expectEqualStrings(listener.SupportedBoardName, evidence.support_identity.board_name);
    try std.testing.expectEqualStrings(listener.SupportedEventGuid, evidence.support_identity.event_guid);
    try std.testing.expectEqualStrings(listener.SupportedMethodGuid, evidence.support_identity.method_guid);
    try std.testing.expectEqualStrings(listener.SupportedInputName, evidence.support_identity.input_name);
    try std.testing.expectEqualStrings("2026-08-12", evidence.audit_identity_observation.observed_on);
    try std.testing.expectEqualStrings("XINGYAO Series", evidence.audit_identity_observation.product_name);
    try std.testing.expectEqualStrings("1.06", evidence.audit_identity_observation.bios_version);
    try std.testing.expectEqualStrings("Read-only author-host observation made after the calibration date; not a raw calibration capture.", evidence.audit_identity_observation.scope);

    try std.testing.expectEqual(@as(usize, 2), evidence.mappings.len);
    try std.testing.expectEqualStrings(listener.Mode.balanced.scancode(), evidence.mappings[0].scancode);
    try std.testing.expectEqualStrings(listener.Mode.balanced.label(), evidence.mappings[0].mode);
    try std.testing.expectEqualStrings(listener.Mode.performance.scancode(), evidence.mappings[1].scancode);
    try std.testing.expectEqualStrings(listener.Mode.performance.label(), evidence.mappings[1].mode);

    try std.testing.expectEqual(@as(usize, 3), evidence.calibration_samples.len);
    const expected_times = [_][]const u8{
        "2026-08-11T21:46:27.386+08:00",
        "2026-08-11T21:48:46.138+08:00",
        "2026-08-11T21:56:04.159+08:00",
    };
    const expected_scancodes = [_][]const u8{ "0x0041", "0x0042", "0x0041" };
    const expected_modes = [_][]const u8{ "balanced", "performance", "balanced" };
    const expected_stapm = [_]u8{ 15, 28, 15 };
    const expected_fast_ppt = [_]u8{ 30, 45, 30 };
    const expected_slow_ppt = [_]u8{ 25, 35, 25 };
    for (evidence.calibration_samples, 0..) |sample, index| {
        try std.testing.expectEqualStrings(expected_times[index], sample.local_time);
        try std.testing.expectEqualStrings(expected_scancodes[index], sample.scancode);
        try std.testing.expectEqualStrings(expected_modes[index], sample.mode);
        try std.testing.expectEqual(expected_stapm[index], sample.stapm_w);
        try std.testing.expectEqual(expected_fast_ppt[index], sample.fast_ppt_w);
        try std.testing.expectEqual(expected_slow_ppt[index], sample.slow_ppt_w);
    }

    try std.testing.expect(evidence.controlled_linux_state.ac_online);
    try std.testing.expectEqualStrings("performance", evidence.controlled_linux_state.platform_profile);
    try std.testing.expectEqualStrings("performance", evidence.controlled_linux_state.energy_performance_preference);
    try std.testing.expectEqualStrings("performance", evidence.controlled_linux_state.cpu_governor);
    try std.testing.expectEqual(@as(usize, 3), evidence.limitations.len);
    try std.testing.expectEqualStrings("Values are transcribed from the original author's local run; raw journal and RyzenAdj captures are not shipped in this repository.", evidence.limitations[0]);
    try std.testing.expectEqualStrings("The summary does not establish compatibility for another model, board identity, BIOS, WMI path, or scancode mapping.", evidence.limitations[1]);
    try std.testing.expectEqualStrings("A successful IPC response does not prove visible compositor presentation.", evidence.limitations[2]);
}
