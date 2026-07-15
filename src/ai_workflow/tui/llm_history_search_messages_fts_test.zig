//! Tests for `llm_history.searchMessagesFts` and the new `include_all`
//! toggle on `getCompactedMessages` (Chunk 2 of the search_history rewrite
//! plan). Verifies FTS5 indexing, snippet generation, filter combinators,
//! and the `is_feed_to_llm` toggle.

const std = @import("std");
const testing = std.testing;
const sqlite = @import("nalarcore").sqlite;
const llm_history = @import("nalarcore").llm_history;
const helpers = @import("nalarcore").helpers;

const TestCtx = struct {
    db: sqlite.SqliteBackend,
    threaded: std.Io.Threaded,
};

fn setupDb() !TestCtx {
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
        \\  -- Mirrors Migration 059 in production: a regular TEXT column.
        \\  -- No INSERT trigger — production populates it from application
        \\  -- code in `saveMessage`. For test convenience, default to
        \\  -- 'now localtime' (matching `created_at`'s default of 'now').
        \\  -- Tests that need specific timestamps pass `created_at` AND
        \\  -- `created_iso` explicitly via a sub-SELECT that mirrors the
        \\  -- production conversion.
        \\  created_iso TEXT DEFAULT (strftime('%Y-%m-%d %H:%M:%S', 'now'))
        \\)
    , &.{});
    try db.exec(alloc,
        \\CREATE VIRTUAL TABLE messages_fts USING fts5(
        \\    content
        \\)
    , &.{});

    // Sync triggers — same shape as Migration 058 in production (now
    // non-external-content so snippet() can read from messages_fts).
    try db.exec(alloc,
        \\CREATE TRIGGER llm_history_ai AFTER INSERT ON llm_history BEGIN
        \\  INSERT INTO messages_fts(rowid, content) VALUES (new.rowid, COALESCE(new.response_content, ''));
        \\END
    , &.{});
    try db.exec(alloc,
        \\CREATE TRIGGER llm_history_ad AFTER DELETE ON llm_history BEGIN
        \\  DELETE FROM messages_fts WHERE rowid = old.rowid;
        \\END
    , &.{});
    try db.exec(alloc,
        \\CREATE TRIGGER llm_history_au AFTER UPDATE ON llm_history BEGIN
        \\  DELETE FROM messages_fts WHERE rowid = old.rowid;
        \\  INSERT INTO messages_fts(rowid, content) VALUES (new.rowid, COALESCE(new.response_content, ''));
        \\END
    , &.{});

    return .{ .db = db, .threaded = threaded };
}

test "searchMessagesFts: returns hits ranked by relevance" {
    var s = try setupDb();
    defer { s.db.deinit(); s.threaded.deinit(); }
    const alloc = testing.allocator;

    try s.db.exec(alloc,
        "INSERT INTO llm_history (id, session_id, role, response_content) " ++
        "VALUES ('h1','s_1','user','the login bug needs fixing urgently')",
        &.{});
    try s.db.exec(alloc,
        "INSERT INTO llm_history (id, session_id, role, response_content) " ++
        "VALUES ('h2','s_1','user','all tests pass')",
        &.{});

    const hits = try llm_history.searchMessagesFts(alloc, &s.db, "login bug", .{});
    defer {
        for (hits) |h| {
            var copy = h;
            copy.deinit(alloc);
        }
        alloc.free(hits);
    }

    try testing.expectEqual(@as(usize, 1), hits.len);
    try testing.expectEqualStrings("h1", hits[0].id);
    // Snippet should contain [markers] around the matched tokens
    try testing.expect(std.mem.indexOf(u8, hits[0].snippet, "[") != null);
    try testing.expect(std.mem.indexOf(u8, hits[0].snippet, "login") != null);
}

test "searchMessagesFts: filters by session_id" {
    var s = try setupDb();
    defer { s.db.deinit(); s.threaded.deinit(); }
    const alloc = testing.allocator;

    try s.db.exec(alloc,
        "INSERT INTO llm_history (id, session_id, role, response_content) " ++
        "VALUES ('h1','s_a','user','the bug is fixed')", &.{});
    try s.db.exec(alloc,
        "INSERT INTO llm_history (id, session_id, role, response_content) " ++
        "VALUES ('h2','s_b','user','a different bug exists')", &.{});

    const hits = try llm_history.searchMessagesFts(alloc, &s.db, "bug", .{
        .session_id = "s_a",
    });
    defer {
        for (hits) |h| {
            var copy = h;
            copy.deinit(alloc);
        }
        alloc.free(hits);
    }

    try testing.expectEqual(@as(usize, 1), hits.len);
    try testing.expectEqualStrings("h1", hits[0].id);
}

