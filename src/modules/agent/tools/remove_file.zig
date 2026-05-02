const std = @import("std");
const schemas = @import("schemas.zig");
const ToolProperty = schemas.ToolProperty;
const ToolParameters = schemas.ToolParameters;
const AgentToolFunction = schemas.AgentToolFunction;
const AgentTool = schemas.AgentTool;

/// Input structure for remove_file tool
pub const RemoveFileInput = struct {
    /// Absolute path to the file or directory to delete
    path: []const u8,
    /// If true, recursively delete directory and all contents inside
    recursive: bool = false,
};

/// Tool definition for remove_file
pub const remove_file_tool = AgentTool{
    .type = "function",
    .function = .{
        .name = "remove_file",
        .description = "Delete a file or directory from the filesystem. Use recursive=true to delete folders with all contents inside. Warning: This cannot be undone!",
        .parameters = .{
            .type = "object",
            .properties = &.{
                .{
                    .name = "path",
                    .type = "string",
                    .description = "Absolute path to the file or directory to delete.",
                },
                .{
                    .name = "recursive",
                    .type = "boolean",
                    .description = "If true, recursively delete directory and all contents inside. Default: false.",
                },
            },
            .required = &.{ "path" },
        },
    },
};

/// Check if path is a directory
fn isDirectory(io : std.Io, path: []const u8) bool {
    _ = std.Io.Dir.cwd().openDir(io, path, .{}) catch return false;
    return true;
}

/// Execute the remove_file tool - deletes a file or directory
/// Returns an XML string with result
pub fn executeRemoveFileToString(
    allocator: std.mem.Allocator,
    io: std.Io,
    input: RemoveFileInput,
) ![]const u8 {
    if (input.path.len == 0) {
        return xmlError(allocator, "", "path cannot be empty");
    }

    const path_exists = blk: {
        std.Io.Dir.cwd().access(io, input.path, .{}) catch {
            break :blk false;
        };
        break :blk true;
    };

    if (!path_exists) {
        return xmlError(allocator, input.path, "Path not found");
    }

    // Check if it's a directory by trying to open as dir
    const is_directory = isDirectory(input.path);

    if (is_directory) {
        // It's a directory
        if (!input.recursive) {
            return xmlError(allocator, input.path, "Path is a directory. Use recursive=true to delete directories with contents.");
        }

        // Recursive delete using deleteTree
        std.Io.Dir.cwd().deleteTree(io, input.path) catch {
            return xmlError(allocator, input.path, "Failed to delete directory");
        };

        return try std.fmt.allocPrint(allocator,
            \\<path>{s}</path>
            \\<deleted>true</deleted>
            \\<recursive>true</recursive>
        , .{input.path});
    }

    // It's a file - delete it
    std.Io.Dir.cwd().deleteFile(io, input.path) catch {
        return xmlError(allocator, input.path, "Failed to delete file");
    };

    return try std.fmt.allocPrint(allocator,
        \\<path>{s}</path>
        \\<deleted>true</deleted>
    , .{input.path});
}

/// Generate error XML response
pub fn xmlError(allocator: std.mem.Allocator, path: []const u8, error_msg: []const u8) []const u8 {
    return std.fmt.allocPrint(allocator,
        \\<path>{s}</path>
        \\<deleted>false</deleted>
        \\<error>{s}</error>
    , .{ path, error_msg }) catch "<path></path><deleted>false</deleted><error>UnknownError</error>";
}

/// Generate error XML response for parse failures (no path available)
pub fn xmlErrorEmpty(allocator: std.mem.Allocator, error_msg: []const u8) []const u8 {
    return std.fmt.allocPrint(allocator,
        \\<path></path>
        \\<deleted>false</deleted>
        \\<error>{s}</error>
    , .{error_msg}) catch "<path></path><deleted>false</deleted><error>UnknownError</error>";
}
