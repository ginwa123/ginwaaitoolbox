const std = @import("std");
const session_table = @import("session_table.zig");
const sqlite = @import("nalarcore").sqlite;

test "SessionInfo struct fields" {
    const allocator = std.testing.allocator;
    const session = session_table.SessionInfo{
        .id = try allocator.dupe(u8, "test-id"),
        .name = try allocator.dupe(u8, "test-name"),
        .status = try allocator.dupe(u8, "active"),
    };
    defer session.deinit(allocator);

    try std.testing.expectEqualStrings("test-id", session.id);
    try std.testing.expectEqualStrings("test-name", session.name);
    try std.testing.expectEqualStrings("active", session.status);
}

test "create_session" {
    const allocator = std.testing.allocator;
    var db: sqlite.SqliteBackend = sqlite.SqliteBackend{};
    try db.init(":memory:");
    defer db.deinit();

    try db.exec(allocator, "CREATE TABLE sessions (id TEXT, name TEXT, status TEXT)", &.{});

    const session = try session_table.create_session(allocator, &db, "session-1", "My Session");
    defer session.deinit(allocator);

    try std.testing.expectEqualStrings("session-1", session.id);
    try std.testing.expectEqualStrings("My Session", session.name);
    try std.testing.expectEqualStrings("active", session.status);
}

test "get_session" {
    const allocator = std.testing.allocator;
    var db: sqlite.SqliteBackend = sqlite.SqliteBackend{};
    try db.init(":memory:");
    defer db.deinit();

    try db.exec(allocator, "CREATE TABLE sessions (id TEXT, name TEXT, status TEXT)", &.{});
    try db.exec(allocator, "INSERT INTO sessions (id, name, status) VALUES ('session-1', 'My Session', 'active')", &.{});

    const session = try session_table.getSession(allocator, &db, "session-1");
    try std.testing.expect(session != null);
    defer session.?.deinit(allocator);

    try std.testing.expectEqualStrings("session-1", session.?.id);
    try std.testing.expectEqualStrings("My Session", session.?.name);
    try std.testing.expectEqualStrings("active", session.?.status);
}

test "update_session_status" {
    const allocator = std.testing.allocator;
    var db: sqlite.SqliteBackend = sqlite.SqliteBackend{};
    try db.init(":memory:");
    defer db.deinit();

    try db.exec(allocator, "CREATE TABLE sessions (id TEXT, name TEXT, status TEXT)", &.{});
    try db.exec(allocator, "INSERT INTO sessions (id, name, status) VALUES ('session-1', 'My Session', 'active')", &.{});

    try session_table.update_session_status(allocator, &db, "session-1", "inactive");

    const session = try session_table.getSession(allocator, &db, "session-1");
    try std.testing.expect(session != null);
    defer session.?.deinit(allocator);

    try std.testing.expectEqualStrings("inactive", session.?.status);
}

test "delete_session" {
    const allocator = std.testing.allocator;
    var db: sqlite.SqliteBackend = sqlite.SqliteBackend{};
    try db.init(":memory:");
    defer db.deinit();

    try db.exec(allocator, "CREATE TABLE sessions (id TEXT, name TEXT, status TEXT)", &.{});
    try db.exec(allocator, "INSERT INTO sessions (id, name, status) VALUES ('session-1', 'My Session', 'active')", &.{});

    try session_table.delete_session(allocator, &db, "session-1");

    const session = try session_table.getSession(allocator, &db, "session-1");
    try std.testing.expect(session == null);
}

test "list_sessions" {
    const allocator = std.testing.allocator;
    var db: sqlite.SqliteBackend = sqlite.SqliteBackend{};
    try db.init(":memory:");
    defer db.deinit();

    try db.exec(allocator, "CREATE TABLE sessions (id TEXT, name TEXT, status TEXT)", &.{});
    try db.exec(allocator, "INSERT INTO sessions (id, name, status) VALUES ('session-1', 'Session One', 'active')", &.{});
    try db.exec(allocator, "INSERT INTO sessions (id, name, status) VALUES ('session-2', 'Session Two', 'inactive')", &.{});

    const sessions = try session_table.list_sessions(allocator, &db);
    defer {
        for (sessions) |s| s.deinit(allocator);
        allocator.free(sessions);
    }

    try std.testing.expectEqual(@as(usize, 2), sessions.len);
    try std.testing.expectEqualStrings("session-1", sessions[0].id);
    try std.testing.expectEqualStrings("session-2", sessions[1].id);
}

test "get_session returns null for non-existent id" {
    const allocator = std.testing.allocator;
    var db: sqlite.SqliteBackend = sqlite.SqliteBackend{};
    try db.init(":memory:");
    defer db.deinit();

    try db.exec(allocator, "CREATE TABLE sessions (id TEXT, name TEXT, status TEXT)", &.{});

    const session = try session_table.getSession(allocator, &db, "non-existent");
    try std.testing.expect(session == null);
}
