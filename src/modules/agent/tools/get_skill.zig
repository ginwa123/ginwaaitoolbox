const std = @import("std");
const schemas = @import("schemas.zig");
const ToolProperty = schemas.ToolProperty;
const ToolParameters = schemas.ToolParameters;
const AgentToolFunction = schemas.AgentToolFunction;
const AgentTool = schemas.AgentTool;
const skills = @import("skills.zig");

/// Input structure for get_skill tool
pub const GetSkillInput = struct {
    skill_name: ?[]const u8 = null,
    path: ?[]const u8 = null,
};

/// Result structure for get_skill tool
pub const GetSkillResult = struct {
    skill_name: []const u8,
    content: []const u8,
    loaded: bool,
    path: ?[]const u8 = null,
    err_msg: ?[]const u8 = null,
    available_skills: ?[]const []const u8 = null,
};

/// Tool definition for get_skill
pub const get_skill_tool = AgentTool{
    .type = "function",
    .function = .{
        .name = "get_skill",
        .description = "Load a skill's full content on-demand. Use this when you need detailed guidance for a specific capability",
        .parameters = .{
            .type = "object",
            .properties = &.{
                .{
                    .name = "skill_name",
                    .type = "string",
                    .description = "The exact name of the skill to load",
                },
                .{
                    .name = "path",
                    .type = "string",
                    .description = "Load skill from absolute file path",
                },
            },
            .required = &.{},
        },
    },
};

/// Execute the get_skill tool
/// Returns an XML string with the skill content or error message
/// Caller owns the returned memory and must free it with allocator.free()
pub fn execute_get_skill_to_string(allocator: std.mem.Allocator, input: GetSkillInput) ![]const u8 {
    // Check if path is provided - load from file
    if (input.path) |path| {
        return loadSkillFromPath(allocator, path);
    }

    // Otherwise try to parse by skill name
    if (input.skill_name) |skill_name| {
        return loadSkillByName(allocator, skill_name);
    }

    // No skill_name or path provided
    return error.InvalidInput;
}

/// Load skill from absolute file path
fn loadSkillFromPath(allocator: std.mem.Allocator, io: std.Io, path: []const u8) ![]const u8 {
    const file = std.Io.Dir.openFileAbsolute(io, path, .{}) catch {
        const result = try std.fmt.allocPrint(allocator,
            \\<skill_name></skill_name>
            \\<content></content>
            \\<loaded>false</loaded>
            \\<error>Failed to open file</error>
        , .{});
        return result;
    };
    defer std.Io.File.close(file, io);

    const content = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, std.Io.Limit.limited(std.math.maxInt(usize))) catch {
        const result = try std.fmt.allocPrint(allocator,
            \\<skill_name></skill_name>
            \\<content></content>
            \\<loaded>false</loaded>
            \\<error>Failed to read file</error>
        , .{});
        return result;
    };
    defer allocator.free(content);

    // Extract filename without extension for skill_name
    const filename = std.fs.path.basename(path);
    const ext = std.fs.path.extension(filename);
    const skill_name = filename[0 .. filename.len - ext.len];

    const result = try std.fmt.allocPrint(allocator,
        \\<skill_name>{s}</skill_name>
        \\<content>{s}</content>
        \\<loaded>true</loaded>
    , .{ skill_name, content });
    return result;
}

/// Load skill by name from built-in skills
fn loadSkillByName(allocator: std.mem.Allocator, skill_name: []const u8) ![]const u8 {
    // Try to parse the skill
    if (skills.parse_skill(allocator, skill_name)) |content| {
        defer allocator.free(content);
        // Success - return the skill content
        const result = try std.fmt.allocPrint(allocator,
            \\<skill_name>{s}</skill_name>
            \\<content>{s}</content>
            \\<loaded>true</loaded>
        , .{ skill_name, content });
        return result;
    } else {
        // Skill not found - list available skills
        const skills_list = skills.list_skills(allocator);
        defer skills.free_skills_list(allocator, skills_list);

        // Build XML string for available skills
        var available_str: std.ArrayList(u8) = .empty;
        defer available_str.deinit(allocator);

        for (skills_list) |skill| {
            try available_str.appendSlice(allocator, "<skill>");
            try available_str.appendSlice(allocator, skill.name);
            try available_str.appendSlice(allocator, "</skill>");
        }

        const result = try std.fmt.allocPrint(allocator,
            \\<skill_name>{s}</skill_name>
            \\<content></content>
            \\<loaded>false</loaded>
            \\<error>Skill not found</error>
            \\<available_skills>{s}</available_skills>
        , .{ skill_name, available_str.items });

        return result;
    }
}
