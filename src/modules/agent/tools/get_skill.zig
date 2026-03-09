const std = @import("std");
const ToolProperty = @import("models.zig").ToolProperty;
const ToolParameters = @import("models.zig").ToolParameters;
const AgentToolFunction = @import("models.zig").AgentToolFunction;
const AgentTool = @import("models.zig").AgentTool;
const skills = @import("skills.zig");

/// Input structure for get_skill tool
pub const GetSkillInput = struct {
    skill_name: []const u8,
};

/// Result structure for get_skill tool
pub const GetSkillResult = struct {
    skill_name: []const u8,
    content: []const u8,
    loaded: bool,
    err_msg: ?[]const u8 = null,
    available_skills: ?[]const []const u8 = null,
};

/// Tool definition for get_skill
pub const getSkillTool = AgentTool{
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
                    .description = "The exact name of the skill to load ",
                },
            },
            .required = &.{"skill_name"},
        },
    },
};

/// Execute the get_skill tool
/// Returns an XML string with the skill content or error message
/// Caller owns the returned memory and must free it with allocator.free()
pub fn executeGetSkillToString(allocator: std.mem.Allocator, input: GetSkillInput) ![]const u8 {
    // Try to parse the skill
    if (skills.parseSkill(allocator, input.skill_name)) |content| {
        defer allocator.free(content);
        // Success - return the skill content
        const result = try std.fmt.allocPrint(allocator,
            \\<skill_name>{s}</skill_name>
            \\<content>{s}</content>
            \\<loaded>true</loaded>
        , .{ input.skill_name, content });
        return result;
    } else {
        // Skill not found - list available skills
        const skills_list = skills.listSkills(allocator);
        defer skills.freeSkillsList(allocator, skills_list);

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
        , .{ input.skill_name, available_str.items });

        return result;
    }
}
