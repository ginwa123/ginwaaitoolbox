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

/// JSON payloads for remove_agent results.
pub const RemoveAgentSuccessJSON = struct {
    name: []const u8,
    removed: bool,
    path: []const u8,
};

pub const RemoveAgentErrorJSON = struct {
    name: []const u8,
    @"error": []const u8,
};

/// Execute the remove_agent tool - deletes agent directory from .nalar/agents/
/// Returns an owned JSON string with the result
/// Caller owns the returned memory and must free it with allocator.free()
///
/// `io: std.Io` is required for the cross-platform recursive-delete
/// (`std.Io.Dir.cwd().deleteTree`). `std.fs.deleteTreeAbsolute` was
/// removed in Zig 0.16 and on Windows there is no portable libc
/// equivalent — the Io runtime + `Io.Dir.cwd().deleteTree` is the
/// only cross-platform option.
pub fn execute_remove_agent_to_json(
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
        return try jsonError(allocator, input.name, "Failed to get current working directory");
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
        return try jsonError(allocator, input.name, "Agent directory not found in .nalar/agents/");
    }

    // Delete the agent directory recursively. `std.fs.deleteTreeAbsolute`
    // was removed in Zig 0.16 — use the cross-platform
    // `std.Io.Dir.cwd().deleteTree` (POSIX: recursive unlink + rmdir;
    // Windows: Win32 DeleteFileW/RemoveDirectoryW per design_io.zig).
    std.Io.Dir.cwd().deleteTree(io, agent_dir_path) catch {
        return try jsonError(allocator, input.name, "Failed to delete agent directory");
    };

    // Return success
    const clean_name = try helpers.sanitize_control_chars(allocator, input.name);
    defer allocator.free(clean_name);
    const clean_path = try helpers.sanitize_control_chars(allocator, agent_dir_path);
    defer allocator.free(clean_path);
    return try std.json.Stringify.valueAlloc(allocator, RemoveAgentSuccessJSON{
        .name = clean_name,
        .removed = true,
        .path = clean_path,
    }, .{});
}

/// Generate error JSON response (owned; caller frees)
pub fn jsonError(allocator: std.mem.Allocator, name: []const u8, error_msg: []const u8) ![]const u8 {
    const clean_name = try helpers.sanitize_control_chars(allocator, name);
    defer allocator.free(clean_name);
    const clean_err = try helpers.sanitize_control_chars(allocator, error_msg);
    defer allocator.free(clean_err);
    return try std.json.Stringify.valueAlloc(allocator, RemoveAgentErrorJSON{
        .name = clean_name,
        .@"error" = clean_err,
    }, .{});
}

/// Generate error JSON response for parse failures (no name available; owned)
pub fn jsonErrorEmpty(allocator: std.mem.Allocator, error_msg: []const u8) ![]const u8 {
    return try jsonError(allocator, "", error_msg);
}

test "remove_agent jsonError emits JSON error shape" {
    const allocator = std.testing.allocator;
    const out = try jsonError(allocator, "my-agent", "Agent directory not found in .nalar/agents/");
    defer allocator.free(out);
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, out, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;
    try std.testing.expectEqualStrings("my-agent", obj.get("name").?.string);
    try std.testing.expectEqualStrings("Agent directory not found in .nalar/agents/", obj.get("error").?.string);
}

test "remove_agent jsonErrorEmpty emits empty name with error" {
    const allocator = std.testing.allocator;
    const out = try jsonErrorEmpty(allocator, "boom");
    defer allocator.free(out);
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, out, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;
    try std.testing.expectEqualStrings("", obj.get("name").?.string);
    try std.testing.expectEqualStrings("boom", obj.get("error").?.string);
}

test "remove_agent missing directory returns JSON error" {
    const allocator = std.testing.allocator;
    const out = try execute_remove_agent_to_json(allocator, std.testing.io, .{
        .name = "definitely-not-a-real-agent-xyz",
        .session_id = "s",
    });
    defer allocator.free(out);
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, out, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;
    try std.testing.expectEqualStrings("definitely-not-a-real-agent-xyz", obj.get("name").?.string);
    try std.testing.expect(obj.get("error").? == .string);
}
