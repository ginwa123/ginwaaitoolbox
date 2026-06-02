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
