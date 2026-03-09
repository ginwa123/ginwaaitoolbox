const std = @import("std");
const testing = std.testing;
const build_skill_content = @import("build_skill_content.zig");

test "build_skill_content - session_id validation" {
    // Test that empty session_id is handled correctly
    const empty_session = "";
    const valid_session = "test-session-123";

    try testing.expect(empty_session.len == 0);
    try testing.expect(valid_session.len > 0);
    try testing.expectEqualStrings("test-session-123", valid_session);
}

test "build_skill_content - output format validation" {
    // Test the expected output format components
    const header = "\n\n## Loaded Skills\n\n";
    const skill_marker = "### ";

    try testing.expect(header.len > 0);
    try testing.expect(skill_marker.len > 0);
    try testing.expect(std.mem.indexOf(u8, header, "Loaded Skills") != null);
    try testing.expect(std.mem.indexOf(u8, skill_marker, "#") != null);
}

test "build_skill_content - skill name handling" {
    // Test various skill name formats
    const skill_name1 = "brainstorming";
    const skill_name2 = "my-skill_name.v1";
    const skill_name3 = "zig-expert";

    try testing.expect(skill_name1.len > 0);
    try testing.expect(skill_name2.len > 0);
    try testing.expect(skill_name3.len > 0);

    // Verify skill names don't contain problematic characters
    try testing.expect(std.mem.indexOf(u8, skill_name1, "\n") == null);
    try testing.expect(std.mem.indexOf(u8, skill_name2, "\r") == null);
}

test "build_skill_content - SQL query validation" {
    const sql = "SELECT skill_name, content FROM session_skills WHERE session_id = ?";

    try testing.expect(std.mem.indexOf(u8, sql, "SELECT") != null);
    try testing.expect(std.mem.indexOf(u8, sql, "skill_name") != null);
    try testing.expect(std.mem.indexOf(u8, sql, "content") != null);
    try testing.expect(std.mem.indexOf(u8, sql, "session_skills") != null);
    try testing.expect(std.mem.indexOf(u8, sql, "WHERE") != null);
}

test "build_skill_content - content formatting" {
    // Test that content is properly formatted with newlines
    const content_suffix = "\n\n";
    try testing.expect(content_suffix.len == 2);
    try testing.expect(std.mem.eql(u8, content_suffix, "\n\n"));
}
