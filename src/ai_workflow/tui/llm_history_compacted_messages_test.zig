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
        \\  created_at TEXT DEFAULT (datetime('now')),
        \\  -- Mirrors Migration 059 in production: a regular TEXT column
        \\  -- populated by INSERT/UPDATE triggers. We CAN'T use a STORED
        \\  -- GENERATED ALWAYS AS column here because `datetime(...,
        \\  -- 'localtime')` is non-deterministic (depends on the system
        \\  -- timezone) — SQLite silently DROPS such columns from CREATE
        \\  -- TABLE / ALTER TABLE ADD COLUMN. Production uses triggers for
        \\  -- the same reason. The since/until filters on
        \\  -- getCompactedMessages bind to this column, so the test
        \\  -- schema must include it AND populate it.
        \\  created_iso TEXT
        \\)
    , &.{});
    // Trigger: mirror Migration 059's trigger that populates created_iso
    // from created_at on INSERT. CAST(... AS REAL) / 1000000 keeps the
    // microsecond Unix timestamp in the valid datetime() range.
    try db.exec(alloc,
        \\CREATE TRIGGER trg_iso_ins
        \\AFTER INSERT ON llm_history
        \\FOR EACH ROW
        \\WHEN NEW.created_at IS NOT NULL AND NEW.created_at != ''
        \\BEGIN
        \\    UPDATE llm_history
        \\    SET created_iso = datetime(
        \\        CAST(NEW.created_at AS REAL) / 1000000,
        \\        'unixepoch', 'localtime'
        \\    )
        \\    WHERE rowid = NEW.rowid;
        \\END
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

// ────────────────────────────────────────────────────────────────────────
// Regression tests for the since/until bug
// (docs/superpowers/plans/2026-07-15-search-history-since-until-bug.md).
//
// The bug: `created_at` stores Unix microseconds as TEXT (e.g.
// `"1784119389936251112"`). The previous SQL did a lex comparison on
// this column against user input like `"2026-07-15 00:00:00"`, which
// silently returned 0 rows because `'1' < '2'` (so `'1784…' < '2026-…'`
// always evaluated true, excluding every row).
//
// The fix: filter on `created_iso`, a STORED generated column produced
// by `datetime(created_at / 1000000, 'unixepoch', 'localtime')` at
// write time. These tests verify both halves of the fix:
//   1. ISO date strings actually filter rows (no longer silently 0).
//   2. Lex-correct ordering of the generated column preserves
//      chronological filter semantics.
// ────────────────────────────────────────────────────────────────────────

test "getCompactedMessages: filters by since using ISO date string (regression)" {
    var s = try setupDb();
    defer teardownDb(&s);
    const alloc = testing.allocator;

    // Two compacted messages at known microsecond timestamps. They
    // compare against `is_feed_to_llm=0` so they pass the default filter.
    const old_micros: []const u8 = "1780000000000000";
    const new_micros: []const u8 = "1785000000000000";
    try seedMessage(alloc, &s.db, "h_old", "sess_1", "user", "old", 0, old_micros);
    try seedMessage(alloc, &s.db, "h_new", "sess_1", "user", "new", 0, new_micros);

    // Compute the ISO for `new_micros` using the SAME expression the
    // migration uses — that's what `created_iso` will contain.
    var iso_q = try s.db.queryRow(alloc,
        "SELECT datetime(? / 1000000, 'unixepoch', 'localtime')",
        &.{new_micros});
    defer iso_q.deinit(alloc);
    const new_iso = iso_q.values[0];

    const results = try llm_history.getCompactedMessages(alloc, &s.db, "sess_1", .{
        .since = new_iso,
    });
    defer {
        for (results) |m| {
            var copy = m;
            copy.deinit(alloc);
        }
        alloc.free(results);
    }
    try testing.expectEqual(@as(usize, 1), results.len);
    try testing.expectEqualStrings("h_new", results[0].id);
    try testing.expectEqual(@as(u32, 1), results[0].total_count);
}

test "getCompactedMessages: filters by until using ISO date string (regression)" {
    var s = try setupDb();
    defer teardownDb(&s);
    const alloc = testing.allocator;

    const old_micros: []const u8 = "1780000000000000";
    const new_micros: []const u8 = "1785000000000000";
    try seedMessage(alloc, &s.db, "h_old", "sess_1", "user", "old", 0, old_micros);
    try seedMessage(alloc, &s.db, "h_new", "sess_1", "user", "new", 0, new_micros);

    var iso_q = try s.db.queryRow(alloc,
        "SELECT datetime(? / 1000000, 'unixepoch', 'localtime')",
        &.{old_micros});
    defer iso_q.deinit(alloc);
    const old_iso = iso_q.values[0];

    const results = try llm_history.getCompactedMessages(alloc, &s.db, "sess_1", .{
        .until = old_iso,
    });
    defer {
        for (results) |m| {
            var copy = m;
            copy.deinit(alloc);
        }
        alloc.free(results);
    }
    try testing.expectEqual(@as(usize, 1), results.len);
    try testing.expectEqualStrings("h_old", results[0].id);
}

test "getCompactedMessages: since AND until together produce a date range (regression)" {
    var s = try setupDb();
    defer teardownDb(&s);
    const alloc = testing.allocator;

    const old_micros: []const u8 = "1780000000000000";
    const mid_micros: []const u8 = "1783000000000000";
    const new_micros: []const u8 = "1785000000000000";
    try seedMessage(alloc, &s.db, "h_old", "sess_1", "user", "old", 0, old_micros);
    try seedMessage(alloc, &s.db, "h_mid", "sess_1", "user", "mid", 0, mid_micros);
    try seedMessage(alloc, &s.db, "h_new", "sess_1", "user", "new", 0, new_micros);

    var iso_q = try s.db.queryRow(alloc,
        \\SELECT datetime(? / 1000000, 'unixepoch', 'localtime') AS since_iso,
        \\       datetime(? / 1000000, 'unixepoch', 'localtime') AS until_iso
    , &.{ mid_micros, new_micros });
    defer iso_q.deinit(alloc);
    const since_iso = iso_q.values[0];
    const until_iso = iso_q.values[1];

    const results = try llm_history.getCompactedMessages(alloc, &s.db, "sess_1", .{
        .since = since_iso,
        .until = until_iso,
    });
    defer {
        for (results) |m| {
            var copy = m;
            copy.deinit(alloc);
        }
        alloc.free(results);
    }
    // Expect 2: h_mid + h_new (inclusive window). h_old should be excluded.
    try testing.expectEqual(@as(usize, 2), results.len);
    var found_old = false;
    for (results) |m| {
        if (std.mem.eql(u8, m.id, "h_old")) found_old = true;
    }
    try testing.expect(!found_old);
}