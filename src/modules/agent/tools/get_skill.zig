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
/// Returns a JSON string with the skill content or error message
/// Caller owns the returned memory and must free it with allocator.free()
pub fn executeGetSkill(allocator: std.mem.Allocator, input: GetSkillInput) ![]const u8 {
    // Try to parse the skill
    if (skills.parseSkill(allocator, input.skill_name)) |content| {
        defer allocator.free(content);
        // Success - return the skill content
        const escaped = escapeJsonString(allocator, content);
        defer allocator.free(escaped);
        const result = try std.fmt.allocPrint(allocator,
            \\{{
            \\"skill_name": "{s}",
            \\"content": "{s}",
            \\"loaded": true
            \\}}
        , .{ input.skill_name, escaped });
        return result;
    } else {
        // Skill not found - list available skills
        const skills_list = skills.listSkills(allocator);
        defer skills.freeSkillsList(allocator, skills_list);

        // Build JSON array string directly from skills_list
        // We don't need a separate ArrayList - just use skill names directly
        var available_str: std.ArrayList(u8) = .empty;
        defer available_str.deinit(allocator);
        
        try available_str.append(allocator, '[');
        for (skills_list, 0..) |skill, i| {
            if (i > 0) {
                try available_str.appendSlice(allocator, ", ");
            }
            // Directly format each skill name as JSON string
            try available_str.append(allocator, '"');
            for (skill.name) |c| {
                switch (c) {
                    '"' => try available_str.appendSlice(allocator, "\\\""),
                    '\\' => try available_str.appendSlice(allocator, "\\\\"),
                    '\n' => try available_str.appendSlice(allocator, "\\n"),
                    '\r' => try available_str.appendSlice(allocator, "\\r"),
                    '\t' => try available_str.appendSlice(allocator, "\\t"),
                    else => try available_str.append(allocator, c),
                }
            }
            try available_str.append(allocator, '"');
        }
        try available_str.append(allocator, ']');

        const result = try std.fmt.allocPrint(allocator,
            \\{{
            \\"skill_name": "{s}",
            \\"content": "",
            \\"loaded": false,
            \\"error": "Skill not found",
            \\"available_skills": {s}
            \\}}
        , .{ input.skill_name, available_str.items });

        return result;
    }
}

/// Escape a string for JSON output
fn escapeJsonString(allocator: std.mem.Allocator, s: []const u8) []const u8 {
    var result: std.ArrayList(u8) = .empty;
    defer result.deinit(allocator);

    for (s) |c| {
        switch (c) {
            '"' => result.appendSlice(allocator, "\\\"") catch return "",
            '\\' => result.appendSlice(allocator, "\\\\") catch return "",
            '\n' => result.appendSlice(allocator, "\\n") catch return "",
            '\r' => result.appendSlice(allocator, "\\r") catch return "",
            '\t' => result.appendSlice(allocator, "\\t") catch return "",
            else => result.append(allocator, c) catch return "",
        }
    }

    return allocator.dupe(u8, result.items) catch "";
}
