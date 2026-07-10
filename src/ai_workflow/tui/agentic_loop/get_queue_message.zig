const std = @import("std");
const mod = @import("mod.zig");
const sqlite = mod.nalarcore.sqlite;

pub const QueuedMessage = struct {
    message: []const u8,
    image_url: []const u8,
};

pub const GetQueueMessageInput = struct {
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    session_id: []const u8,
};

/// Returns null if no messages queued
/// Caller must free the returned slice
pub fn getQueueMessages(
    obj: GetQueueMessageInput,
) !?std.ArrayList(QueuedMessage) {
    const allocator = obj.allocator;
    const db = obj.db;
    const session_id = obj.session_id;

    const select_sql =
        \\SELECT
        \\    message,
        \\    image_url
        \\FROM session_queue_messages
        \\WHERE session_id = ?
        \\ORDER BY created_at ASC;
    ;
    var rows = try db.query(allocator, select_sql, &.{session_id});
    defer rows.deinit();

    var messages = std.ArrayList(QueuedMessage).empty;
    errdefer {
        for (messages.items) |msg| {
            allocator.free(msg.message);
            allocator.free(msg.image_url);
        }
        messages.deinit(allocator);
    }

    while (try rows.next()) |row| {
        const msg = try allocator.dupe(u8, row.values[0]);
        const image_url = try allocator.dupe(u8, row.values[1]);
        try messages.append(allocator, .{ .message = msg, .image_url = image_url });
    }

    if (messages.items.len == 0) {
        messages.deinit(allocator);
        return null;
    }

    return messages;
}
