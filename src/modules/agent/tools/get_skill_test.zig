const std = @import("std");
const get_skill = @import("get_skill.zig");
const GetSkillInput = get_skill.GetSkillInput;

test "GetSkillInput with skill_name only" {
    const input = GetSkillInput{
        .skill_name = "test-skill",
        .path = null,
    };

    try std.testing.expectEqualStrings("test-skill", input.skill_name.?);
    try std.testing.expect(input.path == null);
}

test "GetSkillInput with path only" {
    const input = GetSkillInput{
        .skill_name = null,
        .path = "/absolute/path/to/skill.md",
    };

    try std.testing.expect(input.skill_name == null);
    try std.testing.expectEqualStrings("/absolute/path/to/skill.md", input.path.?);
}

test "GetSkillInput with both fields" {
    const input = GetSkillInput{
        .skill_name = "test-skill",
        .path = "/absolute/path/to/skill.md",
    };

    try std.testing.expectEqualStrings("test-skill", input.skill_name.?);
    try std.testing.expectEqualStrings("/absolute/path/to/skill.md", input.path.?);
}

test "GetSkillInput with null fields" {
    const input = GetSkillInput{
        .skill_name = null,
        .path = null,
    };

    try std.testing.expect(input.skill_name == null);
    try std.testing.expect(input.path == null);
}

test "GetSkillInput default values" {
    const input = GetSkillInput{};

    try std.testing.expect(input.skill_name == null);
    try std.testing.expect(input.path == null);
}

test "execute_get_skill_to_string with path loads from file" {
    const allocator = std.testing.allocator;

    // Create a temporary test file
    const test_path = "/tmp/test_skill.md";
    const test_content = "# Test Skill\n\nThis is a test skill content.";

    // Write test file
    const file = try std.fs.createFileAbsolute(test_path, .{});
    defer std.fs.deleteFileAbsolute(test_path) catch {};
    try file.writeAll(test_content);
    file.close();

    // Execute with path
    const input = GetSkillInput{
        .path = test_path,
        .skill_name = null,
    };

    const result = try get_skill.execute_get_skill_to_string(allocator, input);
    defer allocator.free(result);

    // Verify result contains skill content
    try std.testing.expect(std.mem.indexOf(u8, result, "test_skill") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, test_content) != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "<loaded>true</loaded>") != null);
}

test "execute_get_skill_to_string with invalid path returns error" {
    const allocator = std.testing.allocator;

    const input = GetSkillInput{
        .path = "/nonexistent/path/to/skill.md",
        .skill_name = null,
    };

    const result = try get_skill.execute_get_skill_to_string(allocator, input);
    defer allocator.free(result);

    // Verify result contains error
    try std.testing.expect(std.mem.indexOf(u8, result, "<loaded>false</loaded>") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "Failed to open file") != null);
}

test "execute_get_skill_to_string with non-existent skill_name lists available" {
    const allocator = std.testing.allocator;

    const input = GetSkillInput{
        .skill_name = "non-existent-skill-xyz",
        .path = null,
    };

    const result = try get_skill.execute_get_skill_to_string(allocator, input);
    defer allocator.free(result);

    // Verify result contains error and available skills
    try std.testing.expect(std.mem.indexOf(u8, result, "<loaded>false</loaded>") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "Skill not found") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "<available_skills>") != null);
}

test "execute_get_skill_to_string with no input returns error" {
    const allocator = std.testing.allocator;

    const input = GetSkillInput{};

    const result = get_skill.execute_get_skill_to_string(allocator, input);
    try std.testing.expectError(error.InvalidInput, result);
}
