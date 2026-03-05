const std = @import("std");
const builtin = @import("builtin");
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

// ============================================
// Tests for new path resolution functions
// ============================================

test "getLocalSkillsPath returns a valid path structure" {
    const testing = std.testing;
    const allocator = testing.allocator;
    
    const path = skills.getLocalSkillsPath(allocator);
    if (path) |p| {
        defer allocator.free(p);
        
        // Path should contain the local skills directory and filename
        try testing.expect(std.mem.indexOf(u8, p, ".zigginagentic") != null);
        try testing.expect(std.mem.indexOf(u8, p, "skills") != null);
        try testing.expect(std.mem.indexOf(u8, p, "skill.md") != null);
    }
}

test "getGlobalSkillsPath returns XDG-compliant path" {
    const testing = std.testing;
    const allocator = testing.allocator;
    
    const path = skills.getGlobalSkillsPath(allocator);
    if (path) |p| {
        defer allocator.free(p);
        
        // Path should contain the app name and skills directory
        try testing.expect(std.mem.indexOf(u8, p, "zigginagentic") != null);
        try testing.expect(std.mem.indexOf(u8, p, "skills") != null);
        try testing.expect(std.mem.indexOf(u8, p, "skill.md") != null);
        
        // On Linux, should contain .config or XDG_CONFIG_HOME
        if (builtin.os.tag == .linux) {
            const has_config = std.mem.indexOf(u8, p, ".config") != null or 
                               std.posix.getenv("XDG_CONFIG_HOME") != null;
            try testing.expect(has_config);
        }
    }
}

test "resolveSkillsPath returns null when no skills file exists" {
    const testing = std.testing;
    const allocator = testing.allocator;
    
    // This test assumes no skills file exists in default locations
    // The function should return null gracefully
    const path = skills.resolveSkillsPath(allocator);
    if (path) |p| {
        defer allocator.free(p);
        // If a path was returned, the file should exist
        std.fs.cwd().access(p, .{}) catch {
            try testing.expect(false); // Should not happen
        };
    }
    // null is also a valid result when no skills file exists
}

test "freeSkillsPath properly frees allocated path" {
    const testing = std.testing;
    const allocator = testing.allocator;
    
    // Get a path and free it - this should not cause memory issues
    if (skills.getLocalSkillsPath(allocator)) |path| {
        skills.freeSkillsPath(allocator, path);
    }
    // Test passes if no crash or memory leak
}
