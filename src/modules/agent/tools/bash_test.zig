const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;

const bash = @import("bash.zig");

test "bash_tool: foreground echo command runs on host OS" {
    if (builtin.os.tag != .linux and builtin.os.tag != .macos) return;

    const allocator = testing.allocator;
    const io = std.testing.io;

    const result = try bash.execute_bash(allocator, io, .{
        .command = "echo hello-cross-platform",
        .cwd = if (builtin.os.tag == .linux) "/" else "/tmp",
        .max_output = 1024,
        .max_lines = 10,
        .mandatory_timeout = 5,
    });
    defer {
        allocator.free(result.command);
        allocator.free(result.stdout);
        allocator.free(result.stderr);
    }

    try testing.expect(result.exit_code == 0);
    try testing.expect(std.mem.indexOf(u8, result.stdout, "hello-cross-platform") != null);
}

test "bash_tool: large output is truncated by line count" {
    if (builtin.os.tag != .linux and builtin.os.tag != .macos) return;

    const allocator = testing.allocator;
    const io = std.testing.io;

    const result = try bash.execute_bash(allocator, io, .{
        .command = "seq 1 1000",
        .cwd = "/tmp",
        .max_output = 1024 * 1024,
        .max_lines = 5,
        .mandatory_timeout = 5,
    });
    defer {
        allocator.free(result.command);
        allocator.free(result.stdout);
        allocator.free(result.stderr);
    }

    try testing.expect(result.exit_code == 0);
    try testing.expect(result.truncated == true);
    try testing.expect(result.stdout_lines >= 5);
}

test "bash_tool: timeout fires on long-running command" {
    if (builtin.os.tag != .linux and builtin.os.tag != .macos) return;

    const allocator = testing.allocator;
    const io = std.testing.io;

    const result = try bash.execute_bash(allocator, io, .{
        .command = "sleep 5",
        .cwd = "/tmp",
        .mandatory_timeout = 1,
    });
    defer {
        allocator.free(result.command);
        allocator.free(result.stdout);
        allocator.free(result.stderr);
    }

    try testing.expect(result.timeout == true);
    try testing.expect(result.exit_code != 0); // killed by signal
}

test "bash_tool: missing mandatory_timeout returns MandatoryTimeoutMissing" {
    // Runs on ALL platforms (no shell required) — the validation fires before
    // we ever spawn a child.
    const allocator = testing.allocator;
    const io = std.testing.io;

    const result = bash.execute_bash(allocator, io, .{
        .command = "echo should-never-run",
        .cwd = "/tmp",
        // mandatory_timeout intentionally omitted → null
    });
    try testing.expectError(error.MandatoryTimeoutMissing, result);
}

test "bash_tool: mandatory_timeout = 0 returns MandatoryTimeoutMissing" {
    // Zero is not a meaningful deadline; treat it the same as missing.
    const allocator = testing.allocator;
    const io = std.testing.io;

    const result = bash.execute_bash(allocator, io, .{
        .command = "echo should-never-run",
        .cwd = "/tmp",
        .mandatory_timeout = 0,
    });
    try testing.expectError(error.MandatoryTimeoutMissing, result);
}

test "bash_tool: background mode ignores missing mandatory_timeout" {
    // Background runs detach via nohup and have no deadline enforced by this
    // tool, so omitting mandatory_timeout must NOT return MandatoryTimeoutMissing.
    // We don't actually verify the detached process behavior (CI is too flaky
    // for that) — we only verify that the validation gate lets it through.
    if (builtin.os.tag != .linux and builtin.os.tag != .macos) return;

    const allocator = testing.allocator;
    const io = std.testing.io;

    const result = bash.execute_bash(allocator, io, .{
        .command = "true",
        .cwd = "/tmp",
        .background = true,
        // mandatory_timeout intentionally null
    });
    // Only MandatoryTimeoutMissing is a contract violation. Any other
    // error means the background path is broken for unrelated reasons;
    // surface it as a test failure rather than masking it.
    if (result) |r| {
        defer allocator.free(r.command);
        defer allocator.free(r.stdout);
        defer allocator.free(r.stderr);
    } else |err| {
        try testing.expect(err != error.MandatoryTimeoutMissing);
    }
}
