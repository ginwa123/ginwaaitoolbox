const std = @import("std");
const schemas = @import("schemas.zig");
const ToolProperty = schemas.ToolProperty;
const ToolParameters = schemas.ToolParameters;
const AgentToolFunction = schemas.AgentToolFunction;
const AgentTool = schemas.AgentTool;
const skills = @import("skills.zig");

/// Input structure for remove_skill tool
pub const RemoveSkillInput = struct {
    skill_name: []const u8,
    session_id: []const u8,
    /// If true, remove from global skills directory (~/.config/nalar/skills/)
    /// If false, remove from local skills directory (.nalar/skills/)
    is_global: bool = false,
};

/// Result structure for remove_skill tool
pub const RemoveSkillResult = struct {
    skill_name: []const u8,
    removed: bool,
    err_msg: ?[]const u8 = null,
};

/// Create XML error output for remove_skill
pub fn xmlError(allocator: std.mem.Allocator, skill_name: []const u8, err_msg: []const u8) []const u8 {
    var result = std.ArrayList(u8).empty;
    errdefer result.deinit(allocator);

    result.appendSlice(allocator, "<skill_name>") catch return "";
    appendXmlContent(allocator, &result, skill_name) catch return "";
    result.appendSlice(allocator, "</skill_name>\n<removed>false</removed>\n<error>") catch return "";
    appendXmlContent(allocator, &result, err_msg) catch return "";
    result.appendSlice(allocator, "</error>") catch return "";

    return result.toOwnedSlice(allocator) catch "";
}

/// Tool definition for remove_skill
pub const remove_skill_tool = AgentTool{
    .type = "function",
    .function = .{
        .name = "remove_skill",
        .description = "Remove a skill from the current session AND delete the skill file from .nalar/skills/. Use this to permanently delete a skill.",
        .parameters = .{
            .type = "object",
            .properties = &.{
                .{
                    .name = "skill_name",
                    .type = "string",
                    .description = "The exact name of the skill to remove and delete",
                },
                .{
                    .name = "session_id",
                    .type = "string",
                    .description = "The session ID (unused, kept for compatibility)",
                },
                .{
                    .name = "is_global",
                    .type = "boolean",
                    .description = "If true, remove from global skills directory (~/.config/nalar/skills/). If false, remove from local directory (.nalar/skills/). Default: false",
                },
            },
            .required = &.{ "skill_name", "session_id" },
        },
    },
};

/// Execute the remove_skill tool - removes from session AND deletes file
/// Deletes skill file at .nalar/skills/<skill_name>/ or global ~/.config/nalar/skills/<skill_name>/
/// Returns an XML string with result
/// Caller owns the returned memory and must free it with allocator.free()
pub fn execute_remove_skill_to_string(
    allocator: std.mem.Allocator,
    io: std.Io,
    cwd: []const u8,
    environment: ?*const std.process.Environ.Map,
    input: RemoveSkillInput,
) ![]const u8 {
    // Validate input
    if (input.skill_name.len == 0) {
        const result = try std.fmt.allocPrint(allocator,
            \\<skill_name></skill_name>
            \\<removed>false</removed>
            \\<error>skill_name cannot be empty</error>
        , .{});
        return result;
    }

    // Determine skills directory based on is_global flag
    const skills_dir: []const u8 = if (input.is_global)
        blk: {
            if (environment) |env| {
                const path = skills.get_global_skills_path_from_env(allocator, env) orelse {
                    const result = try std.fmt.allocPrint(allocator,
                        \\<skill_name>{s}</skill_name>
                        \\<removed>false</removed>
                        \\<error>Failed to get global skills path</error>
                    , .{input.skill_name});
                    return result;
                };
                break :blk path;
            } else {
                const result = try std.fmt.allocPrint(allocator,
                    \\<skill_name>{s}</skill_name>
                    \\<removed>false</removed>
                    \\<error>Environment not available for global skills</error>
                , .{input.skill_name});
                return result;
            }
        }
    else
        try std.fs.path.join(allocator, &[_][]const u8{ cwd, ".nalar", "skills" });

    // Build path to skill directory
    // Duplicate skill_name to ensure no aliasing with path.join's internal buffer allocation
    const skill_name_copy = try allocator.dupe(u8, input.skill_name);
    errdefer allocator.free(skill_name_copy);

    const skill_dir_path = try std.fs.path.join(allocator, &[_][]const u8{ skills_dir, skill_name_copy });
    // skill_name_copy is no longer needed after path.join copies it
    allocator.free(skill_name_copy);

    // Check if the skill directory exists
    const dir_exists = blk: {
        std.Io.Dir.cwd().access(io, skill_dir_path, .{}) catch {
            break :blk false;
        };
        break :blk true;
    };

    if (!dir_exists) {
        // Skill directory doesn't exist - might be a built-in skill or already removed
        var result = std.ArrayList(u8).empty;
        errdefer result.deinit(allocator);

        try result.appendSlice(allocator, "<skill_name>");
        try appendXmlContent(allocator, &result, input.skill_name);
        try result.appendSlice(allocator, "</skill_name>\n<removed>false</removed>\n<error>Skill directory not found</error>");

        if (input.is_global) allocator.free(skills_dir);
        allocator.free(skill_dir_path);
        return try result.toOwnedSlice(allocator);
    }

    // Delete the skill directory recursively
    std.Io.Dir.cwd().deleteTree(io, skill_dir_path) catch {
        var result = std.ArrayList(u8).empty;
        errdefer result.deinit(allocator);

        try result.appendSlice(allocator, "<skill_name>");
        try appendXmlContent(allocator, &result, input.skill_name);
        try result.appendSlice(allocator, "</skill_name>\n<removed>false</removed>\n<error>Failed to delete skill directory</error>");

        if (input.is_global) allocator.free(skills_dir);
        allocator.free(skill_dir_path);
        return try result.toOwnedSlice(allocator);
    };

    // Return success
    var result = std.ArrayList(u8).empty;
    errdefer result.deinit(allocator);

    try result.appendSlice(allocator, "<skill_name>");
    try appendXmlContent(allocator, &result, input.skill_name);
    try result.appendSlice(allocator, "</skill_name>\n<removed>true</removed>\n<path>");
    try appendXmlContent(allocator, &result, skill_dir_path);
    try result.appendSlice(allocator, "</path>");

    // Clean up allocated memory
    if (input.is_global) allocator.free(skills_dir);
    allocator.free(skill_dir_path);

    return try result.toOwnedSlice(allocator);
}

/// Generate error XML response for parse failures (no name available)
pub fn xmlErrorEmpty(allocator: std.mem.Allocator, error_msg: []const u8) []const u8 {
    var result = std.ArrayList(u8).empty;
    errdefer result.deinit(allocator);

    result.appendSlice(allocator, "<skill_name></skill_name>\n<removed>false</removed>\n<error>") catch return "";
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
