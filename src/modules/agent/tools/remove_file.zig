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
fn isDirectory(path: []const u8) bool {
    var dir = std.fs.cwd().openDir(path, .{}) catch return false;
    defer dir.close();
    return true;
}

/// Execute the remove_file tool - deletes a file or directory
/// Returns an XML string with result
pub fn executeRemoveFileToString(
    allocator: std.mem.Allocator,
    input: RemoveFileInput,
) ![]const u8 {
    if (input.path.len == 0) {
        return try std.fmt.allocPrint(allocator,
            \\<path></path>
            \\<deleted>false</deleted>
            \\<error>path cannot be empty</error>
        , .{});
    }

    const path_exists = blk: {
        std.fs.cwd().access(input.path, .{}) catch {
            break :blk false;
        };
        break :blk true;
    };

    if (!path_exists) {
        return try std.fmt.allocPrint(allocator,
            \\<path>{s}</path>
            \\<deleted>false</deleted>
            \\<error>Path not found</error>
        , .{input.path});
    }

    // Check if it's a directory by trying to open as dir
    const is_directory = isDirectory(input.path);

    if (is_directory) {
        // It's a directory
        if (!input.recursive) {
            return try std.fmt.allocPrint(allocator,
                \\<path>{s}</path>
                \\<deleted>false</deleted>
                \\<error>Path is a directory. Use recursive=true to delete directories with contents.</error>
            , .{input.path});
        }

        // Recursive delete using deleteTree
        std.fs.deleteTreeAbsolute(input.path) catch {
            return try std.fmt.allocPrint(allocator,
                \\<path>{s}</path>
                \\<deleted>false</deleted>
                \\<error>Failed to delete directory</error>
            , .{input.path});
        };

        return try std.fmt.allocPrint(allocator,
            \\<path>{s}</path>
            \\<deleted>true</deleted>
            \\<recursive>true</recursive>
        , .{input.path});
    }

    // It's a file - delete it
    std.fs.cwd().deleteFile(input.path) catch {
        return try std.fmt.allocPrint(allocator,
            \\<path>{s}</path>
            \\<deleted>false</deleted>
            \\<error>Failed to delete file</error>
        , .{input.path});
    };

    return try std.fmt.allocPrint(allocator,
        \\<path>{s}</path>
        \\<deleted>true</deleted>
    , .{input.path});
}
