//! Tests for `llm_history.searchMessagesFts` and the new `include_all`
//! toggle on `getCompactedMessages` (Chunk 2 of the search_history rewrite
//! plan). Verifies FTS5 indexing, snippet generation, filter combinators,
//! and the `is_feed_to_llm` toggle.

const std = @import("std");
const testing = std.testing;
const sqlite = @import("nalarcore").sqlite;
const llm_history = @import("nalarcore").llm_history;

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
        \\  created_at TEXT DEFAULT (datetime('now'))
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
