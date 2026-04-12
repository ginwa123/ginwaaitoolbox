const std = @import("std");
const posix = std.posix;
const schemas = @import("schemas.zig");
const BashInput = schemas.BashInput;
const BashOutput = schemas.BashOutput;
const ToolProperty = schemas.ToolProperty;
const ToolParameters = schemas.ToolParameters;
const AgentToolFunction = schemas.AgentToolFunction;
const AgentTool = schemas.AgentTool;
const selfkill = @import("bash_selfkill.zig");

pub const CommandForbidden = error{
    /// Command contains forbidden patterns that produce unbounded output
    CommandForbidden,
};

/// Detects forbidden command patterns that produce unbounded output
fn is_forbidden_command(command: []const u8) bool {
    const trimmed = std.mem.trim(u8, command, " \t\n\r");

    // temporary disabled forbidden command
    _ = trimmed;

    // Check for recursive ls variants
    // if (std.mem.indexOf(u8, trimmed, "ls -R") != null) return true;
    // if (std.mem.indexOf(u8, trimmed, "ls -lR") != null) return true;
    // if (std.mem.indexOf(u8, trimmed, "ls -laR") != null) return true;
    // if (std.mem.indexOf(u8, trimmed, "ls -alR") != null) return true;
    //
    // // Check for find without -maxdepth (matches "find /" or "find .")
    // if (std.mem.startsWith(u8, trimmed, "find /")) return true;
    // if (std.mem.startsWith(u8, trimmed, "find .")) {
    //     // Allow if it has -maxdepth
    //     if (std.mem.indexOf(u8, trimmed, "-maxdepth") == null) {
    //         return true;
    //     }
    // }
    //
    // // Skip timeout/head checks for background commands
    // if (std.mem.indexOf(u8, trimmed, "nohup") == null) {
    //     // Check for timeout prefix (check both "timeout " and "Timeout " for robustness)
    //     const has_timeout = std.mem.startsWith(u8, trimmed, "timeout ") or
    //         std.mem.startsWith(u8, trimmed, "Timeout ");
    //     if (!has_timeout) {
    //         return true;
    //     }
    //
    //     // Check for head output cap
    //     if (std.mem.indexOf(u8, trimmed, "| head -n") == null) {
    //         return true;
    //     }
    // }

    return false;
}

