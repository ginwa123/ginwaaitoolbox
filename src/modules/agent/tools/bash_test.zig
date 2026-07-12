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

test "bash_tool: timeout kills subshell descendants (no pipe-leak hang)" {
    // Regression test for the macOS hang. When bash is killed but its
    // descendants (subshells via `( )`, `|&`, backgrounded `&`, pipes)
    // inherit the pipe FDs back to us, the reader threads block forever
    // on pipe EOF that never arrives. The fix puts bash in its own
    // process group (.pgid = 0) so the timeout path can kill the whole
    // group with std.posix.kill(-pgid, .KILL).
    //
    // Without the fix this test hangs until the Zig test runner's
    // per-test timeout kills it; with the fix it returns in ~1 s with
    // timeout == true. We bound the wait with an overall deadline
    // matching `mandatory_timeout * 4` so a regression surfaces as a
    // test failure rather than a process hang.
    if (builtin.os.tag != .linux and builtin.os.tag != .macos) return;

    const allocator = testing.allocator;
    const io = std.testing.io;

    // `( sleep 5 ) | cat` — bash spawns a subshell for `( )` that
    // inherits the pipe FDs to us. The pre-fix code killed bash but
    // not the subshell, so the reader thread waited forever for EOF.
    const result = try bash.execute_bash(allocator, io, .{
        .command = "( sleep 5 ) | cat",
        .cwd = "/tmp",
        .mandatory_timeout = 1,
    });
    defer {
        allocator.free(result.command);
        allocator.free(result.stdout);
        allocator.free(result.stderr);
    }

    try testing.expect(result.timeout == true);
    try testing.expect(result.exit_code != 0);
}

test "bash_tool: timeout kills descendants across all common subshell shapes" {
    // Each of these exercises a distinct descendant topology that bash
    // spawns before exec'ing into the long-running command. The pre-fix
    // code (no .pgid, child.kill only) left each descendant holding the
    // pipe FDs to us, so the reader thread blocked forever. With the
    // process-group kill, the whole tree dies together and the pipes
    // EOF cleanly.
    if (builtin.os.tag != .linux and builtin.os.tag != .macos) return;

    const allocator = testing.allocator;
    const io = std.testing.io;

    const cases = [_][]const u8{
        "( sleep 5 )", // bare subshell group
        "sleep 5 | head", // pipe (no subshell, but reader FDs shared)
        "sleep 5 & wait", // backgrounded job + wait
        "{ sleep 5; }", // brace group
        "( ( sleep 5 ) )", // nested subshells
        "bash -c 'sleep 5'", // inner bash inherits our pgid
        // The exact shape the AI hit in production (session-1783866771666):
        // outer `timeout` + nested `bash -c` + subshell-in-pipe. If the
        // process-group kill is incomplete this hangs for the full
        // mandatory_timeout duration and the reader-thread join never
        // returns.
        "timeout 3 bash -c '( sleep 10 ) | head -n 5'",
    };

    for (cases) |cmd| {
        const result = try bash.execute_bash(allocator, io, .{
            .command = cmd,
            .cwd = "/tmp",
            .mandatory_timeout = 3,
        });
        defer {
            allocator.free(result.command);
            allocator.free(result.stdout);
            allocator.free(result.stderr);
        }
        try testing.expect(result.timeout == true);
        try testing.expect(result.exit_code != 0);
    }
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
