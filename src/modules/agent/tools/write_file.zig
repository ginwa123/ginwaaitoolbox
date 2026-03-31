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
    sha256: []u8,

    pub fn deinit(self: WriteFileResult, allocator: std.mem.Allocator) void {
        allocator.free(self.sha256);
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
                var hash: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
                std.crypto.hash.sha2.Sha256.hash(opts.content, &hash, .{});
                return WriteFileResult{
                    .sha256 = std.fmt.allocPrint(allocator, "{s}", .{std.fmt.bytesToHex(hash, .lower)}) catch unreachable,
                };
            }
        }
        return err;
    };
    defer file.close();

    try file.writeAll(opts.content);
    var hash: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(opts.content, &hash, .{});
    return WriteFileResult{
        .sha256 = std.fmt.allocPrint(allocator, "{s}", .{std.fmt.bytesToHex(hash, .lower)}) catch unreachable,
    };
}

pub fn writeFileToString(allocator: std.mem.Allocator, result: WriteFileResult) ![]const u8 {
    return std.fmt.allocPrint(allocator, "<sha256>{s}</sha256>", .{result.sha256});
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

