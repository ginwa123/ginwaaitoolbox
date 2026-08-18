const std = @import("std");
const schemas = @import("schemas.zig");
const ToolProperty = schemas.ToolProperty;
const ToolParameters = schemas.ToolParameters;
const AgentToolFunction = schemas.AgentToolFunction;
const AgentTool = schemas.AgentTool;
pub const skills = @import("skills.zig");

/// Shared data structure for skills list - used by both HTTP handler and AI agent tool
pub const SkillsListData = struct {
    global_skills: []const skills.SkillInfo,
    local_skills: []const skills.SkillInfo,
    cwd: ?[]const u8,
};

/// Tool definition for list_skills
pub const list_skills_tool = AgentTool{
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

/// List all skills (global + local) and return the data structure
/// Caller owns the returned memory and must free it with freeSkillsListData()
pub fn listAllSkills(
    allocator: std.mem.Allocator,
    io: std.Io,
    cwd_param: ?[]const u8,
    environment: ?*const std.process.Environ.Map,
) !SkillsListData {
    // Get global skills path (from environment map - REQUIRED)
    if (environment == null) {
        return error.MissingEnvironment;
    }
    const global_path = skills.get_global_skills_path_from_env(allocator, environment.?);
    defer if (global_path) |p| allocator.free(p);

    // Get local skills path (from cwd or current directory)
    const local_path: ?[]const u8 = if (cwd_param) |cwd|
        skills.get_local_skills_path_for_dir(allocator, cwd)
    else
        skills.get_local_skills_path_from_io(allocator, io);
    defer if (local_path) |p| allocator.free(p);

    // List global skills
    var global_skills: []skills.SkillInfo = &[_]skills.SkillInfo{};
    if (global_path) |path| {
        global_skills = skills.list_skills_from_dir_path(allocator, io, path);
    }

    // List local skills
    var local_skills: []skills.SkillInfo = &[_]skills.SkillInfo{};
    if (local_path) |path| {
        local_skills = skills.list_skills_from_dir_path(allocator, io, path);
    }

    return SkillsListData{
        .global_skills = global_skills,
        .local_skills = local_skills,
        .cwd = cwd_param,
    };
}

/// Free memory allocated by listAllSkills()
pub fn freeSkillsListData(allocator: std.mem.Allocator, data: SkillsListData) void {
    skills.free_skills_list(allocator, data.global_skills);
    skills.free_skills_list(allocator, data.local_skills);
}

/// Serialize SkillsListData to JSON string
/// Caller owns the returned memory and must free it with allocator.free()
pub fn toJson(allocator: std.mem.Allocator, data: SkillsListData) ![]const u8 {
    return std.json.Stringify.valueAlloc(allocator, data, .{});
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

/// Serialize SkillsListData to XML string for AI agent tool output
/// Caller owns the returned memory and must free it with allocator.free()
pub fn toXml(allocator: std.mem.Allocator, data: SkillsListData) ![]u8 {
    var xml = std.ArrayList(u8).empty;
    errdefer xml.deinit(allocator);

    try xml.appendSlice(allocator, "<skills>");

    // Global skills section
    try xml.appendSlice(allocator, "<global_skills>");
    for (data.global_skills) |skill| {
        try xml.appendSlice(allocator, "<skill>");
        const escaped_name = try xmlEscape(allocator, skill.name);
        defer allocator.free(escaped_name);
        try xml.appendSlice(allocator, "<name>");
        try xml.appendSlice(allocator, escaped_name);
        try xml.appendSlice(allocator, "</name>");
        const escaped_desc = try xmlEscape(allocator, skill.description);
        defer allocator.free(escaped_desc);
        try xml.appendSlice(allocator, "<description>");
        try xml.appendSlice(allocator, escaped_desc);
        try xml.appendSlice(allocator, "</description>");
        const escaped_path = try xmlEscape(allocator, skill.path);
        defer allocator.free(escaped_path);
        try xml.appendSlice(allocator, "<path>");
        try xml.appendSlice(allocator, escaped_path);
        try xml.appendSlice(allocator, "</path>");
        try xml.appendSlice(allocator, "</skill>");
    }
    try xml.appendSlice(allocator, "</global_skills>");

    // Local skills section
    try xml.appendSlice(allocator, "<local_skills>");
    for (data.local_skills) |skill| {
        try xml.appendSlice(allocator, "<skill>");
        const escaped_name = try xmlEscape(allocator, skill.name);
        defer allocator.free(escaped_name);
        try xml.appendSlice(allocator, "<name>");
        try xml.appendSlice(allocator, escaped_name);
        try xml.appendSlice(allocator, "</name>");
        const escaped_desc = try xmlEscape(allocator, skill.description);
        defer allocator.free(escaped_desc);
        try xml.appendSlice(allocator, "<description>");
        try xml.appendSlice(allocator, escaped_desc);
        try xml.appendSlice(allocator, "</description>");
        const escaped_path = try xmlEscape(allocator, skill.path);
        defer allocator.free(escaped_path);
        try xml.appendSlice(allocator, "<path>");
        try xml.appendSlice(allocator, escaped_path);
        try xml.appendSlice(allocator, "</path>");
        try xml.appendSlice(allocator, "</skill>");
    }
    try xml.appendSlice(allocator, "</local_skills>");

    // CWD if present
    if (data.cwd) |cwd| {
        const escaped_cwd = try xmlEscape(allocator, cwd);
        defer allocator.free(escaped_cwd);
        try xml.appendSlice(allocator, "<cwd>");
        try xml.appendSlice(allocator, escaped_cwd);
        try xml.appendSlice(allocator, "</cwd>");
    }

    try xml.appendSlice(allocator, "</skills>");

    return xml.toOwnedSlice(allocator);
}

/// Execute the list_skills tool - returns XML string for AI agent
/// Caller owns the returned memory and must free it with allocator.free()
pub fn execute_list_skills(
    allocator: std.mem.Allocator,
    io: std.Io,
    cwd_param: ?[]const u8,
    environment: ?*const std.process.Environ.Map,
) ![]const u8 {
    const data = try listAllSkills(allocator, io, cwd_param, environment);
    defer freeSkillsListData(allocator, data);
    return toXml(allocator, data);
}