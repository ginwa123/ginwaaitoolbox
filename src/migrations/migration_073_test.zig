//! Behavioural regression checks for Migration 073
//! (`session_activity` append-only log).
//!
//! Why this file exists
//! ────────────────────
//! Migration 073 adds a per-session activity log that records every
//! `update_activity` tool call AND every compaction event. This is
//! purely additive — `worker.last_activity_description` (the live UI
//! signal) keeps being overwritten as before.
//!
//! The migration must:
//!   1. Create the `session_activity` table with the expected schema
//!      (id TEXT PRIMARY KEY, session_id TEXT NOT NULL,
//!      description TEXT NOT NULL, created_at DATETIME DEFAULT
//!      CURRENT_TIMESTAMP).
//!   2. Create the `idx_session_activity_session_created` index over
//!      `(session_id, created_at DESC)` so the per-session "most
//!      recent N" query is fast.
//!   3. Be idempotent on a re-run (CREATE TABLE IF NOT EXISTS + CREATE
//!      INDEX IF NOT EXISTS — per the project-wide
//!      `migration-is-idempotent` invariant).
//!   4. Allow INSERT + SELECT round-trip on a row.
//!
//! Plan: docs/superpowers/plans/2026-08-13-session-activity-table.md
//! Task: task_1786629034327 ("new table session_activity")

const std = @import("std");
const testing = std.testing;
const sqlite = @import("nalarcore").sqlite;

const Migration073AddSessionActivity = @import("migration.zig").Migration073AddSessionActivity;

const TestCtx = struct {
    db: sqlite.SqliteBackend,
    threaded: std.Io.Threaded,
};

/// Set up an in-memory DB with the empty (pre-migration) state. After
/// Migration 073 runs, `session_activity` exists and the index is
/// installed.
fn setupDb() !TestCtx {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    errdefer threaded.deinit();
    const io = threaded.io();
    var db: sqlite.SqliteBackend = .{};
    errdefer db.deinit();
    try db.init(io, ":memory:");
    return .{ .db = db, .threaded = threaded };
}

// ============================================================================
// Test 1 — Migration creates the `session_activity` table with the right
// columns in the right order.
// ============================================================================

test "Migration073 creates session_activity table with correct columns" {
    // After migration, `pragma_table_info('session_activity')` must
    // show columns in order: id (TEXT PK), session_id (TEXT NOT NULL),
    // description (TEXT NOT NULL), created_at (DATETIME DEFAULT
    // CURRENT_TIMESTAMP).
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    // Sanity: table does NOT exist before the migration.
    {
        var q = try ctx.db.query(alloc,
            "SELECT 1 FROM sqlite_master WHERE type='table' AND name='session_activity'",
            &.{});
        defer q.deinit();
        const row = (try q.next()) orelse null;
        if (row) |r| {
            defer r.deinit(alloc);
            try testing.expect(false); // pre-migration should NOT have session_activity
        }
    }

    try Migration073AddSessionActivity.up(&ctx.db, alloc);

    // Post-migration: table exists.
    {
        var q = try ctx.db.query(alloc,
            "SELECT name FROM sqlite_master WHERE type='table' AND name='session_activity'",
            &.{});
        defer q.deinit();
        const row = (try q.next()) orelse return error.SessionActivityTableNotCreated;
        defer row.deinit(alloc);
        try testing.expectEqualStrings("session_activity", row.values[0]);
    }

    // Verify the 4 expected columns exist with the expected names + order.
    var q = try ctx.db.query(alloc,
        "SELECT name FROM pragma_table_info('session_activity') ORDER BY cid",
        &.{});
    defer q.deinit();
    const expected_columns = [_][]const u8{ "id", "session_id", "description", "created_at" };
    var idx: usize = 0;
    while (try q.next()) |row| {
        defer row.deinit(alloc);
        try testing.expect(idx < expected_columns.len);
        try testing.expectEqualStrings(expected_columns[idx], row.values[0]);
        idx += 1;
    }
    try testing.expectEqual(@as(usize, expected_columns.len), idx);
}

// ============================================================================
// Test 2 — Idempotent on re-run.
// ============================================================================

test "Migration073 is idempotent on a re-run" {
    // The migration's CREATE statements all use IF NOT EXISTS. A
    // second run must NOT crash with "table session_activity already
    // exists" or similar errors.
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try Migration073AddSessionActivity.up(&ctx.db, alloc);
    try Migration073AddSessionActivity.up(&ctx.db, alloc);

    // Still exactly 1 session_activity table.
    var q = try ctx.db.query(alloc,
        "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='session_activity'",
        &.{});
    defer q.deinit();
    const row = (try q.next()) orelse return error.RowMissing;
    defer row.deinit(alloc);
    try testing.expectEqualStrings("1", row.values[0]);
}

// ============================================================================
// Test 3 — Index created.
// ============================================================================

test "Migration073 creates idx_session_activity_session_created index" {
    // After migration, `sqlite_master` must contain a row for
    // `idx_session_activity_session_created` with type='index' over
    // (session_id, created_at DESC).
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    // Sanity: pre-migration, index doesn't exist.
    {
        var q = try ctx.db.query(alloc,
            "SELECT 1 FROM sqlite_master WHERE type='index' AND name='idx_session_activity_session_created'",
            &.{});
        defer q.deinit();
        const row = (try q.next()) orelse null;
        if (row) |r| {
            defer r.deinit(alloc);
            try testing.expect(false); // pre-migration should not have the index
        }
    }

    try Migration073AddSessionActivity.up(&ctx.db, alloc);

    var q = try ctx.db.query(alloc,
        \\SELECT name FROM sqlite_master
        \\WHERE type='index' AND name='idx_session_activity_session_created'
        , &.{});
    defer q.deinit();
    const row = (try q.next()) orelse return error.IndexNotCreated;
    defer row.deinit(alloc);
    try testing.expectEqualStrings("idx_session_activity_session_created", row.values[0]);
}

// ============================================================================
// Test 4 — INSERT + SELECT round-trip.
// ============================================================================

test "Migration073 fresh-DB replay: insert and select a session_activity row" {
    // After migration, an INSERT into session_activity followed by a
    // SELECT must round-trip the values correctly. The id is supplied
    // by the caller (TEXT PK), so we hardcode one for determinism.
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try Migration073AddSessionActivity.up(&ctx.db, alloc);

    try ctx.db.exec(alloc,
        \\INSERT INTO session_activity (id, session_id, description) VALUES (?, ?, ?)
        , &.{ "act_001", "sess_test", "[2026-08-13 10:00] test @ /tmp | Thinking | hello" });

    var q = try ctx.db.query(alloc,
        "SELECT id, session_id, description FROM session_activity WHERE session_id = ?",
        &.{"sess_test"});
    defer q.deinit();
    const row = (try q.next()) orelse return error.RowMissing;
    defer row.deinit(alloc);
    try testing.expectEqualStrings("act_001", row.values[0]);
    try testing.expectEqualStrings("sess_test", row.values[1]);
    try testing.expectEqualStrings("[2026-08-13 10:00] test @ /tmp | Thinking | hello", row.values[2]);

    // No further rows.
    try testing.expect((try q.next()) == null);
}
