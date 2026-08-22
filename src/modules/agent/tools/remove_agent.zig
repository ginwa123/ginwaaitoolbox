const std = @import("std");
const schemas = @import("schemas.zig");
const nalarcore = @import("nalarcore");
const helpers = @import("helpers");
const ToolProperty = schemas.ToolProperty;
const ToolParameters = schemas.ToolParameters;
const AgentToolFunction = schemas.AgentToolFunction;
const AgentTool = schemas.AgentTool;

/// Input structure for remove_agent tool
pub const RemoveAgentInput = struct {
    /// Agent name to delete
    name: []const u8,
    /// Session ID (kept for compatibility)
    session_id: []const u8,
};

/// Tool definition for remove_agent
pub const remove_agent_tool = AgentTool{
    .type = "function",
    .function = .{
        .name = "remove_agent",
        .description = "Remove and delete an agent from .nalar/agents/. Use this to permanently remove a custom agent persona.",
        .parameters = .{
            .type = "object",
            .properties = &.{
                .{
                    .name = "name",
                    .type = "string",
                    .description = "The exact name of the agent to delete from .nalar/agents/",
                },
                .{
                    .name = "session_id",
                    .type = "string",
                    .description = "The session ID (unused, kept for compatibility)",
                },
            },
            .required = &.{ "name", "session_id" },
        },
    },
};

/// Execute the remove_agent tool - deletes agent directory from .nalar/agents/
/// Returns an XML string with result
/// Caller owns the returned memory and must free it with allocator.free()
///
/// `io: std.Io` is required for the cross-platform recursive-delete
/// (`std.Io.Dir.cwd().deleteTree`). `std.fs.deleteTreeAbsolute` was
/// removed in Zig 0.16 and on Windows there is no portable libc
/// equivalent — the Io runtime + `Io.Dir.cwd().deleteTree` is the
/// only cross-platform option.
pub fn execute_remove_agent_to_string(
    allocator: std.mem.Allocator,
    io: std.Io,
    input: RemoveAgentInput,
) ![]const u8 {
    // Validate input
    if (input.name.len == 0) {
        return error.InvalidInput;
    }

    // Get current working directory
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    // `std.posix.getcwd` was removed in Zig 0.16. Use the cross-platform
    // `helpers.getcwd` wrapper (libc-backed; works on Linux/macOS/Windows
    // without an `io: std.Io` runtime).
    const cwd = helpers.getcwd(&cwd_buf) orelse {
        return errorToXml(allocator, input.name, "Failed to get current working directory");
    };

    // Build path to agent directory: .nalar/agents/<name>/
    // Duplicate name to ensure no aliasing with path.join's internal buffer allocation
    const name_copy = try allocator.dupe(u8, input.name);
    defer allocator.free(name_copy);

    const agent_dir_path = try std.fs.path.join(allocator, &[_][]const u8{ cwd, ".nalar", "agents", name_copy });
    defer allocator.free(agent_dir_path);

    // Check if the agent directory exists. Uses the cross-platform
    // `helpers.fileExists` (libc access()) since Zig 0.16 removed
    // `std.fs.cwd().access`.
    const dir_exists = helpers.fileExists(agent_dir_path);

    if (!dir_exists) {
        // Agent directory doesn't exist
        return errorToXml(allocator, input.name, "Agent directory not found in .nalar/agents/");
    }

    // Delete the agent directory recursively. `std.fs.deleteTreeAbsolute`
    // was removed in Zig 0.16 — use the cross-platform
    // `std.Io.Dir.cwd().deleteTree` (POSIX: recursive unlink + rmdir;
    // Windows: Win32 DeleteFileW/RemoveDirectoryW per design_io.zig).
    std.Io.Dir.cwd().deleteTree(io, agent_dir_path) catch {
        return errorToXml(allocator, input.name, "Failed to delete agent directory");
    };

    // Return success
    var result = std.ArrayList(u8).empty;
    errdefer result.deinit(allocator);

    try result.appendSlice(allocator, "<name>");
    try appendXmlContent(allocator, &result, input.name);
    try result.appendSlice(allocator, "</name>\n<removed>true</removed>\n<path>");
    try appendXmlContent(allocator, &result, agent_dir_path);
    try result.appendSlice(allocator, "</path>");

    return try result.toOwnedSlice(allocator);
}

/// Generate error XML response
pub fn xmlError(allocator: std.mem.Allocator, name: []const u8, error_msg: []const u8) []const u8 {
    var result = std.ArrayList(u8).empty;
    errdefer result.deinit(allocator);

    result.appendSlice(allocator, "<name>") catch return "";
    appendXmlContent(allocator, &result, name) catch return "";
    result.appendSlice(allocator, "</name>\n<removed>false</removed>\n<error>") catch return "";
    appendXmlContent(allocator, &result, error_msg) catch return "";
    result.appendSlice(allocator, "</error>") catch return "";

    return result.toOwnedSlice(allocator) catch "";
}

/// Generate error XML response for parse failures (no name available)
pub fn xmlErrorEmpty(allocator: std.mem.Allocator, error_msg: []const u8) []const u8 {
    var result = std.ArrayList(u8).empty;
    errdefer result.deinit(allocator);

    result.appendSlice(allocator, "<name></name>\n<removed>false</removed>\n<error>") catch return "";
    appendXmlContent(allocator, &result, error_msg) catch return "";
    result.appendSlice(allocator, "</error>") catch return "";

    return result.toOwnedSlice(allocator) catch "";
}

/// Append XML-safe content to an ArrayList
fn appendXmlContent(allocator: std.mem.Allocator, result: *std.ArrayList(u8), s: []const u8) !void {
    for (s) |c| {
        switch (c) {
            '<' => try result.appendSlice(allocator, "&lt;"),
            '>' => try result.appendSlice(allocator, "&gt;"),
            '&' => try result.appendSlice(allocator, "&amp;"),
            '"' => try result.appendSlice(allocator, "&quot;"),
            '\'' => try result.appendSlice(allocator, "&apos;"),
            else => try result.append(allocator, c),
        }
    }
}

/// Internal error-to-XML helper (doesn't return error)
fn errorToXml(allocator: std.mem.Allocator, name: []const u8, error_msg: []const u8) []const u8 {
    return xmlError(allocator, name, error_msg);
}
