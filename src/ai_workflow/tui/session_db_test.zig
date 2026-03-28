const std = @import("std");
const session_db = @import("session_db.zig");
const SessionInfo = session_db.SessionInfo;

test "buildSessionListJson with multiple sessions" {
    const sessions = &[_]SessionInfo{
        .{
            .session_id = "abc123",
            .session_dir = "/tmp/sessions/abc123",
            .created_at = "2024-01-15T10:30:00",
            .agent = "Agent",
            .session_name = "Test Session",
        },
        .{
            .session_id = "def456",
            .session_dir = "/tmp/sessions/def456",
            .created_at = "2024-01-15T11:00:00",
            .agent = "CodeAgent",
            .session_name = "Another Session",
        },
    };

    const result = try session_db.buildSessionListJson(std.testing.allocator, sessions, 42);
    defer std.testing.allocator.free(result);

    // Verify JSON structure
    try std.testing.expect(std.mem.indexOf(u8, result, "\"sessions\":[") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"total\":42") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"sessionId\":\"abc123\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"sessionId\":\"def456\"") != null);
}

test "buildSessionListJson with empty sessions" {
    const sessions: []const SessionInfo = &.{};

    const result = try session_db.buildSessionListJson(std.testing.allocator, sessions, 0);
    defer std.testing.allocator.free(result);

    try std.testing.expectEqualSlices(u8, "{\"sessions\":[],\"total\":0}", result);
}

test "buildSessionListJson with single session" {
    const sessions = &[_]SessionInfo{
        .{
            .session_id = "single123",
            .session_dir = "/tmp/session",
            .created_at = "2024-01-01",
            .agent = "TestAgent",
            .session_name = "Only One",
        },
    };

    const result = try session_db.buildSessionListJson(std.testing.allocator, sessions, 1);
    defer std.testing.allocator.free(result);

    try std.testing.expect(std.mem.indexOf(u8, result, "{\"sessions\":[") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "],\"total\":1}") != null);
}
