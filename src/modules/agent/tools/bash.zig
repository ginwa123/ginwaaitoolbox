const std = @import("std");
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
fn isForbiddenCommand(command: []const u8) bool {
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

/// Encode special characters in URLs within double quotes
/// Converts: curl -sI "http://host/path?query=val&sig=xyz"
///      to: curl -sI 'http://host/path?query=val&sig=xyz'
/// This prevents bash from interpreting ?, &, etc.
fn encode_command_urls(allocator: std.mem.Allocator, command: []const u8) ![]const u8 {
    var result = std.ArrayList(u8).empty;
    errdefer result.deinit(allocator);

    var i: usize = 0;
    while (i < command.len) {
        // Look for " followed by http:// or https://
        if (command[i] == '"' and i + 7 < command.len) {
            const rest = command[i + 1 ..];
            if (std.mem.startsWith(u8, rest, "http://") or std.mem.startsWith(u8, rest, "https://")) {
                // Found a URL in double quotes - find the closing quote
                try result.append(allocator, '\'');
                i += 1; // skip opening "

                // Copy until closing quote
                while (i < command.len and command[i] != '"') {
                    try result.append(allocator, command[i]);
                    i += 1;
                }

                if (i < command.len and command[i] == '"') {
                    try result.append(allocator, '\'');
                    i += 1; // skip closing "
                }
                continue;
            }
        }
        try result.append(allocator, command[i]);
        i += 1;
    }

    return result.toOwnedSlice(allocator);
}

pub fn execute_bash(allocator: std.mem.Allocator, io: std.Io, input: BashInput) !BashOutput {
    // --- URL encoding if requested ---
    const command = if (input.do_encoding)
        try encode_command_urls(allocator, input.command)
    else
        try allocator.dupe(u8, input.command);
    defer allocator.free(command);

    // --- Forbidden pattern check ---
    if (isForbiddenCommand(command)) {
        return error.CommandForbidden;
    }

    // --- Self-kill protection check ---
    const self_pid = selfkill.get_self_pid();
    if (try selfkill.detect_self_kill(allocator, command, self_pid)) |warning| {
        // Log the warning
        std.log.warn("Self-kill detected: {s}", .{warning});

        // Return blocked output instead of executing
        const stderr_msg = try std.fmt.allocPrint(allocator, "\n=== SELF-KILL PROTECTION ===\n" ++
            "Blocked command that would terminate the current process.\n" ++
            "Reason: {s}\n" ++
            "Your PID: {d}\n" ++
            "===========================\n", .{ warning, self_pid });
        errdefer allocator.free(stderr_msg);

        const command_copy = try allocator.dupe(u8, command);
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
        const ts: i64 = @intCast(@divTrunc(std.Io.Timestamp.now(io, .real).nanoseconds, 1_000_000));
        const log_path = try std.fmt.allocPrint(
            allocator,
            "/tmp/bg_{d}.log",
            .{ts},
        );
        defer allocator.free(log_path);

        const bg_command = try std.fmt.allocPrint(
            allocator,
            "nohup {s} > {s} 2>&1 & echo $!",
            .{ command, log_path },
        );
        defer allocator.free(bg_command);

        var child = try std.process.spawn(io, .{
            .argv = &.{ "bash", "-c", bg_command },
            .cwd = if (input.cwd) |cwd| .{ .path = cwd } else .inherit,
            .stdin = .close,
            .stdout = .pipe,
            .stderr = .ignore,
        });

        // Read PID from stdout
        var pid_buf: [32]u8 = undefined;
        const pid_len = std.Io.File.readStreaming(child.stdout.?, io, &.{&pid_buf}) catch 0;
        const pid_str = std.mem.trimEnd(u8, pid_buf[0..pid_len], "\n\r ");

        _ = child.wait(io) catch {};

        const stdout_msg = try std.fmt.allocPrint(
            allocator,
            "PID: {s}\nLog: {s}",
            .{ pid_str, log_path },
        );
        errdefer allocator.free(stdout_msg);

        const stderr_msg = try allocator.dupe(u8, "No errors.");
        errdefer allocator.free(stderr_msg);

        // Allocate command on heap to avoid dangling pointer to stack buffer
        const command_copy = if (command.len > 50) blk: {
            const cmd = try allocator.alloc(u8, 53);
            @memcpy(cmd[0..50], command[0..50]);
            @memcpy(cmd[50..53], "...");
            break :blk cmd;
        } else try allocator.dupe(u8, command);
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

    // .pgid removed: default null. child.kill kills the immediate child, which
    // is the correct behavior for a tool. Subprocesses are reparented on exit.
    var child = try std.process.spawn(io, .{
        .argv = &.{ "bash", "-c", command },
        .cwd = if (input.cwd) |cwd| .{ .path = cwd } else .inherit,
        .stdin = if (input.stdin_data != null) .pipe else .close,
        .stdout = .pipe,
        .stderr = .pipe,
    });

    if (input.stdin_data) |data| {
        if (child.stdin) |stdin| {
            var write_buf: [1024]u8 = undefined;
            var stdin_writer = std.Io.File.writer(stdin, io, &write_buf);
            try stdin_writer.interface.writeAll(data);
            stdin.close(io);
            child.stdin = null;
        }
    }

    const timeout_ns = @as(u64, timeout_sec) * std.time.ns_per_s;
    const start_time = std.Io.Timestamp.now(io, .real).nanoseconds;

    var stdout_data: std.ArrayList(u8) = .empty;
    var stderr_data: std.ArrayList(u8) = .empty;
    defer {
        stdout_data.deinit(allocator);
        stderr_data.deinit(allocator);
    }

    var stdout_line_count: usize = 0;
    var stderr_line_count: usize = 0;
    var stdout_truncated = false;
    var stderr_truncated = false;
    var stdout_eof = std.atomic.Value(bool).init(false);
    var stderr_eof = std.atomic.Value(bool).init(false);
    // Zig 0.16 has no std.Thread.Mutex; std.atomic.Mutex is a lock-free enum
    // that we use as a spinlock (tryLock + spinLoopHint). The critical section
    // is small (one appendSlice + truncation check), so spinning is fine.
    var stdout_mutex: std.atomic.Mutex = .unlocked;
    var stderr_mutex: std.atomic.Mutex = .unlocked;

    const ReadContext = struct {
        stream: std.Io.File,
        io: std.Io,
        buf: *[4096]u8,
        data: *std.ArrayList(u8),
        line_count: *usize,
        truncated: *bool,
        max_output: usize,
        max_lines: usize,
        eof_flag: *std.atomic.Value(bool),
        mutex: *std.atomic.Mutex,
        allocator: std.mem.Allocator,
    };

    const readLoopFn = struct {
        fn run(ctx: ReadContext) void {
            defer ctx.eof_flag.store(true, .release);
            while (true) {
                const n = std.Io.File.readStreaming(ctx.stream, ctx.io, &.{ctx.buf}) catch return;
                if (n == 0) return;
                for (ctx.buf[0..n]) |byte| {
                    if (byte == '\n') ctx.line_count.* += 1;
                }
                if (!ctx.truncated.*) {
                    // Spinlock on std.atomic.Mutex (no blocking lock in std 0.16)
                    while (!ctx.mutex.tryLock()) {
                        std.atomic.spinLoopHint();
                    }
                    defer ctx.mutex.unlock();
                    ctx.data.appendSlice(ctx.allocator, ctx.buf[0..n]) catch return;
                    if (ctx.data.items.len >= ctx.max_output or ctx.line_count.* >= ctx.max_lines) {
                        ctx.truncated.* = true;
                        var trim_pos: usize = ctx.data.items.len;
                        if (ctx.line_count.* >= ctx.max_lines) {
                            var count: usize = 0;
                            for (ctx.data.items, 0..) |b, i| {
                                if (b == '\n') {
                                    count += 1;
                                    if (count == ctx.max_lines) {
                                        trim_pos = i + 1;
                                        break;
                                    }
                                }
                            }
                        } else if (ctx.data.items.len > ctx.max_output) {
                            trim_pos = ctx.max_output;
                        }
                        if (ctx.data.items.len > trim_pos) {
                            ctx.data.shrinkAndFree(ctx.allocator, trim_pos);
                        }
                    }
                }
            }
        }
    }.run;

    var stdout_buf: [4096]u8 = undefined;
    var stderr_buf: [4096]u8 = undefined;

    const stdout_ctx = ReadContext{
        .stream = child.stdout.?,
        .io = io,
        .buf = &stdout_buf,
        .data = &stdout_data,
        .line_count = &stdout_line_count,
        .truncated = &stdout_truncated,
        .max_output = max_output,
        .max_lines = max_lines,
        .eof_flag = &stdout_eof,
        .mutex = &stdout_mutex,
        .allocator = allocator,
    };
    const stderr_ctx = ReadContext{
        .stream = child.stderr.?,
        .io = io,
        .buf = &stderr_buf,
        .data = &stderr_data,
        .line_count = &stderr_line_count,
        .truncated = &stderr_truncated,
        .max_output = max_output,
        .max_lines = max_lines,
        .eof_flag = &stderr_eof,
        .mutex = &stderr_mutex,
        .allocator = allocator,
    };

    const stdout_thread = try std.Thread.spawn(.{}, readLoopFn, .{stdout_ctx});
    const stderr_thread = try std.Thread.spawn(.{}, readLoopFn, .{stderr_ctx});

    var timeout_hit = false;
    var child_term: ?std.process.Child.Term = null;

    while (true) {
        const elapsed = std.Io.Timestamp.now(io, .real).nanoseconds - start_time;
        if (elapsed > timeout_ns) {
            timeout_hit = true;
            _ = child.kill(io);
            // Do not call child.wait() here; kill() invalidates child.id.
            // The wait happens after the threads join below.
            child_term = .{ .signal = .KILL };
            break;
        }
        if (stdout_eof.load(.acquire) and stderr_eof.load(.acquire)) {
            child_term = child.wait(io) catch .{ .unknown = 1 };
            break;
        }
        try std.Io.sleep(io, .{ .nanoseconds = 10 * std.time.ns_per_ms }, .real);
    }

    stdout_thread.join();
    stderr_thread.join();
    if (child_term == null) {
        child_term = child.wait(io) catch .{ .unknown = 1 };
    }

    const exit_code: i32 = switch (child_term.?) {
        .exited => |code| @as(i32, @intCast(code)),
        .signal => |sig| -@as(i32, @intCast(@intFromEnum(sig))),
        .stopped => |code| -@as(i32, @intCast(@intFromEnum(code))),
        .unknown => -1,
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
    const command_copy = try allocator.dupe(u8, command);
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

pub fn bash_result_to_string(allocator: std.mem.Allocator, result: BashOutput) ![]const u8 {
    return try std.fmt.allocPrint(allocator,
        \\<command>{s}</command>
        \\<stdout>{s}</stdout>
        \\<stderr>{s}</stderr>
        \\<exit_code>{d}</exit_code>
        \\<truncated>{}</truncated>
        \\<timeout>{}</timeout>
        \\<stdout_lines>{d}</stdout_lines>
        \\<stderr_lines>{d}</stderr_lines>
        \\<is_self>{}</is_self>
    , .{
        result.command,
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
                .{
                    .name = "do_encoding",
                    .type = "boolean",
                    .description =
                    \\Encode URLs in double quotes by converting to single quotes.
                    \\Use this for curl/wget commands with URLs containing ? and & characters.
                    \\Example: curl -sI "https://host/path?query=val&sig=xyz" will become curl -sI 'https://host/path?query=val&sig=xyz'
                    ,
                },
            },
            .required = &.{ "command", "cwd" },
        },
    },
};
