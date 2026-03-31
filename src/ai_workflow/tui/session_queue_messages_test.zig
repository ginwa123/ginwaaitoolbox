const std = @import("std");
const session_queue_messages = @import("session_queue_messages.zig");
const sqlite = @import("nalarcore").sqlite;

test "SessionQueueMessage struct fields" {
    const allocator = std.testing.allocator;
    const msg = session_queue_messages.SessionQueueMessage{
        .id = try allocator.dupe(u8, "msg-1"),
        .session_id = try allocator.dupe(u8, "session-1"),
        .message = try allocator.dupe(u8, "Hello world"),
        .created_at = try allocator.dupe(u8, "2025-03-31 12:00:00"),
    };
    defer msg.deinit(allocator);

    try std.testing.expectEqualStrings("msg-1", msg.id);
    try std.testing.expectEqualStrings("session-1", msg.session_id);
    try std.testing.expectEqualStrings("Hello world", msg.message);
    try std.testing.expectEqualStrings("2025-03-31 12:00:00", msg.created_at);
}

test "create_queue_message" {
    const allocator = std.testing.allocator;
    var db: sqlite.SqliteBackend = sqlite.SqliteBackend{};
    try db.init(":memory:");
    defer db.deinit();

    try db.exec(allocator, 
        \\CREATE TABLE IF NOT EXISTS session_queue_messages (
        \\    id TEXT NOT NULL,
        \\    session_id TEXT NOT NULL,
        \\    message TEXT NOT NULL,
        \\    created_at DATETIME DEFAULT CURRENT_TIMESTAMP
        \\)
    , &.{});

    const msg = try session_queue_messages.create_queue_message(
        allocator, &db, "msg-1", "session-1", "Test message"
    );
    defer msg.deinit(allocator);

    try std.testing.expectEqualStrings("msg-1", msg.id);
    try std.testing.expectEqualStrings("session-1", msg.session_id);
    try std.testing.expectEqualStrings("Test message", msg.message);
    try std.testing.expect(msg.created_at.len > 0); // created_at auto-generated
}

test "get_queue_message" {
    const allocator = std.testing.allocator;
    var db: sqlite.SqliteBackend = sqlite.SqliteBackend{};
    try db.init(":memory:");
    defer db.deinit();

    try db.exec(allocator, 
        \\CREATE TABLE IF NOT EXISTS session_queue_messages (
        \\    id TEXT NOT NULL,
        \\    session_id TEXT NOT NULL,
        \\    message TEXT NOT NULL,
        \\    created_at DATETIME DEFAULT CURRENT_TIMESTAMP
        \\)
    , &.{});
    
    try db.exec(allocator, 
        "INSERT INTO session_queue_messages (id, session_id, message) VALUES (?, ?, ?)",
        &.{ "msg-1", "session-1", "Test message" }
    );

    const msg = try session_queue_messages.get_queue_message(allocator, &db, "msg-1");
    try std.testing.expect(msg != null);
    defer msg.?.deinit(allocator);

    try std.testing.expectEqualStrings("msg-1", msg.?.id);
    try std.testing.expectEqualStrings("session-1", msg.?.session_id);
    try std.testing.expectEqualStrings("Test message", msg.?.message);
}

test "get_messages_by_session" {
    const allocator = std.testing.allocator;
    var db: sqlite.SqliteBackend = sqlite.SqliteBackend{};
    try db.init(":memory:");
    defer db.deinit();

    try db.exec(allocator, 
        \\CREATE TABLE IF NOT EXISTS session_queue_messages (
        \\    id TEXT NOT NULL,
        \\    session_id TEXT NOT NULL,
        \\    message TEXT NOT NULL,
        \\    created_at DATETIME DEFAULT CURRENT_TIMESTAMP
        \\)
    , &.{});
    
    try db.exec(allocator, 
        "INSERT INTO session_queue_messages (id, session_id, message) VALUES (?, ?, ?)",
        &.{ "msg-1", "session-1", "Message 1" }
    );
    try db.exec(allocator, 
        "INSERT INTO session_queue_messages (id, session_id, message) VALUES (?, ?, ?)",
        &.{ "msg-2", "session-1", "Message 2" }
    );
    try db.exec(allocator, 
        "INSERT INTO session_queue_messages (id, session_id, message) VALUES (?, ?, ?)",
        &.{ "msg-3", "session-2", "Message 3" }
    );

    const messages = try session_queue_messages.get_messages_by_session(allocator, &db, "session-1");
    defer {
        for (messages) |m| m.deinit(allocator);
        allocator.free(messages);
    }

    try std.testing.expectEqual(@as(usize, 2), messages.len);
    try std.testing.expectEqualStrings("msg-1", messages[0].id);
    try std.testing.expectEqualStrings("msg-2", messages[1].id);
}

test "delete_queue_message" {
    const allocator = std.testing.allocator;
    var db: sqlite.SqliteBackend = sqlite.SqliteBackend{};
    try db.init(":memory:");
    defer db.deinit();

    try db.exec(allocator, 
        \\CREATE TABLE IF NOT EXISTS session_queue_messages (
        \\    id TEXT NOT NULL,
        \\    session_id TEXT NOT NULL,
        \\    message TEXT NOT NULL,
        \\    created_at DATETIME DEFAULT CURRENT_TIMESTAMP
        \\)
    , &.{});
    
    try db.exec(allocator, 
        "INSERT INTO session_queue_messages (id, session_id, message) VALUES (?, ?, ?)",
        &.{ "msg-1", "session-1", "Test message" }
    );

    try session_queue_messages.delete_queue_message(allocator, &db, "msg-1");

    const msg = try session_queue_messages.get_queue_message(allocator, &db, "msg-1");
    try std.testing.expect(msg == null);
}
