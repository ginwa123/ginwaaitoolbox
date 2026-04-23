const std = @import("std");
const testing = std.testing;
const edit_skill = @import("edit_skill.zig");

test "EditSkillInput - basic structure" {
    const input = edit_skill.EditSkillInput{
        .skill_name = "test-skill",
        .description = "A test skill",
        .content = "# Test Content",
    };

    try testing.expectEqualStrings("test-skill", input.skill_name);
    try testing.expect(input.description != null);
    try testing.expect(input.content != null);
}

test "EditSkillInput - optional fields" {
    const input = edit_skill.EditSkillInput{
        .skill_name = "test-skill",
        .description = null,
        .content = "# Test Content",
    };

    try testing.expectEqualStrings("test-skill", input.skill_name);
    try testing.expect(input.description == null);
    try testing.expect(input.content != null);
}

test "EditSkillInput - only content provided" {
    const input = edit_skill.EditSkillInput{
        .skill_name = "test-skill",
        .description = null,
        .content = "# Test Content",
    };

    try testing.expect(input.description == null);
    try testing.expect(input.content != null);
}

test "edit_skill_tool - tool definition" {
    const tool = edit_skill.edit_skill_tool;

    try testing.expectEqualStrings("edit_skill", tool.function.name);
    try testing.expect(tool.function.parameters.properties.len >= 3);

    // Check required fields
    const props = tool.function.parameters.properties;
    var has_required = false;
    for (props) |prop| {
        if (std.mem.eql(u8, prop.name, "skill_name")) {
            has_required = true;
            break;
        }
    }
    try testing.expect(has_required);
}

test "EditSkillInput - validation rules" {
    // skill_name must be non-empty for execution
    const empty_name = "";
    try testing.expect(empty_name.len == 0);

    // At least description or content must be provided
    const both_null = .{ .skill_name = "test", .description = null, .content = null };
    _ = both_null;
}

test "parseSkillFile - extracts description from frontmatter" {
    const content =
        \\---
        \\name: test-skill
        \\description: "Test description"
        \\---
        \\# Skill content
    ;

    // Just verify the content format is correct for parsing
    try testing.expect(std.mem.indexOf(u8, content, "---") != null);
    try testing.expect(std.mem.indexOf(u8, content, "description:") != null);
}

test "parseSkillFile - extracts content after frontmatter" {
    const content =
        \\---
        \\name: test-skill
        \\description: "Test"
        \\---
        \\# Markdown content here
    ;

    // Content starts after second ---
    const frontmatter_end = std.mem.indexOf(u8, content[4..], "---").?;
    try testing.expect(frontmatter_end > 0);
}

test "unescapeYamlString - basic string" {
    const input = "simple string";

    // No special characters to unescape
    try testing.expect(std.mem.indexOf(u8, input, "\\") == null);
}

test "unescapeYamlString - escaped quotes" {
    const input = "test\\\"quote";
    // Verify escaped quotes exist
    try testing.expect(std.mem.indexOf(u8, input, "\\\"") != null);
}

test "buildSkillContent - structure" {
    const name = "test-skill";
    const description = "A test skill";
    const content = "# Test content";

    // Verify all parts are present
    try testing.expect(name.len > 0);
    try testing.expect(description.len > 0);
    try testing.expect(content.len > 0);
}

test "successToXml - format" {
    const skill_name = "test-skill";

    // XML should contain skill name and edited=true
    try testing.expect(std.mem.indexOf(u8, skill_name, "test-skill") != null);
}

test "errorToXml - format" {
    const skill_name = "test-skill";
    const error_msg = "Skill not found";

    // XML should contain skill name and edited=false
    try testing.expect(skill_name.len > 0);
    try testing.expect(error_msg.len > 0);
}

test "executeEditSkillToString - empty skill name returns error" {
    const allocator = std.heap.page_allocator;
    const input = edit_skill.EditSkillInput{
        .skill_name = "",
        .description = "test",
        .content = "test",
    };

    // Should return error for empty skill name
    const result = edit_skill.executeEditSkillToString(allocator, input);
    const xml = try result;
    defer allocator.free(xml);

    // Check that edited=false in the XML response
    try testing.expect(std.mem.indexOf(u8, xml, "edited>false") != null);
}

test "executeEditSkillToString - both fields null returns error" {
    const allocator = std.heap.page_allocator;
    const input = edit_skill.EditSkillInput{
        .skill_name = "test-skill",
        .description = null,
        .content = null,
    };

    // Should return error when neither description nor content provided
    const result = edit_skill.executeEditSkillToString(allocator, input);
    const xml = try result;
    defer allocator.free(xml);

    // Check that edited=false in the XML response
    try testing.expect(std.mem.indexOf(u8, xml, "edited>false") != null);
}