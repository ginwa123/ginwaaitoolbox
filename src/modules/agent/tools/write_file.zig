const std = @import("std");
const schemas = @import("schemas.zig");
const ToolProperty = schemas.ToolProperty;
const ToolParameters = schemas.ToolParameters;
const AgentToolFunction = schemas.AgentToolFunction;
const AgentTool = schemas.AgentTool;

pub const WriteFileInput = struct {
    path: []const u8,
    content: []const u8,
    create_with_dir: bool = false,
};

pub const WriteFileResult = struct {
    path: []const u8,

    pub fn deinit(self: WriteFileResult, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
    }
};

pub const WriteFileOptions = struct {
    content: []const u8,
    create_with_dir: bool = false,
};

pub fn write_file(
    allocator: std.mem.Allocator,
    path: []const u8,
    opts: WriteFileOptions,
) !WriteFileResult {
    // If create_with_dir is true, proactively create parent directories with makePath
    if (opts.create_with_dir) {
        if (std.mem.lastIndexOf(u8, path, "/")) |idx| {
            const dir_path = path[0..idx];
            try std.fs.cwd().makePath(dir_path);
        }
    }

    const file = std.fs.cwd().createFile(path, .{}) catch |err| {
        if (err == error.FileNotFound) {
            var path_copy = try allocator.dupe(u8, path);
            defer allocator.free(path_copy);

            const last_slash = std.mem.lastIndexOf(u8, path_copy, "/");
            if (last_slash) |idx| {
                const dir_path = path_copy[0..idx];
                try std.fs.cwd().makeDir(dir_path);
                const file = try std.fs.cwd().createFile(path, .{});
                defer file.close();

                try file.writeAll(opts.content);
                return WriteFileResult{
                    .path = try allocator.dupe(u8, path),
                };
            }
        }
        return err;
    };
    defer file.close();

    try file.writeAll(opts.content);
    return WriteFileResult{
        .path = try allocator.dupe(u8, path),
    };
}

pub fn writeFileToString(allocator: std.mem.Allocator, result: WriteFileResult) ![]const u8 {
    return std.fmt.allocPrint(allocator, "<file_write>{s}</file_write>", .{result.path});
}

pub const write_file_tool = AgentTool{
    .type = "function",
    .function = .{
        .name = "write_file",
        .description =
        \\Write content to a new file. Creates file if it doesn't exist, overwrites if it does.
        \\For partial file updates, use text_replace tool instead.
        \\Set create_with_dir to true to automatically create parent directories.
        ,
        .parameters = .{
            .type = "object",
            .properties = &.{
                .{
                    .name = "path",
                    .type = "string",
                    .description = "Absolute path to the file.",
                },
                .{
                    .name = "content",
                    .type = "string",
                    .description = "Content to write.",
                },
                .{
                    .name = "create_with_dir",
                    .type = "boolean",
                    .description = "If true, automatically create parent directories if they don't exist. Default: false.",
                },
            },
            .required = &.{ "path", "content" },
        },
    },
};

