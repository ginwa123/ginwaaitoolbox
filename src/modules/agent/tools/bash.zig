const std = @import("std");
const posix = std.posix;
const BashInput = @import("models.zig").BashInput;
const BashOutput = @import("models.zig").BashOutput;
const ToolProperty = @import("models.zig").ToolProperty;
const ToolParameters = @import("models.zig").ToolParameters;
const AgentToolFunction = @import("models.zig").AgentToolFunction;
const AgentTool = @import("models.zig").AgentTool;

pub fn executeBash(allocator: std.mem.Allocator, input: BashInput) !BashOutput {
    // --- Background mode ---
    if (input.background) {
        const ts = std.time.milliTimestamp();
        const log_path = try std.fmt.allocPrint(
            allocator,
            "/tmp/bg_{d}.log",
            .{ts},
        );
        defer allocator.free(log_path);

        const bg_command = try std.fmt.allocPrint(
            allocator,
            "nohup {s} > {s} 2>&1 & echo $!",
            .{ input.command, log_path },
        );
        defer allocator.free(bg_command);

        var child = std.process.Child.init(&.{ "bash", "-c", bg_command }, allocator);
        if (input.cwd) |cwd| child.cwd = cwd;
        child.stdin_behavior = .Close;
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Ignore;
        try child.spawn();

        // Read PID from stdout
        var pid_buf: [32]u8 = undefined;
        const pid_len = child.stdout.?.read(&pid_buf) catch 0;
        const pid_str = std.mem.trimRight(u8, pid_buf[0..pid_len], "\n\r ");

        _ = child.wait() catch {};

        const stdout_msg = try std.fmt.allocPrint(
            allocator,
            "PID: {s}\nLog: {s}",
            .{ pid_str, log_path },
        );
        errdefer allocator.free(stdout_msg);

        const stderr_msg = try allocator.dupe(u8, "No errors.");
        errdefer allocator.free(stderr_msg);

        var trunc_buf: [53]u8 = undefined;
        const truncated_command = if (input.command.len > 50) blk: {
            trunc_buf[0..50].* = input.command[0..50].*;
            trunc_buf[50..53].* = "...".*;
            break :blk trunc_buf[0..53];
        } else input.command;

        // Return with the allocated stdout_msg as the stdout
        return BashOutput{
            .command = truncated_command,
            .stdout = stdout_msg,
            .stderr = stderr_msg,
            .exit_code = 0,
            .truncated = false,
            .timeout = false,
        };
    }

    // --- Foreground mode ---
    const max_output = input.max_output orelse 1024 * 1024;
    const timeout_sec = input.timeout orelse 30;

    var child = std.process.Child.init(&.{ "bash", "-c", input.command }, allocator);
    if (input.cwd) |cwd| {
        child.cwd = cwd;
    }
    child.stdin_behavior = if (input.stdin_data != null) .Pipe else .Close;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;

    try child.spawn();

    if (input.stdin_data) |data| {
        if (child.stdin) |stdin| {
            try stdin.writeAll(data);
            stdin.close();
            child.stdin = null;
        }
    }

    const timeout_ns = @as(u64, timeout_sec) * std.time.ns_per_s;
    const start_time = std.time.nanoTimestamp();

    const ArrayList = std.ArrayList;
    var stdout_data: ArrayList(u8) = .empty;
    var stderr_data: ArrayList(u8) = .empty;
    defer {
        stdout_data.deinit(allocator);
        stderr_data.deinit(allocator);
    }

    var buf: [4096]u8 = undefined;
    var timeout_hit = false;
    var child_term: ?std.process.Child.Term = null;

    // Prepare poll fds for stdout and stderr
    var poll_fds: [2]posix.pollfd = undefined;
    var poll_count: usize = 0;
    var stdout_idx: ?usize = null;
    var stderr_idx: ?usize = null;

    if (child.stdout) |_| {
        stdout_idx = poll_count;
        poll_fds[poll_count] = .{
            .fd = child.stdout.?.handle,
            .events = posix.POLL.IN,
            .revents = 0,
        };
        poll_count += 1;
    }

    if (child.stderr) |_| {
        stderr_idx = poll_count;
        poll_fds[poll_count] = .{
            .fd = child.stderr.?.handle,
            .events = posix.POLL.IN,
            .revents = 0,
        };
        poll_count += 1;
    }

    while (true) {
        // Check timeout first
        const elapsed = std.time.nanoTimestamp() - start_time;
        if (elapsed > timeout_ns) {
            timeout_hit = true;
            _ = child.kill() catch {};
            child_term = child.wait() catch .{ .Unknown = 1 };
            break;
        }

        // Calculate remaining time for poll (max 100ms per poll call)
        const remaining_ns = timeout_ns - @as(u64, @intCast(elapsed));
        const poll_timeout_ms = @min(100, @as(i32, @intCast(@divFloor(remaining_ns, std.time.ns_per_ms))));

        // Poll for available data - this won't block longer than poll_timeout_ms
        const ready = posix.poll(poll_fds[0..poll_count], poll_timeout_ms) catch 0;

        if (ready == 0) {
            // Poll timed out with no data - loop back to check overall timeout
            continue;
        }

        // Read from ready file descriptors
        var any_read = false;

        // Check stdout using stored index
        if (stdout_idx) |idx| {
            if (poll_fds[idx].revents & posix.POLL.IN != 0) {
                const bytes_read = child.stdout.?.read(&buf) catch 0;
                if (bytes_read > 0) {
                    any_read = true;
                    try stdout_data.appendSlice(allocator, buf[0..bytes_read]);
                    if (stdout_data.items.len >= max_output) break;
                }
            }
        }

        // Check stderr using stored index
        if (stderr_idx) |idx| {
            if (poll_fds[idx].revents & posix.POLL.IN != 0) {
                const bytes_read = child.stderr.?.read(&buf) catch 0;
                if (bytes_read > 0) {
                    any_read = true;
                    try stderr_data.appendSlice(allocator, buf[0..bytes_read]);
                    if (stderr_data.items.len >= max_output) break;
                }
            }
        }

        // Check if child has exited (pipes closed = process ended)
        const all_closed = for (poll_fds[0..poll_count]) |pf| {
            if (pf.revents & (posix.POLL.HUP | posix.POLL.ERR) == 0) break false;
        } else true;

        if (all_closed or (!any_read and ready > 0)) {
            // Pipes closed or poll returned but no data = process likely exited
            child_term = child.wait() catch .{ .Unknown = 1 };
            break;
        }
    }

    if (child_term == null) {
        child_term = child.wait() catch .{ .Unknown = 1 };
    }

    const exit_code: i32 = switch (child_term.?) {
        .Exited => |code| @as(i32, @intCast(code)),
        .Signal => |sig| -@as(i32, @intCast(sig)),
        .Stopped => |code| -@as(i32, @intCast(code)),
        .Unknown => -1,
    };

    const was_truncated = stdout_data.items.len >= max_output or stderr_data.items.len >= max_output;

    var trunc_buf: [53]u8 = undefined;
    const truncated_command = if (input.command.len > 50) blk: {
        trunc_buf[0..50].* = input.command[0..50].*;
        trunc_buf[50..53].* = "...".*;
        break :blk trunc_buf[0..53];
    } else input.command;

    // Return structured BashOutput instead of XML string
    // Duplicate the strings so they outlive the ArrayLists
    const stdout_copy = if (stdout_data.items.len == 0)
        try allocator.dupe(u8, "No output produced.")
    else
        try allocator.dupe(u8, stdout_data.items);
    errdefer allocator.free(stdout_copy);

    const stderr_copy = if (stderr_data.items.len == 0)
        try allocator.dupe(u8, "No errors.")
    else
        try allocator.dupe(u8, stderr_data.items);
    errdefer allocator.free(stderr_copy);

    return BashOutput{
        .command = truncated_command,
        .stdout = stdout_copy,
        .stderr = stderr_copy,
        .exit_code = exit_code,
        .truncated = was_truncated,
        .timeout = timeout_hit,
    };
}

