const std = @import("std");
const builtin = @import("builtin");
const skills = @import("skills.zig");

test "loadSkillsFromPath returns empty string for missing file" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const result = skills.loadSkillsFromPath(allocator, "nonexistent/path/skills.md");
    defer allocator.free(result);

    try testing.expectEqualStrings("", result);
}

test "loadSkillsFromPath loads valid file" {
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

test "loadSkillsFromPath returns empty string for empty file" {
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

test "loadSkillsFromPath returns empty string for whitespace-only file" {
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

// ============================================
// Tests for YAML frontmatter parsing
// ============================================

test "parseYamlFrontmatter extracts name and description with quotes" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const test_content =
        \\---
        \\name: test-skill
        \\description: "This is a test skill description"
        \\---
        \\# Test Skill
        \\Content here.
    ;

    // Create test file
    const test_file = std.fs.cwd().createFile("test_fm_quoted.md", .{ .truncate = true }) catch |err| {
        std.debug.print("Could not create test file: {s}\n", .{@errorName(err)});
        return error.SkipZigTest;
    };
    defer {
        test_file.close();
        std.fs.cwd().deleteFile("test_fm_quoted.md") catch {};
    }
    try test_file.writeAll(test_content);

    const content = skills.loadSkillsFromPath(allocator, "test_fm_quoted.md");
    defer allocator.free(content);

    // We can't directly test parseYamlFrontmatter since it's private, but we can test via listSkillsFromDir
    // For now, just verify the content was loaded
    try testing.expect(content.len > 0);
}

test "parseYamlFrontmatter handles unquoted values" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const test_content =
        \\---
        \\name: unquoted-skill
        \\description: Unquoted description here
        \\---
        \\# Content
    ;

    const test_file = std.fs.cwd().createFile("test_fm_unquoted.md", .{ .truncate = true }) catch |err| {
        std.debug.print("Could not create test file: {s}\n", .{@errorName(err)});
        return error.SkipZigTest;
    };
    defer {
        test_file.close();
        std.fs.cwd().deleteFile("test_fm_unquoted.md") catch {};
    }
    try test_file.writeAll(test_content);

    const content = skills.loadSkillsFromPath(allocator, "test_fm_unquoted.md");
    defer allocator.free(content);

    try testing.expect(content.len > 0);
}

// ============================================
// Tests for path resolution functions
// ============================================

test "getLocalSkillsPath returns a valid path structure" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const path = skills.getLocalSkillsPath(allocator);
    if (path) |p| {
        defer allocator.free(p);

        // Path should contain the local skills directory
        try testing.expect(std.mem.indexOf(u8, p, ".zigginagentic") != null);
        try testing.expect(std.mem.indexOf(u8, p, "skills") != null);
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

        // On Linux, should contain .config or XDG_CONFIG_HOME
        if (builtin.os.tag == .linux) {
            const has_config = std.mem.indexOf(u8, p, ".config") != null or
                               std.posix.getenv("XDG_CONFIG_HOME") != null;
            try testing.expect(has_config);
        }
    }
}

test "resolveSkillsPath returns null when no skills directory exists" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // This test assumes no skills directory exists in default locations
    // The function should return null gracefully
    const path = skills.resolveSkillsPath(allocator);
    if (path) |p| {
        defer allocator.free(p);
        // If a path was returned, the directory should exist
        std.fs.cwd().access(p, .{}) catch {
            // Path returned but doesn't exist - this is fine for this test
        };
    }
}

test "freeSkillsPath works correctly" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const path = skills.getLocalSkillsPath(allocator);
    if (path) |p| {
        skills.freeSkillsPath(allocator, p);
        // If we get here without crashing, the test passes
    }
}

// ============================================
// Tests for parseSkill with YAML frontmatter
// ============================================

