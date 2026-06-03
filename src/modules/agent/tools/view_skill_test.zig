const std = @import("std");
const view_skill = @import("view_skill.zig");

// Helper to check if string contains substring
fn contains(haystack: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, haystack, needle) != null;
}

test "view_skill_tool - has correct tool definition" {
    try std.testing.expectEqualStrings("view_skill", view_skill.view_skill_tool.function.name);
    try std.testing.expect(view_skill.view_skill_tool.function.parameters.properties.len == 1);
}

test "view_skill_tool - required fields are correct" {
    const params = view_skill.view_skill_tool.function.parameters;
    // skill_name is optional (empty required array)
    try std.testing.expect(params.required.len == 0);
}

test "ViewSkillInput - has correct defaults" {
    const input = view_skill.ViewSkillInput{
        .skill_name = null,
    };
    try std.testing.expect(input.skill_name == null);
}

test "ViewSkillInput - skill_name can be set" {
    const input = view_skill.ViewSkillInput{
        .skill_name = "test-skill",
    };
    try std.testing.expect(input.skill_name != null);
    try std.testing.expectEqualStrings("test-skill", input.skill_name.?);
}

test "ViewSkillResult - has correct struct fields" {
    const result = view_skill.ViewSkillResult{
        .skill_name = "test",
        .description = "A test skill",
        .found = true,
        .err_msg = null,
    };
    try std.testing.expectEqualStrings("test", result.skill_name);
    try std.testing.expectEqualStrings("A test skill", result.description);
    try std.testing.expect(result.found == true);
    try std.testing.expect(result.err_msg == null);
}

test "toXmlSuccess - generates valid XML structure" {
    const alloc = std.testing.allocator;

    const result = view_skill.ViewSkillResult{
        .skill_name = "my-test-skill",
        .description = "Test description for skill",
        .found = true,
    };

    const xml = try view_skill.toXmlSuccess(alloc, result);
    defer alloc.free(xml);

    try std.testing.expect(contains(xml, "<skill_name>my-test-skill</skill_name>"));
    try std.testing.expect(contains(xml, "<description>Test description for skill</description>"));
    try std.testing.expect(contains(xml, "<found>true</found>"));
}

test "toXmlSuccess - escapes special characters in skill_name" {
    const alloc = std.testing.allocator;

    const result = view_skill.ViewSkillResult{
        .skill_name = "skill <with> & \"special\" chars",
        .description = "desc",
        .found = true,
    };

    const xml = try view_skill.toXmlSuccess(alloc, result);
    defer alloc.free(xml);

    // Should contain escaped versions
    try std.testing.expect(contains(xml, "&lt;with&gt;"));
    try std.testing.expect(contains(xml, "&amp;"));
    try std.testing.expect(contains(xml, "&quot;special&quot;"));
}

test "toXmlSuccess - escapes special characters in description" {
    const alloc = std.testing.allocator;

    const result = view_skill.ViewSkillResult{
        .skill_name = "test",
        .description = "A description with <html> & special 'chars'",
        .found = true,
    };

    const xml = try view_skill.toXmlSuccess(alloc, result);
    defer alloc.free(xml);

    // Should contain escaped versions
    try std.testing.expect(contains(xml, "&lt;html&gt;"));
    try std.testing.expect(contains(xml, "&amp;"));
    try std.testing.expect(contains(xml, "&apos;chars&apos;"));
}

test "toXmlError - generates error XML structure" {
    const alloc = std.testing.allocator;

    const xml = try view_skill.toXmlError(alloc, error.InvalidInput, "my-skill");
    defer alloc.free(xml);

    try std.testing.expect(contains(xml, "<skill_name>my-skill</skill_name>"));
    try std.testing.expect(contains(xml, "<description></description>"));
    try std.testing.expect(contains(xml, "<found>false</found>"));
    try std.testing.expect(contains(xml, "<error>InvalidInput</error>"));
}

test "toXmlError - escapes special characters in skill_name" {
    const alloc = std.testing.allocator;

    const xml = try view_skill.toXmlError(alloc, error.TestError, "skill <with> & chars");
    defer alloc.free(xml);

    // Should contain escaped versions
    try std.testing.expect(contains(xml, "&lt;with&gt;"));
    try std.testing.expect(contains(xml, "&amp;"));
}

