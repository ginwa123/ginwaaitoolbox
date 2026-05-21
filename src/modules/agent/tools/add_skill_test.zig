const std = @import("std");
const add_skill = @import("add_skill.zig");

// Helper to check if string contains substring
fn contains(haystack: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, haystack, needle) != null;
}

// Helper to extract content between tags
fn extractTag(content: []const u8, tag: []const u8) ?[]const u8 {
    const start = std.mem.indexOf(u8, content, "<" ++ tag ++ ">") orelse return null;
    const end = std.mem.indexOf(u8, content, "</" ++ tag ++ ">") orelse return null;
    return content[start + tag.len + 2 .. end];
}

test "executeAddSkillToString - empty name returns error XML" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    const input = add_skill.AddSkillInput{
        .name = "",
        .description = "Test description",
        .content = "Test content",
    };

    const cwd = "/tmp";
    const result = add_skill.executeAddSkillToString(alloc, io, cwd, input);
    defer alloc.free(result);

    try std.testing.expect(contains(result, "<created>false</created>"));
    try std.testing.expect(contains(result, "<error>Skill name cannot be empty</error>"));
}

test "executeAddSkillToString - empty description returns error XML" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    const input = add_skill.AddSkillInput{
        .name = "test-skill",
        .description = "",
        .content = "Test content",
    };

    const cwd = "/tmp";
    const result = add_skill.executeAddSkillToString(alloc, io, cwd, input);
    defer alloc.free(result);

    try std.testing.expect(contains(result, "<created>false</created>"));
    try std.testing.expect(contains(result, "<error>Description cannot be empty</error>"));
}

test "executeAddSkillToString - empty content returns error XML" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    const input = add_skill.AddSkillInput{
        .name = "test-skill",
        .description = "Test description",
        .content = "",
    };

    const cwd = "/tmp";
    const result = add_skill.executeAddSkillToString(alloc, io, cwd, input);
    defer alloc.free(result);

    try std.testing.expect(contains(result, "<created>false</created>"));
    try std.testing.expect(contains(result, "<error>Content cannot be empty</error>"));
}

test "buildSkillContent - generates valid frontmatter structure" {
    const alloc = std.testing.allocator;

    const input = add_skill.AddSkillInput{
        .name = "my-test-skill",
        .description = "Test description",
        .content = "Skill body content",
    };

    const result = add_skill.buildSkillContent(alloc, input);
    defer alloc.free(result);

    // Should start with YAML frontmatter
    try std.testing.expect(std.mem.startsWith(u8, result, "---\n"));
    try std.testing.expect(contains(result, "name: my-test-skill\n"));
    try std.testing.expect(contains(result, "description: \"Test description\"\n"));
    try std.testing.expect(contains(result, "---\n"));
    // Should end with content
    try std.testing.expect(std.mem.endsWith(u8, result, "Skill body content\n"));
}

test "buildSkillContent - escapes double quotes in description" {
    const alloc = std.testing.allocator;

    const input = add_skill.AddSkillInput{
        .name = "test-skill",
        .description = "A skill with \"quotes\" inside",
        .content = "Content",
    };

    const result = add_skill.buildSkillContent(alloc, input);
    defer alloc.free(result);

    // Should have escaped quotes
    try std.testing.expect(contains(result, "\\\"quotes\\\""));
    // Should NOT have unescaped quotes in description line
    const desc_line = std.mem.indexOf(u8, result, "description: \"") orelse return;
    const next_newline = std.mem.indexOf(u8, result[desc_line..], "\n") orelse return;
    const desc_content = result[desc_line .. desc_line + next_newline];
    try std.testing.expect(std.mem.indexOf(u8, desc_content, "\"quotes\"") == null);
}

test "buildSkillContent - escapes backslashes in description" {
    const alloc = std.testing.allocator;

    const input = add_skill.AddSkillInput{
        .name = "test-skill",
        .description = "Path: C:\\Users\\test",
        .content = "Content",
    };

    const result = add_skill.buildSkillContent(alloc, input);
    defer alloc.free(result);

    // Should have escaped backslashes
    try std.testing.expect(contains(result, "\\\\"));
}

test "xmlError - generates error XML with name" {
    const alloc = std.testing.allocator;

    const result = add_skill.xmlError(alloc, "my-skill", "Something went wrong");
    defer alloc.free(result);

    try std.testing.expect(contains(result, "<name>my-skill</name>"));
    try std.testing.expect(contains(result, "<created>false</created>"));
    try std.testing.expect(contains(result, "<error>Something went wrong</error>"));
}

test "xmlErrorEmpty - generates error XML with empty name" {
    const alloc = std.testing.allocator;

    const result = add_skill.xmlErrorEmpty(alloc, "Parse failed");
    defer alloc.free(result);

    try std.testing.expect(contains(result, "<name></name>"));
    try std.testing.expect(contains(result, "<created>false</created>"));
    try std.testing.expect(contains(result, "<error>Parse failed</error>"));
}

test "add_skill_tool - has correct tool definition" {
    try std.testing.expectEqualStrings("add_skill", add_skill.add_skill_tool.function.name);
    try std.testing.expect(add_skill.add_skill_tool.function.parameters.properties.len == 3);
}

test "add_skill_tool - required fields are correct" {
    const params = add_skill.add_skill_tool.function.parameters;
    try std.testing.expect(params.required.len == 3);
    try std.testing.expect(std.mem.eql(u8, params.required[0], "name"));
    try std.testing.expect(std.mem.eql(u8, params.required[1], "description"));
    try std.testing.expect(std.mem.eql(u8, params.required[2], "content"));
}

test "AddSkillInput - has correct defaults" {
    const input = add_skill.AddSkillInput{
        .name = "test",
        .description = "desc",
        .content = "content",
    };
    // create_with_dir defaults to true
    try std.testing.expect(input.create_with_dir == true);
}

test "AddSkillInput - create_with_dir can be set to false" {
    const input = add_skill.AddSkillInput{
        .name = "test",
        .description = "desc",
        .content = "content",
        .create_with_dir = false,
    };
    try std.testing.expect(input.create_with_dir == false);
}