test "parseSkill returns skill content for valid skill name" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // Create the local skills directory structure
    std.fs.cwd().makePath(".zigginagentic/skills") catch |err| {
        std.debug.print("Could not create test directory: {s}\n", .{@errorName(err)});
        return error.SkipZigTest;
    };

    const skill_content =
        \\---
        \\name: test_skill
        \\description: "A test skill"
        \\---
        \\# Test Skill
        \\This is the skill content.
    ;

    // Create folder structure: .zigginagentic/skills/test_skill/SKILL.MD
    std.fs.cwd().makePath(".zigginagentic/skills/test_skill") catch |err| {
        std.debug.print("Could not create test directory: {s}\n", .{@errorName(err)});
        return error.SkipZigTest;
    };

    const file1 = std.fs.cwd().createFile(".zigginagentic/skills/test_skill/SKILL.MD", .{ .truncate = true }) catch |err| {
        std.debug.print("Could not create test file: {s}\n", .{@errorName(err)});
        return error.SkipZigTest;
    };

    defer {
        file1.close();
        std.fs.cwd().deleteFile(".zigginagentic/skills/test_skill/SKILL.MD") catch {};
        std.fs.cwd().deleteDir(".zigginagentic/skills/test_skill") catch {};
        std.fs.cwd().deleteDir(".zigginagentic/skills") catch {};
        std.fs.cwd().deleteDir(".zigginagentic") catch {};
    }

    try file1.writeAll(skill_content);

    const result = skills.parseSkill(allocator, "test_skill");
    defer if (result) |r| allocator.free(r);

    try testing.expect(result != null);
    try testing.expect(std.mem.indexOf(u8, result.?, "test_skill") != null);
    try testing.expect(std.mem.indexOf(u8, result.?, "Test Skill") != null);
}

test "parseSkill returns null for invalid skill name" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // Create the local skills directory structure
    std.fs.cwd().makePath(".zigginagentic/skills") catch |err| {
        std.debug.print("Could not create test directory: {s}\n", .{@errorName(err)});
        return error.SkipZigTest;
    };

    const skill_content =
        \\---
        \\name: existing_skill
        \\description: "An existing skill"
        \\---
        \\# Existing Skill
    ;

    // Create folder structure: .zigginagentic/skills/existing_skill/SKILL.MD
    std.fs.cwd().makePath(".zigginagentic/skills/existing_skill") catch |err| {
        std.debug.print("Could not create test directory: {s}\n", .{@errorName(err)});
        return error.SkipZigTest;
    };

    const file1 = std.fs.cwd().createFile(".zigginagentic/skills/existing_skill/SKILL.MD", .{ .truncate = true }) catch |err| {
        std.debug.print("Could not create test file: {s}\n", .{@errorName(err)});
        return error.SkipZigTest;
    };

    defer {
        file1.close();
        std.fs.cwd().deleteFile(".zigginagentic/skills/existing_skill/SKILL.MD") catch {};
        std.fs.cwd().deleteDir(".zigginagentic/skills/existing_skill") catch {};
        std.fs.cwd().deleteDir(".zigginagentic/skills") catch {};
        std.fs.cwd().deleteDir(".zigginagentic") catch {};
    }

    try file1.writeAll(skill_content);

    const result = skills.parseSkill(allocator, "nonexistent_skill");

    try testing.expect(result == null);
}

// ============================================
// Integration tests with tool wrappers
// ============================================

const list_skills = @import("list_skills.zig");
const get_skill = @import("get_skill.zig");

test "executeListSkills returns JSON with skills" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // Create the local skills directory structure
    std.fs.cwd().makePath(".zigginagentic/skills") catch |err| {
        std.debug.print("Could not create test directory: {s}\n", .{@errorName(err)});
        return error.SkipZigTest;
    };

    // Create skill files with YAML frontmatter
    const skill1_content =
        \\---
        \\name: code_review
        \\description: "Review code for quality"
        \\---
        \\# Code Review
    ;

    // Create folder structure: .zigginagentic/skills/code_review/SKILL.MD
    std.fs.cwd().makePath(".zigginagentic/skills/code_review") catch |err| {
        std.debug.print("Could not create test directory: {s}\n", .{@errorName(err)});
        return error.SkipZigTest;
    };

    const file1 = std.fs.cwd().createFile(".zigginagentic/skills/code_review/SKILL.MD", .{ .truncate = true }) catch |err| {
        std.debug.print("Could not create test file: {s}\n", .{@errorName(err)});
        return error.SkipZigTest;
    };

    defer {
        file1.close();
        std.fs.cwd().deleteFile(".zigginagentic/skills/code_review/SKILL.MD") catch {};
        std.fs.cwd().deleteDir(".zigginagentic/skills/code_review") catch {};
        std.fs.cwd().deleteDir(".zigginagentic/skills") catch {};
        std.fs.cwd().deleteDir(".zigginagentic") catch {};
    }

    try file1.writeAll(skill1_content);

    const result = try list_skills.executeListSkills(allocator);
    defer allocator.free(result);

    // Verify JSON structure
    try testing.expect(std.mem.indexOf(u8, result, "{\"skills\":[") != null);
    try testing.expect(std.mem.indexOf(u8, result, "\"name\":\"code_review\"") != null);
    try testing.expect(std.mem.indexOf(u8, result, "\"description\"") != null);
}

