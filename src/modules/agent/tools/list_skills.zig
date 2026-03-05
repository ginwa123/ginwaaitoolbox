const std = @import("std");
const ToolProperty = @import("models.zig").ToolProperty;
const ToolParameters = @import("models.zig").ToolParameters;
const AgentToolFunction = @import("models.zig").AgentToolFunction;
const AgentTool = @import("models.zig").AgentTool;
const skills = @import("skills.zig");

/// Result structure for list_skills tool
pub const ListSkillsResult = struct {
    skills: []skills.SkillInfo,
};

/// Tool definition for list_skills
pub const listSkillsTool = AgentTool{
    .type = "function",
    .function = .{
        .name = "list_skills",
        .description = "List all available skills with brief descriptions. Use this to discover what capabilities you can load.",
        .parameters = .{
            .type = "object",
            .properties = &.{
                .{
                    .name = "cwd",
                    .type = "string",
                    .description = "Absolute working directory for the command. REQUIRED — always set explicitly. " ++
                        "Never assume the current directory. All relative paths in the command resolve from here.",
                },
            },
            .required = &.{},
        },
    },
};

/// Execute the list_skills tool
/// Returns a JSON string with the list of available skills
/// Caller owns the returned memory and must free it with allocator.free()
pub fn executeListSkills(allocator: std.mem.Allocator) ![]const u8 {
    const skills_list = skills.listSkills(allocator);
    defer skills.freeSkillsList(allocator, skills_list);

    // Build JSON array
    var result: std.ArrayList(u8) = .empty;
    defer result.deinit(allocator);

    try result.appendSlice(allocator, "{\"skills\":[");

    for (skills_list, 0..) |skill, i| {
        if (i > 0) {
            try result.appendSlice(allocator, ", ");
        }
        const escaped_name = escapeJsonString(allocator, skill.name);
        defer allocator.free(escaped_name);
        const escaped_desc = escapeJsonString(allocator, skill.description);
        defer allocator.free(escaped_desc);
        const entry = try std.fmt.allocPrint(allocator,
            \\{{"name":"{s}","description":"{s}"}}
        , .{ escaped_name, escaped_desc });
        defer allocator.free(entry);
        try result.appendSlice(allocator, entry);
    }

    try result.appendSlice(allocator, "]}");

    return allocator.dupe(u8, result.items) catch "";
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