pub fn bashResultToString(allocator: std.mem.Allocator, result: BashOutput) ![]const u8 {
    return try std.fmt.allocPrint(allocator,
        \\<command>{s}</command>
        \\<stdout>{s}</stdout>
        \\<stderr>{s}</stderr>
        \\<exit_code>{d}</exit_code>
        \\<truncated>{}</truncated>
        \\<timeout>{}</timeout>
    , .{
        result.command,
        result.stdout,
        result.stderr,
        result.exit_code,
        result.truncated,
        result.timeout,
    });
}

pub const bashTool = AgentTool{
    .type = "function",
    .function = .{
        .name = "bash",
        .description =
        \\Execute a bash command and return:
        \\stdout, stderr, exit_code, truncated, timeout flags.
        \\
        \\## Command Rules
        \\Every command MUST:
        \\- start with `timeout <seconds>`
        \\- limit output using `| head -n <N>`
        \\- avoid commands that produce unbounded output
        \\
        \\## Safety
        \\Avoid destructive or system-modifying commands.
        \\Never assume the working directory.
        \\Never use commands that produce unbounded output (e.g. `ls -R`, `find /`, `cat <large-file>`).
        ,
        .parameters = .{
            .type = "object",
            .properties = &.{
                .{
                    .name = "command",
                    .type = "string",
                    .description =
                    \\Command to execute.
                    \\Required format: `timeout <seconds> <command> | head -n <N>`
                    \\
                    \\GOOD: `timeout 10 zig build 2>&1 | head -n 50`
                    \\GOOD: `timeout 10 rg 'MyStruct' src/ | head -n 50`
                    \\BAD:  `cat src/main.zig`  ← use read_file instead
                    \\BAD:  `sed -n '10,20p'`   ← use read_file instead
                    \\BAD:  commands without timeout or output cap
                    ,
                },
                .{
                    .name = "cwd",
                    .type = "string",
                    .description = "Absolute working directory. Always set explicitly.",
                },
                .{
                    .name = "max_output",
                    .type = "number",
                    .description = "Maximum stdout+stderr bytes. Default: 10000.",
                },
                .{
                    .name = "stdin_data",
                    .type = "string",
                    .description = "Optional stdin input for the command.",
                },
                .{
                    .name = "background",
                    .type = "boolean",
                    .description =
                    \\Run command in background using nohup.
                    \\Returns PID and log path in stdout.
                    \\Example stdout: "PID: 12345\nLog: /tmp/bg_1234567890.log"
                    \\Use PID to check status (ps -p <PID>) or kill (kill <PID>).
                    ,
                },
            },
            .required = &.{ "command", "cwd" },
        },
    },
};

test {
    _ = @import("bash_test.zig");
}
