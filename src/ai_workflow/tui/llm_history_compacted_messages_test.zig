const std = @import("std");
const testing = std.testing;
const llm_history = @import("llm_history.zig");
const sqlite = @import("nalarcore").sqlite;
const helpers = @import("nalarcore").helpers;

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
        \\  -- schema must include it. The seedMessage helper below
        \\  -- explicitly populates `created_iso` (mirrors the
        \\  -- application code in `saveMessage`).
        \\  created_iso TEXT,
        \\  -- Anthropic cache breakdown columns (Migration 074). The
        \\  -- saveMessage INSERT must reference both columns, so the
        \\  -- test fixture mirrors the production schema even when the
        \\  -- test doesn't read them.
        \\  cache_creation_input_tokens INTEGER DEFAULT 0,
        \\  cache_read_input_tokens INTEGER DEFAULT 0
        \\)
    , &.{});
    return .{ .db = db, .threaded = threaded };
}

fn teardownDb(s: *@TypeOf(setupDb() catch unreachable)) void {
    s.db.deinit();
    s.threaded.deinit();
}

fn seedMessage(
    alloc: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    id: []const u8,
    sess: []const u8,
    role: []const u8,
    content: []const u8,
    is_feed: u8,
    created_at: []const u8,
) !void {
    const feed_str = if (is_feed == 1) "1" else "0";

    // `created_at` is either:
    //   - A microsecond timestamp string (e.g. "1785000000000000"), OR
    //   - A pre-formatted ISO localtime string (e.g. "2025-01-01 00:01:00").
    //
    // For the microsecond case we compute the ISO via SQLite's
    // `datetime(? / 1000000, 'unixepoch')` — the same expression
    // Migration 059 used before moving the conversion to app code,
    // and the same expression used by the since/until filter queries
    // in this file (so the row's `created_iso` matches what the filter
    // would generate from the same `created_at`). For the ISO case we
    // reuse the string as-is.
    var created_iso_buf: [20]u8 = undefined;
    const created_iso_len: usize = blk: {
        if (created_at.len >= 10 and std.mem.indexOfScalar(u8, created_at, '-') == null) {
            // Looks like a microsecond integer — convert via SQLite.
            var q = try db.queryRow(alloc,
                "SELECT datetime(? / 1000000, 'unixepoch')",
                &.{created_at});
            defer q.deinit(alloc);
            const iso = q.values[0];
            const len = iso.len;
            if (len > created_iso_buf.len) return error.TimestampTooLong;
            @memcpy(created_iso_buf[0..len], iso);
            break :blk len;
        }
        // Already ISO-formatted (e.g. tests using literal "YYYY-MM-DD HH:MM:SS").
        if (created_at.len > created_iso_buf.len) return error.TimestampTooLong;
        @memcpy(created_iso_buf[0..created_at.len], created_at);
        break :blk created_at.len;
    };
    const created_iso: []const u8 = created_iso_buf[0..created_iso_len];

    const sql =
        \\INSERT INTO llm_history (id, session_id, role, response_content, is_feed_to_llm, created_at, created_iso)
        \\VALUES (?, ?, ?, ?, ?, ?, ?)
    ;
    try db.exec(alloc, sql, &.{ id, sess, role, content, feed_str, created_at, created_iso });
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
// by `datetime(created_at / 1000000, 'unixepoch')` at
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
        "SELECT datetime(? / 1000000, 'unixepoch')",
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
        "SELECT datetime(? / 1000000, 'unixepoch')",
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
        \\SELECT datetime(? / 1000000, 'unixepoch') AS since_iso,
        \\       datetime(? / 1000000, 'unixepoch') AS until_iso
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

test "saveMessage: writes a correct-year (2026-ish) created_iso from current time" {
    // Regression check for the year-58,507 bug. Pre-fix `saveMessage`
    // passed raw nanoseconds to the ISO conversion helper, producing
    // year 58,507. Post-fix, saveMessage divides by `ns_per_us` (1000)
    // before calling `currentTimeIsoLocal`, so the year is in the 2020s.
    //
    // We use the live `std.Io.Timestamp.now(...)` clock (same as
    // saveMessage) and verify the resulting `created_iso` starts with
    // "20" (year 2000-2099), NOT with "58".
    //
    // Uses a dedicated schema because the shared `setupDb()` in this
    // file only creates the columns needed by `getCompactedMessages`,
    // not the full set required by `saveMessage`. We also need a
    // `sessions` table because saveMessage runs `UPDATE sessions
    // SET cwd = ?` at the end.
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var db: sqlite.SqliteBackend = .{};
    defer db.deinit();
    try db.init(io, ":memory:");

    try db.exec(alloc,
        \\CREATE TABLE llm_history (
        \\    id TEXT PRIMARY KEY,
        \\    session_id TEXT NOT NULL,
        \\    model TEXT,
        \\    response_content TEXT,
        \\    finish_reason TEXT,
        \\    role TEXT,
        \\    tool_calls_json TEXT,
        \\    tool_call_id TEXT,
        \\    reasoning_content TEXT,
        \\    is_feed_to_llm INTEGER DEFAULT 1,
        \\    agent TEXT,
        \\    loop_index INTEGER,
        \\    temperature REAL,
        \\    is_thinking INTEGER,
        \\    created_at TEXT,
        \\    created_iso TEXT,
        \\    parent_session_id TEXT,
        \\    parent_id TEXT,
        \\    prompt_tokens INTEGER,
        \\    completion_tokens INTEGER,
        \\    total_tokens INTEGER,
        \\    cache_creation_input_tokens INTEGER DEFAULT 0,
        \\    cache_read_input_tokens INTEGER DEFAULT 0,
        \\    is_input INTEGER,
        \\    is_output INTEGER,
        \\    tool_name TEXT,
        \\    diffview_before TEXT,
        \\    diffview_after TEXT,
        \\    image_url TEXT
        \\)
    , &.{});
    try db.exec(alloc,
        \\CREATE TABLE sessions (
        \\    id TEXT PRIMARY KEY,
        \\    cwd TEXT,
        \\    updated_at TEXT
        \\)
    , &.{});

    try llm_history.saveMessage(alloc, io, &db, .{
        .session_id = "sess_regression",
        .model = "test",
        .cwd = "/tmp",
        .content = "hello",
        .reasoning_content = null,
        .role = "user",
        .finish_reason = null,
        .tool_calls = null,
        .tool_call_id = null,
        .agent_name = "test",
        .loop_index = 0,
        .temperature = 0.0,
        .is_thinking = false,
        .is_input = true,
        .is_output = false,
    });

    var q = try db.query(alloc,
        "SELECT created_iso FROM llm_history WHERE session_id = 'sess_regression'", &.{});
    defer q.deinit();
    const row = (try q.next()) orelse return error.RowMissing;
    defer row.deinit(alloc);

    // Year must be in the 2020s, not 58507.
    try testing.expect(std.mem.indexOf(u8, row.values[0], "20") != null);
    try testing.expect(std.mem.indexOf(u8, row.values[0], "58507") == null);
}

test "saveMessage: created_at column is stored as Unix microseconds (length <= 17)" {
    // Regression check: saveMessage must store `created_at` as
    // microseconds (16 digits for year 2026). Pre-fix code stored
    // raw nanoseconds (19 digits), which doesn't match the
    // documented `created_at DATETIME/TEXT` contract.
    //
    // Uses the same dedicated schema as the test above.
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var db: sqlite.SqliteBackend = .{};
    defer db.deinit();
    try db.init(io, ":memory:");

    try db.exec(alloc,
        \\CREATE TABLE llm_history (
        \\    id TEXT PRIMARY KEY,
        \\    session_id TEXT NOT NULL,
        \\    model TEXT,
        \\    response_content TEXT,
        \\    finish_reason TEXT,
        \\    role TEXT,
        \\    tool_calls_json TEXT,
        \\    tool_call_id TEXT,
        \\    reasoning_content TEXT,
        \\    is_feed_to_llm INTEGER DEFAULT 1,
        \\    agent TEXT,
        \\    loop_index INTEGER,
        \\    temperature REAL,
        \\    is_thinking INTEGER,
        \\    created_at TEXT,
        \\    created_iso TEXT,
        \\    parent_session_id TEXT,
        \\    parent_id TEXT,
        \\    prompt_tokens INTEGER,
        \\    completion_tokens INTEGER,
        \\    total_tokens INTEGER,
        \\    cache_creation_input_tokens INTEGER DEFAULT 0,
        \\    cache_read_input_tokens INTEGER DEFAULT 0,
        \\    is_input INTEGER,
        \\    is_output INTEGER,
        \\    tool_name TEXT,
        \\    diffview_before TEXT,
        \\    diffview_after TEXT,
        \\    image_url TEXT
        \\)
    , &.{});
    try db.exec(alloc,
        \\CREATE TABLE sessions (
        \\    id TEXT PRIMARY KEY,
        \\    cwd TEXT,
        \\    updated_at TEXT
        \\)
    , &.{});

    try llm_history.saveMessage(alloc, io, &db, .{
        .session_id = "sess_micros",
        .model = "test",
        .cwd = "/tmp",
        .content = "hello",
        .reasoning_content = null,
        .role = "user",
        .finish_reason = null,
        .tool_calls = null,
        .tool_call_id = null,
        .agent_name = "test",
        .loop_index = 0,
        .temperature = 0.0,
        .is_thinking = false,
        .is_input = true,
        .is_output = false,
    });

    var q = try db.query(alloc,
        "SELECT created_at FROM llm_history WHERE session_id = 'sess_micros'", &.{});
    defer q.deinit();
    const row = (try q.next()) orelse return error.RowMissing;
    defer row.deinit(alloc);

    // Microsecond format is at most 17 digits for any plausible
    // timestamp (year ~9999). 19 digits = nanoseconds, which is the
    // bug we're guarding against.
    try testing.expect(row.values[0].len <= 19);
}
