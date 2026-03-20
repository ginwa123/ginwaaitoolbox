const std = @import("std");
const schemas = @import("schemas.zig");
const ToolProperty = schemas.ToolProperty;
const ToolParameters = schemas.ToolParameters;
const AgentToolFunction = schemas.AgentToolFunction;
const AgentTool = schemas.AgentTool;

pub const WriteFileInput = struct {
    path: []const u8,
    content: []const u8,
};

pub const WriteFileResult = struct {
    path: []u8,
    bytes_written: usize,
    lines_written: usize,

    pub fn deinit(self: WriteFileResult, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
    }
};

pub const WriteFileOptions = struct {
    content: []const u8,
};

pub fn write_file(
    allocator: std.mem.Allocator,
    path: []const u8,
    opts: WriteFileOptions,
) !WriteFileResult {
    const file = std.fs.cwd().createFile(path, .{}) catch |err| {
        if (err == error.FileNotFound) {
            // Try to create parent directories
            var path_copy = try allocator.dupe(u8, path);
            defer allocator.free(path_copy);

            // Find the directory part
            const last_slash = std.mem.lastIndexOf(u8, path_copy, "/");
            if (last_slash) |idx| {
                const dir_path = path_copy[0..idx];
                try std.fs.cwd().makeDir(dir_path);
                const file = try std.fs.cwd().createFile(path, .{});
                defer file.close();

                try file.writeAll(opts.content);

                const lines_written = countLines(opts.content);
                return WriteFileResult{
                    .path = try allocator.dupe(u8, path),
                    .bytes_written = opts.content.len,
                    .lines_written = lines_written,
                };
            }
        }
        return err;
    };
    defer file.close();

    try file.writeAll(opts.content);

    const lines_written = countLines(opts.content);

    return WriteFileResult{
        .path = try allocator.dupe(u8, path),
        .bytes_written = opts.content.len,
        .lines_written = lines_written,
    };
}

fn countLines(content: []const u8) usize {
    var count: usize = 0;
    for (content) |c| {
        if (c == '\n') count += 1;
    }
    if (content.len > 0 and content[content.len - 1] != '\n') {
        count += 1;
    }
    return count;
}

pub fn writeFileToString(allocator: std.mem.Allocator, result: WriteFileResult) ![]const u8 {
    return try std.fmt.allocPrint(allocator,
        \\<path>{s}</path>
        \\<bytes_written>{d}</bytes_written>
        \\<lines_written>{d}</lines_written>
    , .{
        result.path,
        result.bytes_written,
        result.lines_written,
    });
}

pub const writeFileTool = AgentTool{
    .type = "function",
    .function = .{
        .name = "write_file",
        .description =
        \\Write content to a new file. Creates file if it doesn't exist, overwrites if it does.
        \\For partial file updates, use text_replace tool instead.
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
            },
            .required = &.{ "path", "content" },
        },
    },
};

test {
    _ = @import("write_file_test.zig");
}