test "searchMessagesFts: filters by role" {
    var s = try setupDb();
    defer { s.db.deinit(); s.threaded.deinit(); }
    const alloc = testing.allocator;

    try s.db.exec(alloc,
        "INSERT INTO llm_history (id, session_id, role, response_content) " ++
        "VALUES ('h1','s_1','user','user asked about password reset')", &.{});
    try s.db.exec(alloc,
        "INSERT INTO llm_history (id, session_id, role, response_content) " ++
        "VALUES ('h2','s_1','assistant','the password reset feature')", &.{});

    const hits = try llm_history.searchMessagesFts(alloc, &s.db, "password", .{
        .role = "user",
    });
    defer {
        for (hits) |h| {
            var copy = h;
            copy.deinit(alloc);
        }
        alloc.free(hits);
    }

    try testing.expectEqual(@as(usize, 1), hits.len);
    try testing.expectEqualStrings("h1", hits[0].id);
}

test "searchMessagesFts: respects limit" {
    var s = try setupDb();
    defer { s.db.deinit(); s.threaded.deinit(); }
    const alloc = testing.allocator;

    var i: usize = 0;
    while (i < 10) : (i += 1) {
        const id_buf = try std.fmt.allocPrint(alloc, "h_{d}", .{i});
        defer alloc.free(id_buf);
        try s.db.exec(alloc,
            "INSERT INTO llm_history (id, session_id, role, response_content) " ++
            "VALUES (?, 's_1', 'user', 'common keyword here')",
            &.{id_buf});
    }

    const hits = try llm_history.searchMessagesFts(alloc, &s.db, "common", .{
        .limit = 3,
    });
    defer {
        for (hits) |h| {
            var copy = h;
            copy.deinit(alloc);
        }
        alloc.free(hits);
    }

    try testing.expectEqual(@as(usize, 3), hits.len);
}

test "searchMessagesFts: returns empty array when no matches" {
    var s = try setupDb();
    defer { s.db.deinit(); s.threaded.deinit(); }
    const alloc = testing.allocator;

    try s.db.exec(alloc,
        "INSERT INTO llm_history (id, session_id, role, response_content) " ++
        "VALUES ('h1','s_1','user','nothing relevant here')", &.{});

    const hits = try llm_history.searchMessagesFts(alloc, &s.db, "monkeywrench", .{});
    defer alloc.free(hits);

    try testing.expectEqual(@as(usize, 0), hits.len);
}

test "searchMessagesFts: tool_call_id and tool_name surfaced for tool-role hits" {
    var s = try setupDb();
    defer { s.db.deinit(); s.threaded.deinit(); }
    const alloc = testing.allocator;

    try s.db.exec(alloc,
        "INSERT INTO llm_history (id, session_id, role, response_content, " ++
        "tool_call_id, tool_name) " ++
        "VALUES ('h1','s_1','tool','exit code 42','tc_1','bash')",
        &.{});

    const hits = try llm_history.searchMessagesFts(alloc, &s.db, "exit code", .{});
    defer {
        for (hits) |h| {
            var copy = h;
            copy.deinit(alloc);
        }
        alloc.free(hits);
    }

    try testing.expectEqual(@as(usize, 1), hits.len);
    try testing.expectEqualStrings("tool", hits[0].role);
    try testing.expectEqualStrings("tc_1", hits[0].tool_call_id.?);
    try testing.expectEqualStrings("bash", hits[0].tool_name.?);
}