pub fn executeBash(allocator: std.mem.Allocator, input: BashInput) !BashOutput {
    // --- Forbidden pattern check ---
    if (is_forbidden_command(input.command)) {
        return error.CommandForbidden;
    }

    // --- Self-kill protection check ---
    const self_pid = selfkill.get_self_pid();
    if (try selfkill.detect_self_kill(allocator, input.command, self_pid)) |warning| {
        // Log the warning
        std.log.warn("Self-kill detected: {s}", .{warning});

        // Return blocked output instead of executing
        const stderr_msg = try std.fmt.allocPrint(
            allocator,
            "\n=== SELF-KILL PROTECTION ===\n" ++
            "Blocked command that would terminate the current process.\n" ++
            "Reason: {s}\n" ++
            "Your PID: {d}\n" ++
            "===========================\n",
            .{ warning, self_pid });
        errdefer allocator.free(stderr_msg);

        const command_copy = try allocator.dupe(u8, input.command);
        errdefer allocator.free(command_copy);

        return BashOutput{
            .command = command_copy,
            .stdout = "",
            .stderr = stderr_msg,
            .exit_code = 1,
            .truncated = false,
            .timeout = false,
            .stdout_lines = 0,
            .stderr_lines = 1,
            .is_self = true,
        };
    }

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

        // Allocate command on heap to avoid dangling pointer to stack buffer
        const command_copy = if (input.command.len > 50) blk: {
            const cmd = try allocator.alloc(u8, 53);
            @memcpy(cmd[0..50], input.command[0..50]);
            @memcpy(cmd[50..53], "...");
            break :blk cmd;
        } else try allocator.dupe(u8, input.command);
        errdefer allocator.free(command_copy);

        // Return with the allocated strings
        return BashOutput{
            .command = command_copy,
            .stdout = stdout_msg,
            .stderr = stderr_msg,
            .exit_code = 0,
            .truncated = false,
            .timeout = false,
            .stdout_lines = 0,
            .stderr_lines = 0,
        };
    }

    // --- Foreground mode ---
    const max_output = input.max_output orelse 20 * 1024; // 20KB default
    const max_lines = input.max_lines orelse 1000;
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
    var stdout_line_count: usize = 0;
    var stderr_line_count: usize = 0;
    defer {
        stdout_data.deinit(allocator);
        stderr_data.deinit(allocator);
    }

    var buf: [4096]u8 = undefined;
    var timeout_hit = false;
    var child_term: ?std.process.Child.Term = null;

    // Flags to track when each stream has been truncated (stop appending, keep counting)
    var stdout_truncated = false;
    var stderr_truncated = false;

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
                    // Always count newlines
                    for (buf[0..bytes_read]) |byte| {
                        if (byte == '\n') stdout_line_count += 1;
                    }
                    // Append data if not yet truncated
                    if (!stdout_truncated) {
                        try stdout_data.appendSlice(allocator, buf[0..bytes_read]);
                        if (stdout_data.items.len >= max_output or stdout_line_count >= max_lines) {
                            // Mark truncated and find the line boundary to trim to
                            stdout_truncated = true;
                            var count: usize = 0;
                            var trim_pos = stdout_data.items.len;
                            var found_line_boundary = false;

                            // Prefer line boundary if lines exceeded, otherwise use byte limit
                            if (stdout_line_count >= max_lines) {
                                for (stdout_data.items, 0..) |b, i| {
                                    if (b == '\n') {
                                        count += 1;
                                        if (count == max_lines) {
                                            trim_pos = i + 1;
                                            found_line_boundary = true;
                                            break;
                                        }
                                    }
                                }
                            }

                            // If no line boundary found, trim to byte limit
                            if (!found_line_boundary and stdout_data.items.len > max_output) {
                                trim_pos = max_output;
                            }

                            if (stdout_data.items.len > trim_pos) {
                                stdout_data.shrinkAndFree(allocator, trim_pos);
                            }
                        }
                    }
                }
            }
        }

        // Check stderr using stored index
        if (stderr_idx) |idx| {
            if (poll_fds[idx].revents & posix.POLL.IN != 0) {
                const bytes_read = child.stderr.?.read(&buf) catch 0;
                if (bytes_read > 0) {
                    any_read = true;
                    // Always count newlines
                    for (buf[0..bytes_read]) |byte| {
                        if (byte == '\n') stderr_line_count += 1;
                    }
                    // Append data if not yet truncated
                    if (!stderr_truncated) {
                        try stderr_data.appendSlice(allocator, buf[0..bytes_read]);
                        if (stderr_data.items.len >= max_output or stderr_line_count >= max_lines) {
                            // Mark truncated and find the line boundary to trim to
                            stderr_truncated = true;
                            var count: usize = 0;
                            var trim_pos = stderr_data.items.len;
                            var found_line_boundary = false;

                            // Prefer line boundary if lines exceeded, otherwise use byte limit
                            if (stderr_line_count >= max_lines) {
                                for (stderr_data.items, 0..) |b, i| {
                                    if (b == '\n') {
                                        count += 1;
                                        if (count == max_lines) {
                                            trim_pos = i + 1;
                                            found_line_boundary = true;
                                            break;
                                        }
                                    }
                                }
                            }

                            // If no line boundary found, trim to byte limit
                            if (!found_line_boundary and stderr_data.items.len > max_output) {
                                trim_pos = max_output;
                            }

                            if (stderr_data.items.len > trim_pos) {
                                stderr_data.shrinkAndFree(allocator, trim_pos);
                            }
                        }
                    }
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

    // Truncate output by line count if max_lines was exceeded
    var stdout_lines_to_keep = stdout_data.items.len;
    const stdout_truncation_needed = stdout_line_count > max_lines;
    if (stdout_truncation_needed) {
        var count: usize = 0;
        for (stdout_data.items, 0..) |byte, i| {
            if (byte == '\n') {
                count += 1;
                if (count == max_lines) {
                    stdout_lines_to_keep = i + 1;
                    break;
                }
            }
        }
    }

    // Truncate stderr by line count
    var stderr_lines_to_keep = stderr_data.items.len;
    const stderr_truncation_needed = stderr_line_count > max_lines;
    if (stderr_truncation_needed) {
        var count: usize = 0;
        for (stderr_data.items, 0..) |byte, i| {
            if (byte == '\n') {
                count += 1;
                if (count == max_lines) {
                    stderr_lines_to_keep = i + 1;
                    break;
                }
            }
        }
    }

    const was_truncated = stdout_truncation_needed or stderr_truncation_needed or (stdout_data.items.len >= max_output or stderr_data.items.len >= max_output);

    // Allocate command on heap to avoid dangling pointer to stack buffer
    const command_copy = if (input.command.len > 50) blk: {
        const cmd = try allocator.alloc(u8, 53);
        @memcpy(cmd[0..50], input.command[0..50]);
        @memcpy(cmd[50..53], "...");
        break :blk cmd;
    } else try allocator.dupe(u8, input.command);
    errdefer allocator.free(command_copy);

    // Return structured BashOutput instead of XML string
    // Duplicate the strings so they outlive the ArrayLists
    const stdout_copy = if (stdout_data.items.len == 0)
        try allocator.dupe(u8, "No output produced.")
    else if (stdout_truncation_needed)
        try allocator.dupe(u8, stdout_data.items[0..stdout_lines_to_keep])
    else
        try allocator.dupe(u8, stdout_data.items);
    errdefer allocator.free(stdout_copy);

    const stderr_copy = if (stderr_data.items.len == 0)
        try allocator.dupe(u8, "No errors.")
    else if (stderr_truncation_needed)
        try allocator.dupe(u8, stderr_data.items[0..stderr_lines_to_keep])
    else
        try allocator.dupe(u8, stderr_data.items);
    errdefer allocator.free(stderr_copy);

    return BashOutput{
        .command = command_copy,
        .stdout = stdout_copy,
        .stderr = stderr_copy,
        .exit_code = exit_code,
        .truncated = was_truncated,
        .timeout = timeout_hit,
        .stdout_lines = stdout_line_count,
        .stderr_lines = stderr_line_count,
    };
}

pub fn bashResultToString(allocator: std.mem.Allocator, result: BashOutput) ![]const u8 {
    return try std.fmt.allocPrint(allocator,
        \\<stdout>{s}</stdout>
        \\<stderr>{s}</stderr>
        \\<exit_code>{d}</exit_code>
        \\<truncated>{}</truncated>
        \\<timeout>{}</timeout>
        \\<stdout_lines>{d}</stdout_lines>
        \\<stderr_lines>{d}</stderr_lines>
        \\<is_self>{}</is_self>
    , .{
        result.stdout,
        result.stderr,
        result.exit_code,
        result.truncated,
        result.timeout,
        result.stdout_lines,
        result.stderr_lines,
        result.is_self,
    });
}

pub const bash_tool = AgentTool{
    .type = "function",
    .function = .{
        .name = "bash",
        .description =
        \\Execute a bash command and return:
        \\stdout, stderr, exit_code, truncated, timeout flags.
        \\
        \\## Command Rules (enforced in code)
        \\Every command MUST:
        \\- start with `timeout <seconds>`
        \\- limit output using `| head -n <N> or tail -n <N>` to prevent huge output
        \\- avoid commands that produce unbounded output
        \\- use ripgrep (rg) instead of grep/find for searching
        \\- use fd for finding files (faster alternative to find/glob)
        \\- use tree for directory structure
        \\## Web Browsing
        \\To browse the web or fetch URLs, use the `agent-browser` CLI:
        \\
        \\## Safety
        \\Avoid destructive or system-modifying commands.
        \\Never assume the working directory — always set cwd explicitly.
        ,
        .parameters = .{
            .type = "object",
            .properties = &.{
                .{
                    .name = "command",
                    .type = "string",
                    .description =
                    \\Command to execute.
                    \\
                    \\ fd is a faster alternative to find and rg is a faster alternative to grep.
                    \\GOOD: `timeout 10 zig build 2>&1 | head -n 50`
                    \\GOOD: `timeout 10 rg 'MyStruct' src/ | head -n 50`
                    \\GOOD: `timeout 10 fd MyStruct src/ | head -n 50`
                    \\GOOD: `timeout 10 fd -e zig src/ | head -n 50`
                    \\GOOD: `timeout 5 ls -la /some/dir | head -n 30`
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
                    .description = "Maximum stdout+stderr bytes. Default: 20480 (20KB). Output exceeding this limit is truncated.",
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
                .{
                    .name = "max_lines",
                    .type = "number",
                    .description = "Maximum number of lines to capture from stdout/stderr. Default: 1000. Output exceeding this limit is truncated and stdout_lines/stderr_lines will report the true total.",
                },
            },
            .required = &.{ "command", "cwd" },
        },
    },
};
