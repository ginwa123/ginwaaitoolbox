const std = @import("std");
const testing = std.testing;
const llm_history = @import("llm_history.zig");
const sqlite = @import("nalarcore").sqlite;

fn setupDb() !struct {
    db: sqlite.SqliteBackend,
    threaded: std.Io.Threaded,
} {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    errdefer threaded.deinit();
    const io = threaded.io();
    var db: sqlite.SqliteBackend = .{};
    errdefer db.deinit();
    try db.init(io, ":memory:");

    try db.exec(alloc,
        \\CREATE TABLE llm_history (
        \\  id TEXT PRIMARY KEY,
        \\  session_id TEXT NOT NULL,
        \\  model TEXT,
        \\  response_content TEXT,
        \\  role TEXT,
        \\  tool_call_id TEXT,
        \\  tool_name TEXT,
        \\  is_feed_to_llm INTEGER DEFAULT 1,
        \\  agent TEXT,
        \\  created_at TEXT DEFAULT (datetime('now'))
        \\)
    , &.{});
    return .{ .db = db, .threaded = threaded };
}

fn teardownDb(s: *@TypeOf(setupDb() catch unreachable)) void {
    s.db.deinit();
    s.threaded.deinit();
}

fn seedMessage(alloc: std.mem.Allocator, db: *sqlite.SqliteBackend, id: []const u8, sess: []const u8, role: []const u8, content: []const u8, is_feed: u8, created_at: []const u8) !void {
    const feed_str = if (is_feed == 1) "1" else "0";
    const sql =
        \\INSERT INTO llm_history (id, session_id, role, response_content, is_feed_to_llm, created_at)
        \\VALUES (?, ?, ?, ?, ?, ?)
    ;
    try db.exec(alloc, sql, &.{ id, sess, role, content, feed_str, created_at });
}

test "getCompactedMessages: returns only is_feed_to_llm=0 messages for session" {
    var s = try setupDb();
    defer teardownDb(&s);
    const alloc = testing.allocator;

    try seedMessage(alloc, &s.db, "h1", "sess_1", "user", "Fix bug", 1, "2025-01-01 00:00:00");
    try seedMessage(alloc, &s.db, "h2", "sess_1", "assistant", "OK", 1, "2025-01-01 00:01:00");
    try seedMessage(alloc, &s.db, "h3", "sess_1", "user", "More", 0, "2025-01-01 00:02:00");
    try seedMessage(alloc, &s.db, "h4", "sess_1", "assistant", "Done", 0, "2025-01-01 00:03:00");
    try seedMessage(alloc, &s.db, "h5", "sess_2", "user", "other session", 0, "2025-01-01 00:04:00");

    const results = try llm_history.getCompactedMessages(alloc, &s.db, "sess_1", .{});
    defer {
        for (results) |m| {
            var copy = m;
            copy.deinit(alloc);
        }
        alloc.free(results);
    }

    try testing.expectEqual(@as(usize, 2), results.len);
    try testing.expectEqualStrings("h3", results[0].id);
    try testing.expectEqualStrings("h4", results[1].id);
}

test "getCompactedMessages: respects limit" {
    var s = try setupDb();
    defer teardownDb(&s);
    const alloc = testing.allocator;
    var i: usize = 0;
    while (i < 30) : (i += 1) {
        var buf: [16]u8 = undefined;
        const id = try std.fmt.bufPrint(&buf, "h{d}", .{i});
        try seedMessage(alloc, &s.db, id, "sess_1", "user", "msg", 0, "2025-01-01 00:00:00");
    }
    const results = try llm_history.getCompactedMessages(alloc, &s.db, "sess_1", .{ .limit = 5 });
    defer {
        for (results) |m| {
            var copy = m;
            copy.deinit(alloc);
        }
        alloc.free(results);
    }
    try testing.expectEqual(@as(usize, 5), results.len);
}

test "getCompactedMessages: filters by message_ids when provided" {
    var s = try setupDb();
    defer teardownDb(&s);
    const alloc = testing.allocator;
    try seedMessage(alloc, &s.db, "h1", "sess_1", "user", "A", 0, "2025-01-01 00:00:00");
    try seedMessage(alloc, &s.db, "h2", "sess_1", "user", "B", 0, "2025-01-01 00:01:00");
    try seedMessage(alloc, &s.db, "h3", "sess_1", "user", "C", 0, "2025-01-01 00:02:00");

    const ids = [_][]const u8{ "h1", "h3" };
    const results = try llm_history.getCompactedMessages(alloc, &s.db, "sess_1", .{ .message_ids = &ids });
    defer {
        for (results) |m| {
            var copy = m;
            copy.deinit(alloc);
        }
        alloc.free(results);
    }
    try testing.expectEqual(@as(usize, 2), results.len);
    try testing.expectEqualStrings("h1", results[0].id);
    try testing.expectEqualStrings("h3", results[1].id);
}

test "getCompactedMessages: returns empty slice when session has no compacted messages" {
    var s = try setupDb();
    defer teardownDb(&s);
    const alloc = testing.allocator;
    try seedMessage(alloc, &s.db, "h1", "sess_1", "user", "active", 1, "2025-01-01 00:00:00");

    const results = try llm_history.getCompactedMessages(alloc, &s.db, "sess_1", .{});
    defer {
        for (results) |m| {
            var copy = m;
            copy.deinit(alloc);
        }
        alloc.free(results);
    }
    try testing.expectEqual(@as(usize, 0), results.len);
}