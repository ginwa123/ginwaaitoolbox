const std = @import("std");
const schemas = @import("schemas.zig");
const ToolProperty = schemas.ToolProperty;
const ToolParameters = schemas.ToolParameters;
const AgentToolFunction = schemas.AgentToolFunction;
const AgentTool = schemas.AgentTool;
const skills = @import("skills.zig");

/// Input structure for view_skill tool
pub const ViewSkillInput = struct {
    skill_name: ?[]const u8 = null,
};

/// Result structure for view_skill tool
pub const ViewSkillResult = struct {
    skill_name: []const u8,
    description: []const u8,
    found: bool,
    err_msg: ?[]const u8 = null,
};

/// Tool definition for view_skill
pub const view_skill_tool = AgentTool{
    .type = "function",
    .function = .{
        .name = "view_skill",
        .description = "View a skill's description without loading its full content. Use this to check what a skill does before deciding to use get_skill to load it.",
        .parameters = .{
            .type = "object",
            .properties = &.{
                .{
                    .name = "skill_name",
                    .type = "string",
                    .description = "The exact name of the skill to view",
                },
            },
            .required = &.{},
        },
    },
};

/// Execute the view_skill tool
/// Returns an XML string with the skill description or error message
/// Caller owns the returned memory and must free it with allocator.free()
pub fn execute_view_skill_to_string(allocator: std.mem.Allocator, io: std.Io, input: ViewSkillInput, environment: ?*const std.process.Environ.Map) ![]const u8 {
    if (input.skill_name == null or input.skill_name.?.len == 0) {
        return error.InvalidInput;
    }

    const skill_name = input.skill_name.?;
    return viewSkillByName(allocator, io, skill_name, environment);
}

/// View skill by name - searches both local and global paths
fn viewSkillByName(allocator: std.mem.Allocator, io: std.Io, skill_name: []const u8, environment: ?*const std.process.Environ.Map) ![]const u8 {
    // Try local path first (.nalar/skills/)
    if (viewSkillFromPath(allocator, io, skill_name)) |result| {
        return toXmlSuccess(allocator, result);
    }

    // Try global path (~/.config/nalar/skills/) if environment provided
    if (environment) |env| {
        if (skills.get_global_skills_path_from_env(allocator, env)) |global_path| {
            defer allocator.free(global_path);
            if (viewSkillFromPathAt(allocator, io, skill_name, global_path)) |result| {
                return toXmlSuccess(allocator, result);
            }
        }
    }

    // Skill not found - return error with available skills
    return buildSkillNotFoundResponse(allocator, io, skill_name, environment);
}

/// View skill from a specific directory path
fn viewSkillFromPathAt(allocator: std.mem.Allocator, io: std.Io, skill_name: []const u8, dir_path: []const u8) ?ViewSkillResult {
    const files = skills.list_skill_files_in_dir(allocator, io, dir_path) orelse return null;
    defer skills.free_skill_files(allocator, files);

    for (files) |file_path| {
        const content = skills.load_skills_from_path(allocator, io, file_path);
        defer allocator.free(content);

        if (content.len == 0) continue;

        if (skills.parseYamlFrontmatter(allocator, content)) |parsed| {
            if (std.mem.eql(u8, parsed.name, skill_name)) {
                // Return success with skill name and description
                return ViewSkillResult{
                    .skill_name = parsed.name,
                    .description = parsed.description,
                    .found = true,
                };
            }
            allocator.free(parsed.name);
            allocator.free(parsed.description);
        }
    }

    return null;
}

