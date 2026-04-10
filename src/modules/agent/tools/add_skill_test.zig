const std = @import("std");
const add_skill = @import("add_skill.zig");
const AddSkillInput = add_skill.AddSkillInput;

test "AddSkillInput with all required fields" {
    const input = AddSkillInput{
        .name = "test-skill",
        .description = "A test skill for testing",
        .content = "# Test Skill\n\nThis is a test skill.",
    };
    
    try std.testing.expectEqualStrings("test-skill", input.name);
    try std.testing.expectEqualStrings("A test skill for testing", input.description);
    try std.testing.expectEqualStrings("# Test Skill\n\nThis is a test skill.", input.content);
}

test "AddSkillInput default create_with_dir is true" {
    const input = AddSkillInput{
        .name = "test-skill",
        .description = "Description",
        .content = "Content",
    };
    
    try std.testing.expect(input.create_with_dir == true);
}

test "AddSkillInput with create_with_dir set to false" {
    const input = AddSkillInput{
        .name = "test-skill",
        .description = "Description",
        .content = "Content",
        .create_with_dir = false,
    };
    
    try std.testing.expect(input.create_with_dir == false);
}

test "add_skill_tool has correct structure" {
    try std.testing.expectEqualStrings("function", add_skill.add_skill_tool.type);
    try std.testing.expectEqualStrings("add_skill", add_skill.add_skill_tool.function.name);
    try std.testing.expectEqualStrings("object", add_skill.add_skill_tool.function.parameters.type);
    try std.testing.expect(add_skill.add_skill_tool.function.parameters.properties.len > 0);
}

test "add_skill_tool has required properties" {
    const props = add_skill.add_skill_tool.function.parameters.properties;
    
    var has_name = false;
    var has_description = false;
    var has_content = false;
    
    for (props) |prop| {
        if (std.mem.eql(u8, prop.name, "name")) has_name = true;
        if (std.mem.eql(u8, prop.name, "description")) has_description = true;
        if (std.mem.eql(u8, prop.name, "content")) has_content = true;
    }
    
    try std.testing.expect(has_name);
    try std.testing.expect(has_description);
    try std.testing.expect(has_content);
}

test "add_skill_tool has required fields marked as required" {
    const required = add_skill.add_skill_tool.function.parameters.required;
    
    var has_name = false;
    var has_description = false;
    var has_content = false;
    
    for (required) |req| {
        if (std.mem.eql(u8, req, "name")) has_name = true;
        if (std.mem.eql(u8, req, "description")) has_description = true;
        if (std.mem.eql(u8, req, "content")) has_content = true;
    }
    
    try std.testing.expect(has_name);
    try std.testing.expect(has_description);
    try std.testing.expect(has_content);
}

test "executeAddSkillToString returns error for empty name" {
    const allocator = std.testing.allocator;
    
    const input = AddSkillInput{
        .name = "",
        .description = "Description",
        .content = "Content",
    };
    
    const result = add_skill.executeAddSkillToString(allocator, input);
    try std.testing.expectError(error.InvalidInput, result);
}

test "executeAddSkillToString returns error for empty description" {
    const allocator = std.testing.allocator;
    
    const input = AddSkillInput{
        .name = "valid-name",
        .description = "",
        .content = "Content",
    };
    
    const result = add_skill.executeAddSkillToString(allocator, input);
    try std.testing.expectError(error.InvalidInput, result);
}

test "executeAddSkillToString returns error for empty content" {
    const allocator = std.testing.allocator;
    
    const input = AddSkillInput{
        .name = "valid-name",
        .description = "Description",
        .content = "",
    };
    
    const result = add_skill.executeAddSkillToString(allocator, input);
    try std.testing.expectError(error.InvalidInput, result);
}

test "executeAddSkillToString creates skill file with valid structure" {
    const allocator = std.testing.allocator;
    
    // Create a temporary directory
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    
    // Get the realpath to temp directory
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp_path = try tmp_dir.dir.realpath(".", &path_buf);
    
    // Build expected paths
    const skill_file_path = try std.fs.path.join(allocator, &[_][]const u8{ tmp_path, ".nalar", "skills", "test-skill", "SKILL.MD" });
    defer allocator.free(skill_file_path);
    
    // Change to temp directory
    try std.posix.chdir(tmp_path);
    
    // Create skill
    const input = AddSkillInput{
        .name = "test-skill",
        .description = "A test skill",
        .content = "# Test Skill\n\nThis skill was created by a test.",
    };
    
    const result = try add_skill.executeAddSkillToString(allocator, input);
    defer allocator.free(result);
    
    // Verify result contains success XML
    try std.testing.expect(std.mem.indexOf(u8, result, "<created>true</created>") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "<path>") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "test-skill") != null);
    
    // Verify file was created
    const file = try std.fs.openFileAbsolute(skill_file_path, .{});
    defer file.close();
    
    const stat = try file.stat();
    try std.testing.expect(stat.size > 0);
    
    // Read and verify content
    const content = try file.readToEndAlloc(allocator, stat.size + 1);
    defer allocator.free(content);
    
    try std.testing.expect(std.mem.indexOf(u8, content, "name: test-skill") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "description: \"A test skill\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "# Test Skill") != null);
}