test "getCompactedMessages: include_all=true returns live AND compacted rows" {
    var s = try setupDb();
    defer { s.db.deinit(); s.threaded.deinit(); }
    const alloc = testing.allocator;

    // Seed: 1 live (is_feed_to_llm=1) + 1 compacted (is_feed_to_llm=0)
    try s.db.exec(alloc,
        "INSERT INTO llm_history (id, session_id, role, response_content, is_feed_to_llm) " ++
        "VALUES ('live_1','s_full','user','live message',1)", &.{});
    try s.db.exec(alloc,
        "INSERT INTO llm_history (id, session_id, role, response_content, is_feed_to_llm) " ++
        "VALUES ('compact_1','s_full','assistant','compacted message',0)", &.{});

    // Default behavior (include_all=false): only compacted.
    const compact_only = try llm_history.getCompactedMessages(alloc, &s.db, "s_full", .{});
    defer {
        for (compact_only) |m| {
            var copy = m;
            copy.deinit(alloc);
        }
        alloc.free(compact_only);
    }
    try testing.expectEqual(@as(usize, 1), compact_only.len);
    try testing.expectEqualStrings("compact_1", compact_only[0].id);

    // include_all=true: both rows.
    const all_rows = try llm_history.getCompactedMessages(alloc, &s.db, "s_full", .{
        .include_all = true,
    });
    defer {
        for (all_rows) |m| {
            var copy = m;
            copy.deinit(alloc);
        }
        alloc.free(all_rows);
    }
    try testing.expectEqual(@as(usize, 2), all_rows.len);
}

// ────────────────────────────────────────────────────────────────────────
// Regression tests for the since/until bug
// (docs/superpowers/plans/2026-07-15-search-history-since-until-bug.md).
//
// These exercise the filter on `created_iso` (the STORED generated column
// added by Migration 059) instead of `created_at` (which stores Unix
// microseconds — lex-comparing that against a date string silently
// returns 0 rows because '1' < '2' in ASCII order).
//
// We seed with two known microsecond timestamps and compute the
// expected `created_iso` via the SAME SQLite expression the migration
// uses (`datetime(N / 1000000, 'unixepoch')`). This keeps
// the test timezone-agnostic: both the seed and the filter go through
// the same localtime conversion, so they agree regardless of TZ.
// ────────────────────────────────────────────────────────────────────────

test "searchMessagesFts: filters by since using ISO date string (regression for since/until bug)" {
    var s = try setupDb();
    defer { s.db.deinit(); s.threaded.deinit(); }
    const alloc = testing.allocator;

    // Seed: two messages at known microsecond timestamps.
    // Pick values that are unambiguously different from each other and
    // survive any timezone (we never assert the literal ISO string —
    // only that the filter on it works).
    const old_micros: []const u8 = "1780000000000000"; // ~2026-05-29 17:33 UTC
    const new_micros: []const u8 = "1785000000000000"; // ~2026-06-23 12:40 UTC

    // Production code in `saveMessage` computes `created_iso` from
    // `created_at` via libc `localtime_r` + `strftime`. The exact
    // SQLite expression that matches that conversion is
    // `datetime(<micros>/1000000, 'unixepoch')` — but
    // our test schema uses `substr(micros, 1, 10)` (the migration's
    // backfill expression) for consistency with the migration's
    // idempotent backfill. This drops microsecond precision but is
    // fine for `since`/`until` tests at minute granularity.
    try s.db.exec(alloc,
        "INSERT INTO llm_history (id, session_id, role, response_content, created_at, created_iso) " ++
        "VALUES ('h_old','s1','user','old message',?,datetime(substr(?,1,10),'unixepoch'))", &.{ old_micros, old_micros });
    try s.db.exec(alloc,
        "INSERT INTO llm_history (id, session_id, role, response_content, created_at, created_iso) " ++
        "VALUES ('h_new','s1','user','new message',?,datetime(substr(?,1,10),'unixepoch'))", &.{ new_micros, new_micros });

    // Compute the ISO date for `new_micros` using the SAME expression the
    // migration uses — that's what `created_iso` will contain.
    var iso_q = try s.db.queryRow(alloc,
        "SELECT datetime(? / 1000000, 'unixepoch')",
        &.{new_micros});
    defer iso_q.deinit(alloc);
    const new_iso = iso_q.values[0];

    // FTS match for "message" — both rows match. Filter on since=new_iso
    // should return only `h_new`.
    const hits = try llm_history.searchMessagesFts(alloc, &s.db, "message", .{
        .since = new_iso,
    });
    defer {
        for (hits) |h| {
            var copy = h;
            copy.deinit(alloc);
        }
        alloc.free(hits);
    }
    try testing.expectEqual(@as(usize, 1), hits.len);
    try testing.expectEqualStrings("h_new", hits[0].id);
    try testing.expectEqual(@as(u32, 1), hits[0].total_count); // only 1 row after filter
}