/// View skill from the local skills directory
fn viewSkillFromPath(allocator: std.mem.Allocator, io: std.Io, skill_name: []const u8) ?ViewSkillResult {
    const files = skills.list_skill_files(allocator, io) orelse return null;
    defer skills.free_skill_files(allocator, files);

    for (files) |file_path| {
        const content = skills.load_skills_from_path(allocator, io, file_path);
        defer allocator.free(content);

        if (content.len == 0) continue;

        if (skills.parseYamlFrontmatter(allocator, content)) |parsed| {
            if (std.mem.eql(u8, parsed.name, skill_name)) {
                // Return success with skill name and description
                return ViewSkillResult{
                    .skill_name = parsed.name,
                    .description = parsed.description,
                    .found = true,
                };
            }
            allocator.free(parsed.name);
            allocator.free(parsed.description);
        }
    }

    return null;
}

/// Escape XML special characters for safe output
fn xmlEscape(allocator: std.mem.Allocator, s: []const u8) ![]u8 {
    var result = std.ArrayList(u8).empty;
    errdefer result.deinit(allocator);

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

    return try result.toOwnedSlice(allocator);
}

/// Convert ViewSkillResult to XML success string
/// Caller owns the returned memory and must free it with allocator.free()
pub fn toXmlSuccess(allocator: std.mem.Allocator, result: ViewSkillResult) ![]u8 {
    const escaped_name = try xmlEscape(allocator, result.skill_name);
    defer allocator.free(escaped_name);
    const escaped_desc = try xmlEscape(allocator, result.description);
    defer allocator.free(escaped_desc);

    return std.fmt.allocPrint(allocator,
        \\<skill_name>{s}</skill_name>
        \\<description>{s}</description>
        \\<found>true</found>
    , .{ escaped_name, escaped_desc });
}

/// Convert error to XML error string
/// Caller owns the returned memory and must free it with allocator.free()
pub fn toXmlError(allocator: std.mem.Allocator, err: anyerror, skill_name: []const u8) ![]u8 {
    const escaped_name = try xmlEscape(allocator, skill_name);
    defer allocator.free(escaped_name);
    const err_msg = @errorName(err);
    const escaped_err = try xmlEscape(allocator, err_msg);
    defer allocator.free(escaped_err);

    return std.fmt.allocPrint(allocator,
        \\<skill_name>{s}</skill_name>
        \\<description></description>
        \\<found>false</found>
        \\<error>{s}</error>
    , .{ escaped_name, escaped_err });
}

/// Build error response with available skills list
fn buildSkillNotFoundResponse(allocator: std.mem.Allocator, io: std.Io, skill_name: []const u8, environment: ?*const std.process.Environ.Map) ![]const u8 {
    var all_skills: std.ArrayList([]const u8) = .empty;
    defer all_skills.deinit(allocator);

    // List global skills
    if (environment) |env| {
        if (skills.get_global_skills_path_from_env(allocator, env)) |global_path| {
            defer allocator.free(global_path);
            const global_list = skills.list_skills_from_dir_path(allocator, io, global_path);
            defer skills.free_skills_list(allocator, global_list);
            for (global_list) |skill| {
                all_skills.append(allocator, skill.name) catch break;
            }
        }
    }

    // List local skills
    if (skills.get_local_skills_path_from_io(allocator, io)) |local_path| {
        defer allocator.free(local_path);
        const local_list = skills.list_skills_from_dir_path(allocator, io, local_path);
        defer skills.free_skills_list(allocator, local_list);
        for (local_list) |skill| {
            all_skills.append(allocator, skill.name) catch break;
        }
    }

    // Build XML string for available skills
    var available_str: std.ArrayList(u8) = .empty;
    defer available_str.deinit(allocator);

    for (all_skills.items) |name| {
        try available_str.appendSlice(allocator, "<skill>");
        try available_str.appendSlice(allocator, name);
        try available_str.appendSlice(allocator, "</skill>");
    }

    const result = try std.fmt.allocPrint(allocator,
        \\<skill_name>{s}</skill_name>
        \\<description></description>
        \\<found>false</found>
        \\<error>Skill not found</error>
        \\<available_skills>{s}</available_skills>
    , .{ skill_name, available_str.items });

    return result;
}
