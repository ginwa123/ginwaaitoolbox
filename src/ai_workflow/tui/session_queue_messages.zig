const std = @import("std");
const sqlite = @import("nalarcore").sqlite;

pub const SessionQueueMessage = struct {
    id: []u8,
    session_id: []u8,
    message: []u8,
    created_at: []u8,

    pub fn deinit(self: SessionQueueMessage, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.session_id);
        allocator.free(self.message);
        allocator.free(self.created_at);
    }
};

/// Create a new queue message
pub fn create_queue_message(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    id: []const u8,
    session_id: []const u8,
    message: []const u8,
) !SessionQueueMessage {
    const sql = "INSERT INTO session_queue_messages (id, session_id, message) VALUES (?, ?, ?)";
    try db.exec(allocator, sql, &.{ id, session_id, message });

    // Fetch the created_at that was auto-generated
    const get_sql = "SELECT created_at FROM session_queue_messages WHERE id = ?";
    var rows = try db.query(allocator, get_sql, &.{id});
    defer rows.deinit();

    const row = try rows.next();
    const created_at_str = if (row) |r| r.values[0] else "";

    const created_at = try allocator.dupe(u8, created_at_str);
    errdefer allocator.free(created_at);

    const dup_id = try allocator.dupe(u8, id);
    errdefer allocator.free(dup_id);

    const dup_session_id = try allocator.dupe(u8, session_id);
    errdefer allocator.free(dup_session_id);

    const dup_message = try allocator.dupe(u8, message);
    errdefer allocator.free(dup_message);

    if (row) |r| r.deinit(allocator);

    return SessionQueueMessage{
        .id = dup_id,
        .session_id = dup_session_id,
        .message = dup_message,
        .created_at = created_at,
    };
}

/// Get a queue message by id
pub fn get_queue_message(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    id: []const u8,
) !?SessionQueueMessage {
    const sql = "SELECT id, session_id, message, created_at FROM session_queue_messages WHERE id = ?";

    var rows = try db.query(allocator, sql, &.{id});
    defer rows.deinit();

    if (try rows.next()) |row| {
        const msg = SessionQueueMessage{
            .id = try allocator.dupe(u8, row.values[0]),
            .session_id = try allocator.dupe(u8, row.values[1]),
            .message = try allocator.dupe(u8, row.values[2]),
            .created_at = try allocator.dupe(u8, row.values[3]),
        };
        row.deinit(allocator);
        return msg;
    }

    return null;
}

/// Get all queue messages for a session
pub fn get_messages_by_session(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    session_id: []const u8,
) ![]SessionQueueMessage {
    const sql = "SELECT id, session_id, message, created_at FROM session_queue_messages WHERE session_id = ? ORDER BY id";

    var rows = try db.query(allocator, sql, &.{session_id});
    defer rows.deinit();

    var messages = std.ArrayList(SessionQueueMessage).empty;
    errdefer {
        for (messages.items) |m| m.deinit(allocator);
        messages.deinit(allocator);
    }

    while (try rows.next()) |row| {
        const msg = SessionQueueMessage{
            .id = try allocator.dupe(u8, row.values[0]),
            .session_id = try allocator.dupe(u8, row.values[1]),
            .message = try allocator.dupe(u8, row.values[2]),
            .created_at = try allocator.dupe(u8, row.values[3]),
        };
        try messages.append(allocator, msg);
        row.deinit(allocator);
    }

    return try messages.toOwnedSlice(allocator);
}

/// Delete a queue message by id
pub fn delete_queue_message(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    id: []const u8,
) !void {
    const sql = "DELETE FROM session_queue_messages WHERE id = ?";
    try db.exec(allocator, sql, &.{id});
}

