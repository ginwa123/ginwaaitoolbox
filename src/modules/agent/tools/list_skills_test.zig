const std = @import("std");
const list_skills = @import("list_skills.zig");
const skills = list_skills.skills;

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