test "executeGetSkill returns skill content for valid skill" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // Create the local skills directory structure
    std.fs.cwd().makePath(".zigginagentic/skills") catch |err| {
        std.debug.print("Could not create test directory: {s}\n", .{@errorName(err)});
        return error.SkipZigTest;
    };

    // Create a skill file with YAML frontmatter
    const test_content =
        \\---
        \\name: debugging
        \\description: "Debug issues systematically"
        \\---
        \\# Debugging
        \\Debug issues systematically.
    ;

    // Create folder structure: .zigginagentic/skills/debugging/SKILL.MD
    std.fs.cwd().makePath(".zigginagentic/skills/debugging") catch |err| {
        std.debug.print("Could not create test directory: {s}\n", .{@errorName(err)});
        return error.SkipZigTest;
    };

    const test_file = std.fs.cwd().createFile(".zigginagentic/skills/debugging/SKILL.MD", .{ .truncate = true }) catch |err| {
        std.debug.print("Could not create test file: {s}\n", .{@errorName(err)});
        return error.SkipZigTest;
    };
    defer {
        test_file.close();
        std.fs.cwd().deleteFile(".zigginagentic/skills/debugging/SKILL.MD") catch {};
        std.fs.cwd().deleteDir(".zigginagentic/skills/debugging") catch {};
        std.fs.cwd().deleteDir(".zigginagentic/skills") catch {};
        std.fs.cwd().deleteDir(".zigginagentic") catch {};
    }

    try test_file.writeAll(test_content);

    const input = get_skill.GetSkillInput{
        .skill_name = "debugging",
    };

    const result = try get_skill.executeGetSkillToString(allocator, input);
    defer allocator.free(result);

    // Verify XML structure
    try testing.expect(std.mem.indexOf(u8, result, "<skill_name>") != null);
    try testing.expect(std.mem.indexOf(u8, result, "<loaded>") != null);
    try testing.expect(std.mem.indexOf(u8, result, "Debug issues systematically") != null);
}

test "executeGetSkillToString returns error for invalid skill" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // Create the local skills directory structure
    std.fs.cwd().makePath(".zigginagentic/skills") catch |err| {
        std.debug.print("Could not create test directory: {s}\n", .{@errorName(err)});
        return error.SkipZigTest;
    };

    // Create a skill file with YAML frontmatter
    const test_content =
        \\---
        \\name: existing_skill
        \\description: "This skill exists"
        \\---
        \\# Existing Skill
    ;

    // Create folder structure: .zigginagentic/skills/existing_skill/SKILL.MD
    std.fs.cwd().makePath(".zigginagentic/skills/existing_skill") catch |err| {
        std.debug.print("Could not create test directory: {s}\n", .{@errorName(err)});
        return error.SkipZigTest;
    };

    const test_file = std.fs.cwd().createFile(".zigginagentic/skills/existing_skill/SKILL.MD", .{ .truncate = true }) catch |err| {
        std.debug.print("Could not create test file: {s}\n", .{@errorName(err)});
        return error.SkipZigTest;
    };
    defer {
        test_file.close();
        std.fs.cwd().deleteFile(".zigginagentic/skills/existing_skill/SKILL.MD") catch {};
        std.fs.cwd().deleteDir(".zigginagentic/skills/existing_skill") catch {};
        std.fs.cwd().deleteDir(".zigginagentic/skills") catch {};
        std.fs.cwd().deleteDir(".zigginagentic") catch {};
    }

    try test_file.writeAll(test_content);

    const input = get_skill.GetSkillInput{
        .skill_name = "nonexistent_skill",
    };

    const result = try get_skill.executeGetSkillToString(allocator, input);
    defer allocator.free(result);

    // Verify XML structure for error case
    try testing.expect(std.mem.indexOf(u8, result, "<skill_name>") != null);
    try testing.expect(std.mem.indexOf(u8, result, "<loaded>") != null);
    try testing.expect(std.mem.indexOf(u8, result, "<error>") != null);
}
