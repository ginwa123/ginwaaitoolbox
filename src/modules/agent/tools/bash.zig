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

    var trunc_buf: [53]u8 = undefined;
    const truncated_command = if (input.command.len > 50) blk: {
        trunc_buf[0..50].* = input.command[0..50].*;
        trunc_buf[50..53].* = "...".*;
        break :blk trunc_buf[0..53];
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
        .description =
        \\Execute a bash command and return:
        \\stdout, stderr, exit_code, truncated, timeout flags.
        \\
        \\All commands are validated before execution. Unsafe or malformed
        \\commands are rejected with exit_code=1 and must be retried.
        \\
        \\## Command Rules
        \\Every command MUST:
        \\- start with `timeout <seconds>`
        \\- limit output using `| head -n <N>`
        \\- avoid commands that produce unbounded output
        \\
        \\Commands violating these rules will be rejected.
        \\
        \\## Preferred Tools
        \\Use tools that allow controlled output:
        \\- `rg`        → code search (preferred over grep)
        \\- `wc -l`     → check file size before reading
        \\- `cat`       → read small files only
        \\- `stat`      → file metadata
        \\- `jq`        → JSON processing
        \\- `yq`        → YAML processing
        \\- `awk`       → structured text filtering
        \\
        \\## Reading Files
        \\Always check size first:
        \\`timeout 10 wc -l <file>`
        \\
        \\Recommended strategy:
        \\- <=300 lines → `timeout 10 cat <file> | head -n 300`
        \\- larger files → use `rg` to extract relevant sections
        \\
        \\## Output Limits
        \\Keep output small and focused.
        \\If output is truncated, refine the query instead of increasing limits.
        \\
        \\## Safety
        \\Avoid destructive or system-modifying commands.
        \\Never assume the working directory.
        ,
        .parameters = .{
            .type = "object",
            .properties = &.{
                .{
                    .name = "command",
                    .type = "string",
                    .description =
                    \\Command to execute.
                    \\Required format:
                    \\`timeout <seconds> <command> | head -n <N>`
                    \\
                    \\Examples:
                    \\GOOD: `timeout 10 wc -l src/main.zig`
                    \\GOOD: `timeout 10 cat src/main.zig | head -n 200`
                    \\GOOD: `timeout 10 rg 'MyStruct' src/ | head -n 50`
                    \\
                    \\BAD: `tree -R`
                    \\BAD: `cat bigfile`
                    \\BAD: `ls -R`
                    \\BAD: commands without timeout or output cap
                    ,
                },
                .{
                    .name = "cwd",
                    .type = "string",
                    .description =
                    \\Absolute working directory. Always set explicitly.
                    ,
                },
                .{
                    .name = "max_output",
                    .type = "number",
                    .description =
                    \\Maximum stdout+stderr bytes.
                    \\Default: 10000.
                    ,
                },
                .{
                    .name = "stdin_data",
                    .type = "string",
                    .description =
                    \\Optional stdin input for the command.
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
