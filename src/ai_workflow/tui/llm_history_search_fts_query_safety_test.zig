//! Tests for the FTS5 query-safety layer added to `llm_history.searchMessagesFts`.
//!
//! **The bug** (user report, task_1785658329168): plain text queries that
//! happen to contain FTS5 special characters fail with
//! `"FTS search failed: QueryFailed"`:
//!
//!   - `handle_tool.zig` (`.`)
//!   - `2026-08-06` (`-` is FTS5 binary NOT → invalid expression)
//!   - `agentic_loop/handle_tool.zig:18` (`:` is FTS5 column filter →
//!     "no such column")
//!
//! `QueryFailed` is the bare enum name — the underlying SQLite message
//! is now captured via `Rows.getLastErrorMessage` (verified in
//! `sqlite_test_rows_capture_error.zig`); but the queries still fail,
//! which is the user's actual complaint.
//!
//! **The fix** is to sanitize the user-supplied FTS5 query string
//! before binding it: replace FTS5 operators (`-`, `+`, `*`, `^`, `:`,
//! `(`, `)`, `"`) with spaces so the query becomes a sequence of
//! literal terms. Common queries like `handle_tool.zig` and `2026-08-06`
//! then find their indexed terms (unicode61 splits on punctuation and
//! indexes each token separately).
//!
//! These tests are RED before the fix (the failing queries return
//! QueryFailed) and GREEN after.

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
        \\  created_at TEXT DEFAULT (datetime('now')),
        \\  created_iso TEXT DEFAULT (strftime('%Y-%m-%d %H:%M:%S', 'now'))
        \\)
    , &.{});
    try db.exec(alloc,
        \\CREATE VIRTUAL TABLE messages_fts USING fts5(content)
    , &.{});
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

fn teardown(ctx: *TestCtx) void {
    ctx.db.deinit();
    ctx.threaded.deinit();
}

/// Insert a row whose `response_content` contains all of the "needle"
/// words in `needles` so we can prove the FTS5 query finds it.
fn insertRow(ctx: *TestCtx, id: []const u8, content: []const u8) !void {
    const alloc = testing.allocator;
    var sql_buf: [512]u8 = undefined;
    const stmt = try std.fmt.bufPrint(sql_buf[0..],
        "INSERT INTO llm_history (id, session_id, role, response_content) " ++
        "VALUES ('{s}','s_1','user','{s}')", .{ id, content });
    try ctx.db.exec(alloc, stmt, &.{});
}

fn freeHits(alloc: std.mem.Allocator, hits: []llm_history.SearchHit) void {
    for (hits) |h| {
        var copy = h;
        copy.deinit(alloc);
    }
    alloc.free(hits);
}

// ─── Tests that prove the failing-queries bug ──────────────────────────
//
// Each test below reproduces a specific query the user ran that
// returned "FTS search failed: QueryFailed". They are written against
// the FIXED behavior — i.e. they expect searchMessagesFts to succeed
// and return the matching row. They will FAIL on the unfixed code
// because the queries either:
//   1. trigger an FTS5 syntax error (returned as `QueryFailed`), or
//   2. return 0 hits because the FTS5 query string is parsed as a
//      single term that doesn't exist in the index.
// The fix sanitizes the query so each piece becomes its own term.

test "searchMessagesFts: dotted identifier handle_tool.zig returns the inserted row" {
    var ctx = try setupDb();
    defer teardown(&ctx);
    const alloc = testing.allocator;

    try insertRow(&ctx, "h1",
        "the agentic_loop/handle_tool.zig has broken imports that we need to fix");

    const hits = try llm_history.searchMessagesFts(alloc, &ctx.db,
        "handle_tool.zig", .{});
    defer freeHits(alloc, hits);

    try testing.expectEqual(@as(usize, 1), hits.len);
    try testing.expectEqualStrings("h1", hits[0].id);
}

test "searchMessagesFts: hyphenated date 2026-08-06 returns the inserted row" {
    var ctx = try setupDb();
    defer teardown(&ctx);
    const alloc = testing.allocator;

    // Use a date-format string the user might search for verbatim
    try insertRow(&ctx, "h_date",
        "log entry on 2026-08-06 says the build is green");

    const hits = try llm_history.searchMessagesFts(alloc, &ctx.db,
        "2026-08-06", .{});
    defer freeHits(alloc, hits);

    try testing.expectEqual(@as(usize, 1), hits.len);
    try testing.expectEqualStrings("h_date", hits[0].id);
}

test "searchMessagesFts: column-syntax colon agentic_loop/handle_tool.zig:18 returns the inserted row" {
    var ctx = try setupDb();
    defer teardown(&ctx);
    const alloc = testing.allocator;

    try insertRow(&ctx, "h_col",
        "the bug at agentic_loop/handle_tool.zig:18 references the broken import");

    // This is the exact query the user tried. Without the fix, FTS5
    // sees the trailing `:18` as a column-name filter on a column that
    // does not exist and returns SQLITE_ERROR.
    const hits = try llm_history.searchMessagesFts(alloc, &ctx.db,
        "agentic_loop/handle_tool.zig:18", .{});
    defer freeHits(alloc, hits);

    try testing.expect(hits.len >= 1);
    try testing.expectEqualStrings("h_col", hits[0].id);
}

test "searchMessagesFts: dotted short word SPEC.md returns the inserted row" {
    var ctx = try setupDb();
    defer teardown(&ctx);
    const alloc = testing.allocator;

    try insertRow(&ctx, "h_spec", "see SPEC.md for the full design");

    const hits = try llm_history.searchMessagesFts(alloc, &ctx.db,
        "SPEC.md", .{});
    defer freeHits(alloc, hits);

    try testing.expectEqual(@as(usize, 1), hits.len);
    try testing.expectEqualStrings("h_spec", hits[0].id);
}

// ─── Tests that already-passing queries still pass (regression guard) ──

test "searchMessagesFts: plain words still match (regression guard)" {
    var ctx = try setupDb();
    defer teardown(&ctx);
    const alloc = testing.allocator;

    try insertRow(&ctx, "h_plain", "the login bug needs fixing urgently");

    const hits = try llm_history.searchMessagesFts(alloc, &ctx.db,
        "login bug", .{});
    defer freeHits(alloc, hits);

    try testing.expectEqual(@as(usize, 1), hits.len);
    try testing.expectEqualStrings("h_plain", hits[0].id);
}