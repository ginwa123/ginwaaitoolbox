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
};

/// Result structure for remove_skill tool
pub const RemoveSkillResult = struct {
    skill_name: []const u8,
    removed: bool,
    err_msg: ?[]const u8 = null,
};

/// Create XML error output for remove_skill
pub fn xmlError(allocator: std.mem.Allocator, skill_name: []const u8, err_msg: []const u8) []const u8 {
    return std.fmt.allocPrint(allocator,
        \\<skill_name>{s}</skill_name>
        \\<removed>false</removed>
        \\<error>{s}</error>
    , .{ skill_name, err_msg }) catch "<skill_name></skill_name><removed>false</removed><error>UnknownError</error>";
}

/// Create XML error output for remove_skill when skill_name is empty/missing
pub fn xmlErrorEmpty(allocator: std.mem.Allocator, err_msg: []const u8) []const u8 {
    return std.fmt.allocPrint(allocator,
        \\<skill_name></skill_name>
        \\<removed>false</removed>
        \\<error>{s}</error>
    , .{err_msg}) catch "<skill_name></skill_name><removed>false</removed><error>UnknownError</error>";
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
            },
            .required = &.{ "skill_name", "session_id" },
        },
    },
};

/// Execute the remove_skill tool - removes from session AND deletes file
/// Returns an XML string with result
/// Caller owns the returned memory and must free it with allocator.free()
pub fn execute_remove_skill_to_string(
    allocator: std.mem.Allocator,
    io: std.Io,
    cwd: []const u8,
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

    // Use cwd from context (already absolute path from session)
    // Build path to skill directory: .nalar/skills/<skill_name>/
    const skill_dir_path = try std.fs.path.join(allocator, &[_][]const u8{ cwd, ".nalar", "skills", input.skill_name });
    defer allocator.free(skill_dir_path);

    // Check if the skill directory exists
    const dir_exists = blk: {
        std.Io.Dir.cwd().access(io, skill_dir_path, .{}) catch {
            break :blk false;
        };
        break :blk true;
    };

    if (!dir_exists) {
        // Skill directory doesn't exist - might be a built-in skill or already removed
        const result = try std.fmt.allocPrint(allocator,
            \\<skill_name>{s}</skill_name>
            \\<removed>false</removed>
            \\<error>Skill directory not found in .nalar/skills/</error>
        , .{input.skill_name});
        return result;
    }

    // Delete the skill directory recursively
    std.Io.Dir.cwd().deleteTree(io, skill_dir_path) catch {
        const result = try std.fmt.allocPrint(allocator,
            \\<skill_name>{s}</skill_name>
            \\<removed>false</removed>
            \\<error>Failed to delete skill directory</error>
        , .{input.skill_name});
        return result;
    };

    // Return success
    const result = try std.fmt.allocPrint(allocator,
        \\<skill_name>{s}</skill_name>
        \\<removed>true</removed>
        \\<path>{s}</path>
    , .{ input.skill_name, skill_dir_path });

    return result;
}
