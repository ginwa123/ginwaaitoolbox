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

pub fn writeFile(
    allocator: std.mem.Allocator,
    io: std.Io,
    input: WriteFileInput,
) !WriteFileResult {
    const path = input.path;

    // If create_with_dir is true, proactively create parent directories with makePath
    if (input.create_with_dir) {
        // Look for the LAST path separator to find the parent directory.
        // On POSIX the separator is `/`; on Windows both `/` and `\` are
        // accepted by the kernel (forward slashes get translated to
        // backslashes inside the runtime), so we check for either to
        // keep the test paths portable across `std.fs.path.join` output
        // (which uses `\` on Windows hosts).
        const last_sep_pos = blk: {
            const last_fwd = std.mem.lastIndexOf(u8, path, "/");
            const last_back = std.mem.lastIndexOf(u8, path, "\\");
            break :blk @max(last_fwd orelse 0, last_back orelse 0);
        };
        if (last_sep_pos > 0) {
            const dir_path = path[0..last_sep_pos];
            try std.Io.Dir.cwd().createDirPath(io, dir_path);
        }
    }

    const file = std.Io.Dir.cwd().createFile(io, path, .{}) catch |err| {
        if (err == error.FileNotFound) {
            var path_copy = try allocator.dupe(u8, path);
            defer allocator.free(path_copy);

            // Windows path: std.fs.path.join produces `\`-separated
            // paths, so accept either separator when locating the
            // parent directory.
            const last_sep_pos = blk: {
                const last_fwd = std.mem.lastIndexOf(u8, path_copy, "/");
                const last_back = std.mem.lastIndexOf(u8, path_copy, "\\");
                break :blk @max(last_fwd orelse 0, last_back orelse 0);
            };
            if (last_sep_pos > 0) {
                const dir_path = path_copy[0..last_sep_pos];
                try std.Io.Dir.cwd().createDirPath(io, dir_path);
                const file = try std.Io.Dir.cwd().createFile(io, path, .{});
                defer std.Io.File.close(file, io);

                try std.Io.File.writeStreamingAll(file, io, input.content);
                return WriteFileResult{
                    .path = try allocator.dupe(u8, path),
                };
            }
        }
        return err;
    };
    defer std.Io.File.close(file, io);

    try std.Io.File.writeStreamingAll(file, io, input.content);
    return WriteFileResult{
        .path = try allocator.dupe(u8, path),
    };
}

/// Serialize result to XML string
pub fn toXmlSuccess(allocator: std.mem.Allocator, result: WriteFileResult) []const u8 {
    return std.fmt.allocPrint(allocator, "<success>true</success><file_write>{s}</file_write>", .{result.path}) catch "<success>false</success>";
}

pub fn toXmlError(allocator: std.mem.Allocator, err: anyerror, path: []const u8) []const u8 {
    const message: []const u8 = switch (err) {
        error.PathNotFound => std.fmt.allocPrint(allocator, "Directory for path '{s}' not found. Check if the parent directory exists.", .{path}) catch return "<success>false</success><file_write>{s}</file_write><error>UnknownError</error>",
        error.InputOutput => std.fmt.allocPrint(allocator, "Failed to write file '{s}'. Check write permissions.", .{path}) catch return "<success>false</success><file_write>{s}</file_write><error>UnknownError</error>",
        else => std.fmt.allocPrint(allocator, "Unexpected error: {s}", .{@errorName(err)}) catch return "<success>false</success><file_write>{s}</file_write><error>UnknownError</error>",
    };
    // From here on, `message` is always a heap allocation (the catch
    // branches above `return` early when allocPrint fails). Release it
    // on every return path — both success (the wrapped XML embeds
    // `message` by value) and the outer-catch fallback.
    defer allocator.free(message);
    return std.fmt.allocPrint(allocator, "<success>false</success><file_write>{s}</file_write><error>{s}</error>", .{ path, message }) catch "<success>false</success><file_write>{s}</file_write><error>UnknownError</error>";
}

pub const write_file_tool = AgentTool{
    .type = "function",
    .function = .{
        .name = "write_file",
        .description =
        \\Write content to a new file. Creates file if it doesn't exist, overwrites if it does.
        \\For partial file updates, use text_replace tool instead.
        \\Set create_with_dir to true to automatically create parent directories.
        \\return <file_write>{path}</file_write>
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
