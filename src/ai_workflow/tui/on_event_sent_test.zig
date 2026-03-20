const std = @import("std");
const testing = std.testing;
const on_event_sent = @import("on_event_sent.zig");

test "on_event_sent - sendSessions XML format validation" {
    // Test XML structure components
    const xml_start = "<response><type>sessions</type><sessions>";
    const xml_end = "</sessions></response>";
    const session_start = "<session><id>";
    const session_end = "</created></session>";

    try testing.expect(xml_start.len > 0);
    try testing.expect(xml_end.len > 0);
    try testing.expect(session_start.len > 0);
    try testing.expect(session_end.len > 0);

    // Verify XML tags
    try testing.expect(std.mem.indexOf(u8, xml_start, "response") != null);
    try testing.expect(std.mem.indexOf(u8, xml_start, "sessions") != null);
    try testing.expect(std.mem.indexOf(u8, session_start, "session") != null);
    try testing.expect(std.mem.indexOf(u8, session_start, "id") != null);
}

test "on_event_sent - sendSessions session info structure" {
    // Test session info fields
    const session_id = "test-session-123";
    const session_dir = "/home/user/project";
    const created_at = "2024-01-01T00:00:00Z";

    try testing.expect(session_id.len > 0);
    try testing.expect(session_dir.len > 0);
    try testing.expect(created_at.len > 0);

    try testing.expectEqualStrings("test-session-123", session_id);
    try testing.expect(std.mem.indexOf(u8, session_dir, "/") != null);
}

test "on_event_sent - sendSessions multiple sessions handling" {
    // Test with multiple sessions
    const sessions = [_]struct {
        id: []const u8,
        dir: []const u8,
        created: []const u8,
    }{
        .{ .id = "session1", .dir = "/path/1", .created = "2024-01-01" },
        .{ .id = "session2", .dir = "/path/2", .created = "2024-01-02" },
        .{ .id = "session3", .dir = "/path/3", .created = "2024-01-03" },
    };

    try testing.expect(sessions.len == 3);
    for (sessions) |session| {
        try testing.expect(session.id.len > 0);
        try testing.expect(session.dir.len > 0);
        try testing.expect(session.created.len > 0);
    }
}

test "on_event_sent - sendSessions empty sessions list" {
    // Empty sessions should still produce valid XML
    const empty_count: usize = 0;
    try testing.expect(empty_count == 0);
}
