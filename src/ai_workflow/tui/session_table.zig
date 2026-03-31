const std = @import("std");
const sqlite = @import("nalarcore").sqlite;

/// Session info for CRUD operations
pub const SessionInfo = struct {
    id: []u8,
    name: []u8,
    status: []u8,

    pub fn deinit(self: SessionInfo, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.name);
        allocator.free(self.status);
    }
};

/// Create a new session with status set to 'active'
pub fn create_session(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    id: []const u8,
    name: []const u8,
) !SessionInfo {
    const sql = "INSERT INTO sessions (id, name, status) VALUES (?, ?, 'active')";
    try db.exec(allocator, sql, &.{ id, name });

    return SessionInfo{
        .id = try allocator.dupe(u8, id),
        .name = try allocator.dupe(u8, name),
        .status = try allocator.dupe(u8, "active"),
    };
}

/// Get a session by id
pub fn get_session(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    id: []const u8,
) !?SessionInfo {
    const sql = "SELECT id, name, status FROM sessions WHERE id = ?";

    var rows = try db.query(allocator, sql, &.{id});
    defer rows.deinit();

    if (try rows.next()) |row| {
        const session = SessionInfo{
            .id = try allocator.dupe(u8, row.values[0]),
            .name = try allocator.dupe(u8, row.values[1]),
            .status = try allocator.dupe(u8, row.values[2]),
        };
        row.deinit(allocator);
        return session;
    }

    return null;
}

/// Update session status
pub fn update_session_status(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    id: []const u8,
    new_status: []const u8,
) !void {
    const sql = "UPDATE sessions SET status = ? WHERE id = ?";
    try db.exec(allocator, sql, &.{ new_status, id });
}

/// Delete a session by id
pub fn delete_session(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    id: []const u8,
) !void {
    const sql = "DELETE FROM sessions WHERE id = ?";
    try db.exec(allocator, sql, &.{id});
}

/// List all sessions
pub fn list_sessions(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
) ![]SessionInfo {
    const sql = "SELECT id, name, status FROM sessions ORDER BY id";

    var rows = try db.query(allocator, sql, &.{});
    defer rows.deinit();

    var sessions = std.ArrayList(SessionInfo).empty;
    errdefer {
        for (sessions.items) |s| s.deinit(allocator);
        sessions.deinit(allocator);
    }

    while (try rows.next()) |row| {
        const session = SessionInfo{
            .id = try allocator.dupe(u8, row.values[0]),
            .name = try allocator.dupe(u8, row.values[1]),
            .status = try allocator.dupe(u8, row.values[2]),
        };
        try sessions.append(allocator, session);
        row.deinit(allocator);
    }

    return try sessions.toOwnedSlice(allocator);
}

test "SessionInfo struct fields" {
    const allocator = std.testing.allocator;
    const session = SessionInfo{
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

    const session = try create_session(allocator, &db, "session-1", "My Session");
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

    const session = try get_session(allocator, &db, "session-1");
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

    try update_session_status(allocator, &db, "session-1", "inactive");

    const session = try get_session(allocator, &db, "session-1");
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

    try delete_session(allocator, &db, "session-1");

    const session = try get_session(allocator, &db, "session-1");
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

    const sessions = try list_sessions(allocator, &db);
    defer {
        for (sessions) |s| s.deinit(allocator);
        allocator.free(sessions);
    }

    try std.testing.expectEqual(@as(usize, 2), sessions.len);
    try std.testing.expectEqualStrings("session-1", sessions[0].id);
    try std.testing.expectEqualStrings("session-2", sessions[1].id);
}

test "get_session error for non-existent id" {
    const allocator = std.testing.allocator;
    var db: sqlite.SqliteBackend = sqlite.SqliteBackend{};
    try db.init(":memory:");
    defer db.deinit();

    try db.exec(allocator, "CREATE TABLE sessions (id TEXT, name TEXT, status TEXT)", &.{});

    const session = try get_session(allocator, &db, "non-existent");
    try std.testing.expect(session == null);
}
