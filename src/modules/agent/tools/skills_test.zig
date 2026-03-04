const std = @import("std");
const skills = @import("skills.zig");

test "loadSkills returns empty string for missing file" {
    const testing = std.testing;
    const allocator = testing.allocator;
    
    const result = skills.loadSkillsFromPath(allocator, "nonexistent/path/skills.md");
    defer allocator.free(result);
    
    try testing.expectEqualStrings("", result);
}

test "loadSkills loads valid file" {
    const testing = std.testing;
    const allocator = testing.allocator;
    
    // Create a temporary test file
    const test_content = "# Test Skills\n\nThis is a test.";
    const test_file = std.fs.cwd().createFile(
        "test_skills_temp.md",
        .{ .truncate = true }
    ) catch |err| {
        std.debug.print("Could not create test file: {s}\n", .{@errorName(err)});
        return error.SkipZigTest;
    };
    defer {
        test_file.close();
        std.fs.cwd().deleteFile("test_skills_temp.md") catch {};
    }
    
    try test_file.writeAll(test_content);
    
    const result = skills.loadSkillsFromPath(allocator, "test_skills_temp.md");
    defer allocator.free(result);
    
    try testing.expectEqualStrings(test_content, result);
}

test "loadSkills returns empty string for empty file" {
    const testing = std.testing;
    const allocator = testing.allocator;
    
    // Create an empty test file
    const test_file = std.fs.cwd().createFile(
        "test_skills_empty.md",
        .{ .truncate = true }
    ) catch |err| {
        std.debug.print("Could not create test file: {s}\n", .{@errorName(err)});
        return error.SkipZigTest;
    };
    defer {
        test_file.close();
        std.fs.cwd().deleteFile("test_skills_empty.md") catch {};
    }
    
    const result = skills.loadSkillsFromPath(allocator, "test_skills_empty.md");
    defer allocator.free(result);
    
    try testing.expectEqualStrings("", result);
}

test "loadSkills returns empty string for whitespace-only file" {
    const testing = std.testing;
    const allocator = testing.allocator;
    
    // Create a whitespace-only test file
    const test_file = std.fs.cwd().createFile(
        "test_skills_whitespace.md",
        .{ .truncate = true }
    ) catch |err| {
        std.debug.print("Could not create test file: {s}\n", .{@errorName(err)});
        return error.SkipZigTest;
    };
    defer {
        test_file.close();
        std.fs.cwd().deleteFile("test_skills_whitespace.md") catch {};
    }
    
    try test_file.writeAll("   \n\t\n   ");
    
    const result = skills.loadSkillsFromPath(allocator, "test_skills_whitespace.md");
    defer allocator.free(result);
    
    try testing.expectEqualStrings("", result);
}

test "parseSkill returns skill content for valid skill name" {
    const testing = std.testing;
    const allocator = testing.allocator;
    
    // Create a temporary test file with delimited skills
    const test_content = 
        \\# Test Skills
        \\
        \\<!-- SKILL: test_skill -->
        \\## Test Skill
        \\This is a test skill.
        \\<!-- END_SKILL -->
        \\
        \\<!-- SKILL: another_skill -->
        \\## Another Skill
        \\This is another skill.
        \\<!-- END_SKILL -->
    ;
    
    const test_file = std.fs.cwd().createFile(
        "test_skills_parse.md",
        .{ .truncate = true }
    ) catch |err| {
        std.debug.print("Could not create test file: {s}\n", .{@errorName(err)});
        return error.SkipZigTest;
    };
    defer {
        test_file.close();
        std.fs.cwd().deleteFile("test_skills_parse.md") catch {};
    }
    
    try test_file.writeAll(test_content);
    
    const result = skills.parseSkillFromPath(allocator, "test_skills_parse.md", "test_skill");
    defer if (result) |r| allocator.free(r);
    
    try testing.expect(result != null);
    try testing.expectEqualStrings("## Test Skill\nThis is a test skill.", result.?);
}

test "parseSkill returns null for invalid skill name" {
    const testing = std.testing;
    const allocator = testing.allocator;
    
    // Create a temporary test file with delimited skills
    const test_content = 
        \\# Test Skills
        \\
        \\<!-- SKILL: test_skill -->
        \\## Test Skill
        \\This is a test skill.
        \\<!-- END_SKILL -->
    ;
    
    const test_file = std.fs.cwd().createFile(
        "test_skills_parse_invalid.md",
        .{ .truncate = true }
    ) catch |err| {
        std.debug.print("Could not create test file: {s}\n", .{@errorName(err)});
        return error.SkipZigTest;
    };
    defer {
        test_file.close();
        std.fs.cwd().deleteFile("test_skills_parse_invalid.md") catch {};
    }
    
    try test_file.writeAll(test_content);
    
    const result = skills.parseSkillFromPath(allocator, "test_skills_parse_invalid.md", "nonexistent_skill");
    
    try testing.expect(result == null);
}

test "listSkills returns all skills" {
    const testing = std.testing;
    const allocator = testing.allocator;
    
    // Create a temporary test file with delimited skills
    const test_content = 
        \\# Test Skills
        \\
        \\<!-- SKILL: code_review -->
        \\## Code Review Skill
        \\When reviewing code, check for bugs.
        \\<!-- END_SKILL -->
        \\
        \\<!-- SKILL: debugging -->
        \\## Debugging Skill
        \\When debugging, reproduce the issue first.
        \\<!-- END_SKILL -->
    ;
    
    const test_file = std.fs.cwd().createFile(
        "test_skills_list.md",
        .{ .truncate = true }
    ) catch |err| {
        std.debug.print("Could not create test file: {s}\n", .{@errorName(err)});
        return error.SkipZigTest;
    };
    defer {
        test_file.close();
        std.fs.cwd().deleteFile("test_skills_list.md") catch {};
    }
    
    try test_file.writeAll(test_content);
    
    const result = skills.listSkillsFromPath(allocator, "test_skills_list.md");
    defer skills.freeSkillsList(allocator, result);
    
    try testing.expectEqual(@as(usize, 2), result.len);
    try testing.expectEqualStrings("code_review", result[0].name);
    try testing.expectEqualStrings("debugging", result[1].name);
}
