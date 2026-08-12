const std = @import("std");
const listener = @import("listener");

fn usageError() noreturn {
    std.debug.print(
        "usage: fnx-oem-osd-cli-fixture --check-support ROOT | --check-runtime ROOT ready|unavailable|error\n",
        .{},
    );
    std.process.exit(2);
}

pub fn main(init: std.process.Init) !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();
    const args = init.minimal.args.vector;

    if (args.len < 2) usageError();
    const command = std.mem.span(args[1]);
    const check_support = std.mem.eql(u8, command, "--check-support");
    const check_runtime = std.mem.eql(u8, command, "--check-runtime");
    if ((!check_support and !check_runtime) or
        (check_support and args.len != 3) or
        (check_runtime and args.len != 4))
    {
        usageError();
    }

    const root_path = std.mem.span(args[2]);
    var root = std.Io.Dir.openDirAbsolute(init.io, root_path, .{}) catch {
        std.process.exit(listener.preflightExitStatus(.internal_error));
    };
    defer root.close(init.io);

    _ = listener.probeSupportedHardware(alloc, init.io, root) catch |err| {
        std.process.exit(listener.preflightExitStatus(listener.supportProbeFailureOutcome(err)));
    };
    if (check_support) return;

    const runtime_fixture = std.mem.span(args[3]);
    const result: listener.RuntimeProbeResult = if (std.mem.eql(u8, runtime_fixture, "ready"))
        .ready
    else if (std.mem.eql(u8, runtime_fixture, "unavailable"))
        .unavailable
    else if (std.mem.eql(u8, runtime_fixture, "error"))
        .internal_error
    else
        usageError();

    const status = listener.preflightExitStatus(listener.runtimePreflightOutcome(result));
    if (status != 0) std.process.exit(status);
}