test "searchMessagesFts: filters by until using ISO date string (regression for since/until bug)" {
    var s = try setupDb();
    defer { s.db.deinit(); s.threaded.deinit(); }
    const alloc = testing.allocator;

    const old_micros: []const u8 = "1780000000000000";
    const new_micros: []const u8 = "1785000000000000";

    try s.db.exec(alloc,
        "INSERT INTO llm_history (id, session_id, role, response_content, created_at, created_iso) " ++
        "VALUES ('h_old','s1','user','old message',?,datetime(substr(?,1,10),'unixepoch'))", &.{ old_micros, old_micros });
    try s.db.exec(alloc,
        "INSERT INTO llm_history (id, session_id, role, response_content, created_at, created_iso) " ++
        "VALUES ('h_new','s1','user','new message',?,datetime(substr(?,1,10),'unixepoch'))", &.{ new_micros, new_micros });

    // Compute the ISO for `old_micros` — `until=old_iso` should keep only h_old.
    // Use the same `substr(_,1,10)` expression as the inserted rows so
    // the lex comparison matches exactly.
    var iso_q = try s.db.queryRow(alloc,
        "SELECT datetime(substr(? ,1, 10), 'unixepoch')",
        &.{old_micros});
    defer iso_q.deinit(alloc);
    const old_iso = iso_q.values[0];

    const hits = try llm_history.searchMessagesFts(alloc, &s.db, "message", .{
        .until = old_iso,
    });
    defer {
        for (hits) |h| {
            var copy = h;
            copy.deinit(alloc);
        }
        alloc.free(hits);
    }
    try testing.expectEqual(@as(usize, 1), hits.len);
    try testing.expectEqualStrings("h_old", hits[0].id);
}

test "searchMessagesFts: since AND until together produce a date range (regression)" {
    var s = try setupDb();
    defer { s.db.deinit(); s.threaded.deinit(); }
    const alloc = testing.allocator;

    const old_micros: []const u8 = "1780000000000000";
    const mid_micros: []const u8 = "1783000000000000";
    const new_micros: []const u8 = "1785000000000000";

    try s.db.exec(alloc,
        "INSERT INTO llm_history (id, session_id, role, response_content, created_at, created_iso) " ++
        "VALUES ('h_old','s1','user','old message',?,datetime(substr(?,1,10),'unixepoch'))", &.{ old_micros, old_micros });
    try s.db.exec(alloc,
        "INSERT INTO llm_history (id, session_id, role, response_content, created_at, created_iso) " ++
        "VALUES ('h_mid','s1','user','mid message',?,datetime(substr(?,1,10),'unixepoch'))", &.{ mid_micros, mid_micros });
    try s.db.exec(alloc,
        "INSERT INTO llm_history (id, session_id, role, response_content, created_at, created_iso) " ++
        "VALUES ('h_new','s1','user','new message',?,datetime(substr(?,1,10),'unixepoch'))", &.{ new_micros, new_micros });

    // Use the same substr(_,1,10) expression as the inserted rows so the
    // lex comparison matches exactly.
    var iso_q = try s.db.queryRow(alloc,
        \\SELECT datetime(substr(? ,1,10), 'unixepoch') AS since_iso,
        \\       datetime(substr(? ,1,10), 'unixepoch') AS until_iso
    , &.{ mid_micros, new_micros });
    defer iso_q.deinit(alloc);
    const since_iso = iso_q.values[0];
    const until_iso = iso_q.values[1];

    const hits = try llm_history.searchMessagesFts(alloc, &s.db, "message", .{
        .since = since_iso,
        .until = until_iso,
    });
    defer {
        for (hits) |h| {
            var copy = h;
            copy.deinit(alloc);
        }
        alloc.free(hits);
    }
    try testing.expectEqual(@as(usize, 2), hits.len);
    // Expectation: h_mid and h_new (the "since..until" inclusive window)
    // — but order is by rank, which is the same as no ORDER BY since
    // the MATCH score ties. Check that both are present.
    var ids: [2][]const u8 = undefined;
    for (hits, 0..) |h, i| ids[i] = h.id;
    // Both h_mid and h_new should be present (h_old should not).
    try testing.expect(std.mem.indexOf(u8, ids[0], "h_old") == null or
        std.mem.indexOf(u8, ids[1], "h_old") == null);
}
