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

const list_skills = @import("list_skills.zig");

// Helper to check if string contains substring
fn contains(haystack: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, haystack, needle) != null;
}

test "toXml generates valid XML structure" {
    const alloc = std.testing.allocator;

    const data = list_skills.SkillsListData{
        .global_skills = &[_]skills.SkillInfo{},
        .local_skills = &[_]skills.SkillInfo{},
        .cwd = null,
    };

    const xml = try list_skills.toXml(alloc, data);
    defer alloc.free(xml);

    try std.testing.expect(std.mem.startsWith(u8, xml, "<skills>"));
    try std.testing.expect(std.mem.endsWith(u8, xml, "</skills>"));
    try std.testing.expect(contains(xml, "<global_skills>"));
    try std.testing.expect(contains(xml, "<local_skills>"));
}

test "toXml escapes special characters in skill data" {
    const alloc = std.testing.allocator;

    const data = list_skills.SkillsListData{
        .global_skills = &[_]skills.SkillInfo{
            .{
                .name = "test <skill>",
                .description = "desc & more",
                .path = "/path/with \"quotes\"",
            },
        },
        .local_skills = &[_]skills.SkillInfo{},
        .cwd = null,
    };

    const xml = try list_skills.toXml(alloc, data);
    defer alloc.free(xml);

    // Should contain escaped versions
    try std.testing.expect(contains(xml, "&lt;skill&gt;"));
    try std.testing.expect(contains(xml, "&amp;"));
    try std.testing.expect(contains(xml, "&quot;"));
    // Should NOT contain unescaped < or > outside of XML tags
    // (we allow <global_skills>, <local_skills>, <skill>, etc. which are valid XML tags)
}

test "toXml includes cwd when present" {
    const alloc = std.testing.allocator;

    const data = list_skills.SkillsListData{
        .global_skills = &[_]skills.SkillInfo{},
        .local_skills = &[_]skills.SkillInfo{},
        .cwd = "/test/cwd",
    };

    const xml = try list_skills.toXml(alloc, data);
    defer alloc.free(xml);

    try std.testing.expect(contains(xml, "<cwd>"));
    try std.testing.expect(contains(xml, "/test/cwd"));
}

test "toJson generates valid JSON" {
    const alloc = std.testing.allocator;

    const data = list_skills.SkillsListData{
        .global_skills = &[_]skills.SkillInfo{},
        .local_skills = &[_]skills.SkillInfo{},
        .cwd = null,
    };

    const json = try list_skills.toJson(alloc, data);
    defer alloc.free(json);

    // Should be valid JSON structure
    try std.testing.expect(std.mem.startsWith(u8, json, "{"));
    try std.testing.expect(std.mem.endsWith(u8, json, "}"));
    try std.testing.expect(contains(json, "global_skills"));
    try std.testing.expect(contains(json, "local_skills"));
}

test "freeSkillsListData handles empty arrays" {
    const alloc = std.testing.allocator;

    const data = list_skills.SkillsListData{
        .global_skills = &[_]skills.SkillInfo{},
        .local_skills = &[_]skills.SkillInfo{},
        .cwd = null,
    };

    // Should not panic
    list_skills.freeSkillsListData(alloc, data);
}

test "execute_list_skills - finds local skill in cwd workspace" {
    // Regression test: ensure execute_list_skills correctly uses the cwd
    // parameter to find local skills. The execListSkills wiring in
    // tool_registry.zig used to pass null instead of ctx.cwd, which made
    // local skills invisible to the agent.
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    const skill_name = "test-list-local-skill";
    const tmp_path = "/tmp/nalar-list-skills-test";

    // Clean up any leftover from previous failed runs
    std.Io.Dir.cwd().deleteTree(io, tmp_path) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, tmp_path) catch {};

    // Pre-create a local skill file in the temp cwd
    const skill_dir_path = try std.fs.path.join(alloc, &[_][]const u8{ tmp_path, ".nalar", "skills", skill_name });
    defer alloc.free(skill_dir_path);
    try std.Io.Dir.cwd().createDirPath(io, skill_dir_path);

    const skill_file_path = try std.fs.path.join(alloc, &[_][]const u8{ skill_dir_path, "SKILL.MD" });
    defer alloc.free(skill_file_path);

    const skill_content =
        \\---
        \\name: test-list-local-skill
        \\description: "Test description for list regression"
        \\---
        \\
        \\# Test content
        \\
    ;
    {
        const f = try std.Io.Dir.createFileAbsolute(io, skill_file_path, .{});
        defer std.Io.File.close(f, io);
        try std.Io.File.writeStreamingAll(f, io, skill_content);
    }

    // Build a minimal environment map so listAllSkills can look up the global path.
    // Point HOME to a non-existent dir so global lookup returns no skills (clean output).
    var env = std.process.Environ.Map.init(alloc);
    defer env.deinit();
    try env.put("HOME", "/tmp/nalar-nonexistent-home-for-list-test");

    // Call execute_list_skills with the tmp_path as cwd
    const output = try list_skills.execute_list_skills(alloc, io, tmp_path, &env);
    defer alloc.free(output);

    // The local skill should appear in the local_skills block
    try std.testing.expect(contains(output, "<local_skills>"));
    try std.testing.expect(contains(output, skill_name));
    try std.testing.expect(contains(output, "Test description for list regression"));
    try std.testing.expect(contains(output, "<cwd>"));
    try std.testing.expect(contains(output, tmp_path));
}

test "execute_list_skills - does not show local skill from a different cwd" {
    // Counterpart test: when the cwd does NOT contain the skill, it should
    // not appear in local_skills. This guards against a regression where
    // the OS-level cwd (instead of the passed-in cwd) is used.
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    const skill_name = "test-list-other-cwd-skill";
    const skill_cwd = "/tmp/nalar-list-skills-other-cwd";
    const query_cwd = "/tmp/nalar-list-skills-different-cwd";

    // Clean up
    std.Io.Dir.cwd().deleteTree(io, skill_cwd) catch {};
    std.Io.Dir.cwd().deleteTree(io, query_cwd) catch {};
    defer {
        std.Io.Dir.cwd().deleteTree(io, skill_cwd) catch {};
        std.Io.Dir.cwd().deleteTree(io, query_cwd) catch {};
    }

    // Create the skill in skill_cwd
    const skill_dir_path = try std.fs.path.join(alloc, &[_][]const u8{ skill_cwd, ".nalar", "skills", skill_name });
    defer alloc.free(skill_dir_path);
    try std.Io.Dir.cwd().createDirPath(io, skill_dir_path);

    const skill_file_path = try std.fs.path.join(alloc, &[_][]const u8{ skill_dir_path, "SKILL.MD" });
    defer alloc.free(skill_file_path);

    const skill_content =
        \\---
        \\name: test-list-other-cwd-skill
        \\description: "Skill in different cwd"
        \\---
        \\
        \\# Test content
        \\
    ;
    {
        const f = try std.Io.Dir.createFileAbsolute(io, skill_file_path, .{});
        defer std.Io.File.close(f, io);
        try std.Io.File.writeStreamingAll(f, io, skill_content);
    }

    // Build a minimal environment map
    var env = std.process.Environ.Map.init(alloc);
    defer env.deinit();
    try env.put("HOME", "/tmp/nalar-nonexistent-home-for-list-test");

    // Call with a DIFFERENT cwd — the skill should not appear
    const output = try list_skills.execute_list_skills(alloc, io, query_cwd, &env);
    defer alloc.free(output);

    // The local skill should NOT appear (because it's in skill_cwd, not query_cwd)
    try std.testing.expect(!contains(output, skill_name));
}
