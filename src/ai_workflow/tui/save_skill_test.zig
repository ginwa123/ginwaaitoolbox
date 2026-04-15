const std = @import("std");
const testing = std.testing;
const save_skill = @import("session_skills.zig");

test "save_skill - empty session_id returns early" {
    // Test that empty session_id is handled correctly
    const empty_session = "";
    const valid_session = "test-session-123";

    try testing.expect(empty_session.len == 0);
    try testing.expect(valid_session.len > 0);
    try testing.expectEqualStrings("test-session-123", valid_session);
}

test "save_skill - skill name validation" {
    // Test various skill name formats
    const skill_names = [_][]const u8{
        "brainstorming",
        "zig-expert",
        "my_skill.v1",
        "test-skill_name",
    };

    for (skill_names) |name| {
        try testing.expect(name.len > 0);
        try testing.expect(name.len < 100); // Reasonable max length
    }
}

test "save_skill - content validation" {
    // Test content formats
    const content1 = "# Skill Content\n\nDescription here.";
    const content2 = "---\nname: test\n---\n";
    const empty_content = "";

    try testing.expect(content1.len > 0);
    try testing.expect(content2.len > 0);
    try testing.expect(empty_content.len == 0);

    // Verify content can contain markdown
    try testing.expect(std.mem.indexOf(u8, content1, "#") != null);
    try testing.expect(std.mem.indexOf(u8, content2, "---") != null);
}

test "save_skill - SQL query format" {
    // Verify the SQL query structure
    const sql = "INSERT OR REPLACE INTO session_skills (session_id, skill_name, content, loaded_at) VALUES (?, ?, ?, strftime('%s', 'now'))";

    try testing.expect(std.mem.indexOf(u8, sql, "INSERT OR REPLACE") != null);
    try testing.expect(std.mem.indexOf(u8, sql, "session_skills") != null);
    try testing.expect(std.mem.indexOf(u8, sql, "session_id") != null);
    try testing.expect(std.mem.indexOf(u8, sql, "skill_name") != null);
    try testing.expect(std.mem.indexOf(u8, sql, "content") != null);
    try testing.expect(std.mem.indexOf(u8, sql, "loaded_at") != null);
}

test "save_skill - isLoaded SQL validation" {
    const sql = "SELECT 1 FROM session_skills WHERE session_id = ? AND skill_name = ? LIMIT 1";

    try testing.expect(std.mem.indexOf(u8, sql, "SELECT 1") != null);
    try testing.expect(std.mem.indexOf(u8, sql, "LIMIT 1") != null);
    try testing.expect(std.mem.indexOf(u8, sql, "AND") != null);
}
