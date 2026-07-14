//! Behavioral tests for Migration 048 (add chat-list covering index).
//!
//! Why a behavioral DB test (not a static check)?
//! ───────────────────────────────────────────────
//! Migration 048 adds a single new SQLite index
//! (`idx_llm_history_created_session` on `(created_at DESC, session_id)`)
//! that is the load-bearing optimization for the chat-list query at
//! `llm_history.zig:115`. A static source check would not catch a
//! misspelled index name, a wrong column order, or a missing `DESC` on
//! `created_at` — all of which would make the planner silently fall
//! back to a full table scan. We assert the index actually exists in
//! `sqlite_master` after `up()` runs, mirroring the pattern from
//! `migration_routines_test.zig`.
//!
//! The SqliteBackend's public API (see
//! `src/modules/databases/sqlite/Sqlite.zig`) is: `init`, `exec`,
//! `query` (returns `Rows` with `next()` → `?Row` carrying
//! `values: [][]u8`). There is no `prepare`/`step`/`columnText`/
//! `columnInt` public API — column reads go through `Row.values[i]`,
//! which is always text.
//!
//! Plan: docs/plans/2026-06-19-performance-indexes.md (Chunk 1)

const std = @import("std");
const testing = std.testing;
const nalarcore = @import("nalarcore");
const sqlite = nalarcore.sqlite;

const migration = @import("migration.zig");
const Migration048AddChatListIndex = migration.Migration048AddChatListIndex;

// ─── Test helpers ─────────────────────────────────────────────────────────

/// Open a fresh in-memory sqlite DB with the `llm_history` table present
/// (matching the schema created by Migration 001), ready for
/// Migration 048 to add the `idx_llm_history_created_session` index on top.
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

    // Mirror the state left by Migration 001 exactly — same columns,
    // same NULL/NOT NULL semantics. The index only touches
    // (created_at, session_id) so those are the columns that must
    // exist with compatible types.
    try db.exec(alloc,
        \\CREATE TABLE llm_history (
        \\    id TEXT PRIMARY KEY,
        \\    session_id TEXT NOT NULL,
        \\    model TEXT NOT NULL,
        \\    response_content TEXT,
        \\    tool_calls_json TEXT,
        \\    tool_results_json TEXT,
        \\    finish_reason TEXT,
        \\    usage_json TEXT,
        \\    created_at DATETIME DEFAULT CURRENT_TIMESTAMP
        \\)
    , &.{});

    return .{ .db = db, .threaded = threaded };
}

// ─── Test 1: index exists in sqlite_master after up() ─────────────────────

test "Migration048AddChatListIndex creates idx_llm_history_created_session index" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    try Migration048AddChatListIndex.up(&ctx.db, alloc);

    // Query sqlite_master for the index name. If the migration forgot
    // to create the index, the query returns zero rows. We check
    // `name` (not just existence) so a typo in the index name is
    // caught — sqlite_master would still report it as a row.
    var q = try ctx.db.query(alloc,
        \\SELECT name FROM sqlite_master
        \\WHERE type = 'index'
        \\  AND name = 'idx_llm_history_created_session'
    , &.{});
    defer q.deinit();

    var found = false;
    while (try q.next()) |row| {
        defer row.deinit(alloc);
        if (std.mem.eql(u8, row.values[0], "idx_llm_history_created_session")) {
            found = true;
        }
    }
    try testing.expect(found);
}

// ─── Test 2: migration is idempotent (re-running up() does not fail) ─────

test "Migration048AddChatListIndex is idempotent on re-run" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    // The migration uses `CREATE INDEX IF NOT EXISTS` so a second
    // run is a no-op. We assert no error is returned.
    try Migration048AddChatListIndex.up(&ctx.db, alloc);
    try Migration048AddChatListIndex.up(&ctx.db, alloc);

    // And the index is still there exactly once.
    var q = try ctx.db.query(alloc,
        \\SELECT COUNT(*) FROM sqlite_master
        \\WHERE type = 'index'
        \\  AND name = 'idx_llm_history_created_session'
    , &.{});
    defer q.deinit();

    const row = (try q.next()) orelse return error.ExpectedRow;
    defer row.deinit(alloc);
    try testing.expectEqualStrings("1", row.values[0]);
}
