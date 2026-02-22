const std = @import("std");
const BashInput = @import("models.zig").BashInput;
const ToolProperty = @import("models.zig").ToolProperty;
const ToolParameters = @import("models.zig").ToolParameters;
const AgentToolFunction = @import("models.zig").AgentToolFunction;
const AgentTool = @import("models.zig").AgentTool;

pub fn executeBash(allocator: std.mem.Allocator, input: BashInput) ![]const u8 {
    const max_output = input.max_output orelse 1024 * 1024;

    const result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ "bash", "-c", input.command },
        .cwd = input.cwd,
        .max_output_bytes = max_output,
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    const was_truncated = result.stdout.len >= max_output or result.stderr.len >= max_output;

    const output = try std.fmt.allocPrint(allocator,
        \\<stdout>{s}</stdout>
        \\<stderr>{s}</stderr>
        \\<exit_code>{d}</exit_code>
        \\<truncated>{}</truncated>
    , .{
        result.stdout,
        result.stderr,
        result.term.Exited,
        was_truncated,
    });

    return output;
}

pub const bashTool = AgentTool{
    .type = "function",
    .function = .{
        .name = "bash",
        .description = "Execute a bash command and return stdout and stderr output",
        .parameters = .{
            .type = "object",
            .properties = &.{
                .{
                    .name = "command",
                    .type = "string",
                    .description = "The bash command to execute",
                },
                .{
                    .name = "timeout",
                    .type = "number",
                    .description = "Timeout in seconds, default 30",
                },
                .{
                    .name = "cwd",
                    .type = "string",
                    .description = "Working directory to run the command in",
                },
                .{
                    .name = "max_output",
                    .type = "number",
                    .description = "Max output size in bytes, default 1048576 (1MB). Increase if output is truncated",
                },
            },
            .required = &.{"command"},
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
