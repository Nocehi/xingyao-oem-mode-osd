const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    // Native journal access through libsystemd (sd-journal). No third-party
    // Zig dependencies.
    // NOTE: use_pkg_config must be disabled — the Arch systemd.pc ships no
    // Libs: line (systemd-libs split), so pkg-config resolves it to nothing;
    // direct -lsystemd search works.
    mod.linkSystemLibrary("systemd", .{ .use_pkg_config = .no });
    const exe = b.addExecutable(.{
        .name = "fnx-oem-osd-listener",
        .root_module = mod,
        // Select the host linker for native builds. scripts/zig-build.sh also
        // handles the official Zig 0.16.0 binary's Arch GCC 16 CRT parser gap.
        .use_lld = false,
    });
    exe.use_new_linker = false;
    b.installArtifact(exe);

    // A separately built, non-production fixture runner exercises the exact
    // support probe and preflight status mapping against disposable roots.
    // It is available only through `zig build cli-fixture` and is never part
    // of the default install graph.
    const cli_fixture_mod = b.createModule(.{
        .root_source_file = b.path("tests/cli_fixture.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    cli_fixture_mod.addImport("listener", mod);
    cli_fixture_mod.linkSystemLibrary("systemd", .{ .use_pkg_config = .no });
    const cli_fixture = b.addExecutable(.{
        .name = "fnx-oem-osd-cli-fixture",
        .root_module = cli_fixture_mod,
        .use_lld = false,
    });
    cli_fixture.use_new_linker = false;
    const install_cli_fixture = b.addInstallArtifact(cli_fixture, .{});
    const cli_fixture_step = b.step("cli-fixture", "Build the deterministic CLI preflight fixture runner");
    cli_fixture_step.dependOn(&install_cli_fixture.step);

    const test_mod = b.createModule(.{
        .root_source_file = b.path("test_suite.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    test_mod.linkSystemLibrary("systemd", .{ .use_pkg_config = .no });
    const unit_tests = b.addTest(.{
        .root_module = test_mod,
        .use_lld = false,
    });
    unit_tests.use_new_linker = false;
    const run_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);
}
