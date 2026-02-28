const std = @import("std");
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

    while (true) {
        const elapsed = std.time.nanoTimestamp() - start_time;
        if (elapsed > timeout_ns) {
            timeout_hit = true;
            _ = child.kill() catch {};
            child_term = child.wait() catch .{ .Unknown = 1 };
            break;
        }

        var any_read = false;

        if (child.stdout) |stdout| {
            const bytes_read = stdout.read(&buf) catch 0;
            if (bytes_read > 0) {
                any_read = true;
                try stdout_data.appendSlice(allocator, buf[0..bytes_read]);
                if (stdout_data.items.len >= max_output) break;
            }
        }

        if (child.stderr) |stderr| {
            const bytes_read = stderr.read(&buf) catch 0;
            if (bytes_read > 0) {
                any_read = true;
                try stderr_data.appendSlice(allocator, buf[0..bytes_read]);
                if (stderr_data.items.len >= max_output) break;
            }
        }

        if (!any_read) {
            child_term = child.wait() catch .{ .Unknown = 1 };
            if (child_term) |term| {
                if (term == .Exited or term == .Unknown) {
                    break;
                }
            }
        }

        std.Thread.sleep(10 * std.time.ns_per_ms);
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
        stdout_data.items,
        stderr_data.items,
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
        .description = "Execute a bash command and return stdout, stderr, exit_code, truncated flag, and timeout flag. Use this to run shell commands, scripts, or interact with the file system. If the command requires stdin input, provide it via stdin_data. If not provided, stdin is closed (useful for interactive programs that would otherwise hang).",
        .parameters = .{
            .type = "object",
            .properties = &.{
                .{
                    .name = "command",
                    .type = "string",
                    .description = "The bash command to execute (required)",
                },
                .{
                    .name = "timeout",
                    .type = "number",
                    .description = "Timeout in seconds (default 30). If the command exceeds this time, it will be terminated and timeout=true returned",
                },
                .{
                    .name = "cwd",
                    .type = "string",
                    .description = "Working directory to run the command in (optional, defaults to current directory)",
                },
                .{
                    .name = "max_output",
                    .type = "number",
                    .description = "Max output size in bytes (default 1048576 = 1MB). If exceeded, truncated=true and output is cut",
                },
                .{
                    .name = "stdin_data",
                    .type = "string",
                    .description = "Data to send to stdin (optional). If not provided, stdin is closed immediately - useful for commands that would otherwise hang waiting for input",
                },
            },
            .required = &.{ "command", "cwd" , "timeout" },
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