test "execute_view_skill_to_string - null skill_name returns error" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    const input = view_skill.ViewSkillInput{
        .skill_name = null,
    };

    // null skill_name should return an error
    const result = view_skill.execute_view_skill_to_string(alloc, io, input, null);
    try std.testing.expectError(error.InvalidInput, result);
}

test "execute_view_skill_to_string - skill-not-found output has no freed-memory fill bytes (use-after-free regression)" {
    // Regression test for the use-after-free bug in buildSkillNotFoundResponse.
    //
    // The previous implementation copied `skill.name` slice headers into an
    // intermediate `all_skills: ArrayList([]const u8)`, then
    // `defer free_skills_list(allocator, ...)` freed the backing memory. The
    // subsequent loop read 0xAA-filled freed memory (Zig debug allocator's
    // free-fill pattern) instead of real skill names, producing garbled
    // `<skill>...</skill>` entries in the `available_skills` section.
    //
    // We point HOME at a temp dir containing a known global skill, then call
    // `execute_view_skill_to_string` with a non-existent name and assert
    // that (a) the output has no 0xAA bytes, and (b) our known skill name
    // appears in the `available_skills` list.
    //
    // We use HOME (not cwd) because `get_local_skills_path_from_io` relies
    // on `std.Io.Dir.cwd().realPath`, which is unreliable under
    // `std.testing.io`. The HOME path is built from the env var alone, with
    // no realPath call, so it's stable in tests.
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    const unique_skill_name = "_regression_uaf_view_skill_test";
    const tmp_home = "/tmp/nalar-uaf-view-test-home";
    const global_skills_dir = "/tmp/nalar-uaf-view-test-home/.config/nalar/skills";

    const skill_dir_path = try std.fs.path.join(alloc, &[_][]const u8{ global_skills_dir, unique_skill_name });
    defer alloc.free(skill_dir_path);
    const skill_file_path = try std.fs.path.join(alloc, &[_][]const u8{ skill_dir_path, "SKILL.MD" });
    defer alloc.free(skill_file_path);

    std.Io.Dir.cwd().deleteTree(io, tmp_home) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, tmp_home) catch {};

    try std.Io.Dir.cwd().createDirPath(io, skill_dir_path);

    const skill_content =
        \\---
        \\name: _regression_uaf_view_skill_test
        \\description: "Regression test skill for use-after-free in buildSkillNotFoundResponse"
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

    var env = std.process.Environ.Map.init(alloc);
    defer env.deinit();
    try env.put("HOME", tmp_home);

    const output = try view_skill.execute_view_skill_to_string(
        alloc,
        io,
        .{ .skill_name = "definitely-not-a-real-skill-xyz" },
        &env,
    );
    defer alloc.free(output);

    // Sanity: response structure is correct.
    try std.testing.expect(contains(output, "<found>false</found>"));
    try std.testing.expect(contains(output, "<error>Skill not found</error>"));
    try std.testing.expect(contains(output, "<available_skills>"));
    try std.testing.expect(contains(output, "</available_skills>"));

    // The known skill name must appear in the available_skills list.
    try std.testing.expect(contains(output, unique_skill_name));

    // CRITICAL: no 0xAA bytes (Zig debug allocator's free-fill pattern).
    try std.testing.expect(std.mem.indexOfScalar(u8, output, 0xAA) == null);
}

test "execute_view_skill_to_string - empty skill_name returns error" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    const input = view_skill.ViewSkillInput{
        .skill_name = "",
    };

    // Empty string skill_name should return an error
    const result = view_skill.execute_view_skill_to_string(alloc, io, input, null);
    try std.testing.expectError(error.InvalidInput, result);
}

test "view_skill_tool - description is descriptive" {
    // The tool description should explain what the tool does
    try std.testing.expect(view_skill.view_skill_tool.function.description.len > 10);
    try std.testing.expect(contains(view_skill.view_skill_tool.function.description, "skill"));
    try std.testing.expect(contains(view_skill.view_skill_tool.function.description, "description"));
}
