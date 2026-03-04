const std = @import("std");
const posix = std.posix;
const BashInput = @import("models.zig").BashInput;
const ToolProperty = @import("models.zig").ToolProperty;
const ToolParameters = @import("models.zig").ToolParameters;
const AgentToolFunction = @import("models.zig").AgentToolFunction;
const AgentTool = @import("models.zig").AgentTool;

pub fn executeBash(allocator: std.mem.Allocator, input: BashInput) ![]const u8 {
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
    errdefer {
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

    var trunc_buf: [13]u8 = undefined;
    const truncated_command = if (input.command.len > 10) blk: {
        trunc_buf[0..10].* = input.command[0..10].*;
        trunc_buf[10..13].* = "...".*;
        break :blk trunc_buf[0..13];
    } else input.command;

    const output = try std.fmt.allocPrint(allocator,
        \\<command>{s}</command>
        \\<stdout>{s}</stdout>
        \\<stderr>{s}</stderr>
        \\<exit_code>{d}</exit_code>
        \\<truncated>{}</truncated>
        \\<timeout>{}</timeout>
    , .{
        truncated_command,
        if (stdout_data.items.len == 0) "No output produced." else stdout_data.items,
        if (stderr_data.items.len == 0) "No errors." else stderr_data.items,
        exit_code,
        was_truncated,
        timeout_hit,
    });

    stdout_data.deinit(allocator);
    stderr_data.deinit(allocator);

    return output;
}

pub const bashTool = AgentTool{
    .type = "function",
    .function = .{
        .name = "bash",
        .description = "Execute a bash command and return stdout, stderr, exit_code, truncated, and timeout flags. " ++
            "Optimized for precise, scoped CLI operations — fast text processing, file inspection, and structured data manipulation. " ++
            "" ++
            "PREFERRED TOOLS (use these by default): " ++
            "`rg` — fast regex search across files; " ++
            "`grep -n` — line-numbered matches; " ++
            "`sed -n 'X,Yp'` — extract line ranges without reading whole file; " ++
            "`awk` — field extraction and row filtering; " ++
            "`jq` — JSON query/transform (never use sed/awk on JSON); " ++
            "`yq` — YAML query/transform (never use sed/awk on YAML); " ++
            "`stat` / `ls -lh` — file metadata without reading content; " ++
            "`wc -l` / `du -sh` — size checks before any read. " ++
            "" ++
            "OUTPUT DISCIPLINE: " ++
            "Always bound output. Pipe through `head -n N`, `tail -n N`, or `rg --max-count=N`. " ++
            "Never emit unbounded streams. Set max_output conservatively. " ++
            "" ++
            "RULES (strictly enforced — never violate): " ++
            "1. NO privilege escalation — never use sudo, su, doas, or pkexec. " ++
            "2. NO full-file reads — use head/tail/sed ranges; always run `wc -l` first on unknown files. " ++
            "3. NO unbounded output — every pipeline must have an explicit output cap. " ++
            "4. NO sed/awk on structured data — use jq (JSON) or yq (YAML) exclusively. " ++
            "5. NO blind recursion — avoid `find /`, `cat **/*`, or unscoped recursive globs on large trees; check `du -sh` first. " ++
            "6. NO hanging commands — if stdin is required, provide stdin_data; otherwise stdin is closed immediately. " ++
            "7. ALWAYS set cwd explicitly — never rely on an assumed working directory. " ++
            "" ++
            "WORKFLOW PATTERN: " ++
            "Check size → scope the read → cap the output → parse structured data with the right tool. " ++
            "When in doubt, rg before cat.",
        .parameters = .{
            .type = "object",
            .properties = &.{
                .{
                    .name = "command",
                    .type = "string",
                    .description = "Bash command to execute. " ++
                        "Must be scoped and output-bounded. " ++
                        "Prefer: rg, grep -n, sed -n 'X,Yp', awk, jq, stat, wc. " ++
                        "Avoid: cat <file>, find / (unscoped), recursive globs without size checks. " ++
                        "Chain with | head -n N or | rg --max-count=N to cap output.",
                },
                .{
                    .name = "timeout",
                    .type = "number",
                    .description = "Max execution time in seconds. Default: 30. Max: 120. " ++
                        "If exceeded, the process is killed and timeout=true is set in the response. " ++
                        "Use lower values for reads/searches; higher only for compiles or network ops.",
                },
                .{
                    .name = "cwd",
                    .type = "string",
                    .description = "Absolute working directory for the command. REQUIRED — always set explicitly. " ++
                        "Never assume the current directory. All relative paths in the command resolve from here.",
                },
                .{
                    .name = "max_output",
                    .type = "number",
                    .description = "Max combined stdout+stderr in bytes. Default: 102400 (100KB). Max: 1048576 (1MB). " ++
                        "If exceeded, output is truncated and truncated=true is set. " ++
                        "Keep low for file reads and searches. Raise only for known-large structured outputs (e.g. JSON dumps).",
                },
                .{
                    .name = "stdin_data",
                    .type = "string",
                    .description = "Optional data piped to the command's stdin. " ++
                        "If omitted, stdin is closed immediately — do not run interactive or stdin-blocking commands without this.",
                },
            },
            .required = &.{ "command", "cwd", "timeout" },
        },
    },
};

// example how to use this tool
// const bashTool = AgentTool{
//     .type = "function",
//     .function = .{
//         .name = "bash",
//         .description = "Execute a bash command and return stdout and stderr output",
//         .parameters = .{
//             .type = "object",
//             .properties = &.{
//                 .{
//                     .name = "command",
//                     .type = "string",
//                     .description = "The bash command to execute",
//                 },
//                 .{
//                     .name = "timeout",
//                     .type = "number",
//                     .description = "Timeout in seconds, default 30",
//                 },
//                 .{
//                     .name = "cwd",
//                     .type = "string",
//                     .description = "Working directory to run the command in",
//                 },
//                 .{
//                     .name = "max_output",
//                     .type = "number",
//                     .description = "Max output size in bytes, default 1048576 (1MB). Increase if output is truncated",
//                 },
//             },
//             .required = &.{"command"},
//         },
//     },
// };
