//! Tests for the `update_activity` agent tool path.
//!
//! History
//! ───────
//! This file pre-existed (last touched April 2026 per git blame) but
//! was never registered in any test_runner.zig, so its tests were
//! silently compiled out. The pre-existing tests referenced helpers
//! (`llm_history.upsertWorker`, `llm_history.get_active_workers`)
//! that don't exist in the current codebase — so the file never
//! compiled when wired up.
//!
//! Migration 073 — `session_activity` append-only log — needs to
//! verify that `llm_history.recordSessionActivity` works end-to-end,
//! so this file is now imported from
//! `src/ai_workflow/tui/test_runner.zig`. The dead-code pre-existing
//! tests are removed (they never ran anyway); the two
//! `recordSessionActivity` regression tests below are the canonical
//! behavioural checks for the new helper.
//!
//! Plan: docs/superpowers/plans/2026-08-13-session-activity-table.md
//! Task: task_1786629034327 ("new table session_activity")

const std = @import("std");
const nalarcore = @import("nalarcore");
const sqlite = nalarcore.sqlite;
const llm_history = nalarcore.llm_history;

/// Test fixture: create the tables needed for session_activity +
/// worker operations. Mirrors the canonical CREATE TABLE bodies so
/// the test DB doesn't have to walk the migration chain.
fn setupTables(allocator: std.mem.Allocator, db: *sqlite.SqliteBackend) !void {
    try db.exec(allocator,
        \\CREATE TABLE IF NOT EXISTS sessions (
        \\    id TEXT PRIMARY KEY,
        \\    name TEXT,
        \\    status TEXT DEFAULT 'active',
        \\    working_directory TEXT,
        \\    agent TEXT DEFAULT 'Agent',
        \\    temperature REAL DEFAULT 0.2,
        \\    is_thinking INTEGER DEFAULT 0,
        \\    created_at TEXT DEFAULT (datetime('now'))
        \\)
    , &.{});

    try db.exec(allocator,
        \\CREATE TABLE IF NOT EXISTS worker (
        \\    id TEXT PRIMARY KEY,
        \\    session_id TEXT NOT NULL,
        \\    working_directory TEXT,
        \\    last_activity INTEGER,
        \\    last_activity_description TEXT
        \\)
    , &.{});

    // session_activity table (Migration 073). Mirrors the canonical
    // CREATE TABLE body — tests use it directly because the test DB
    // doesn't walk the migration chain.
    try db.exec(allocator,
        \\CREATE TABLE IF NOT EXISTS session_activity (
        \\    id TEXT PRIMARY KEY,
        \\    session_id TEXT NOT NULL,
        \\    description TEXT NOT NULL,
        \\    created_at DATETIME DEFAULT CURRENT_TIMESTAMP
        \\)
    , &.{});
}

// ============================================================================
// Migration 073 — recordSessionActivity regression tests
// ============================================================================

test "recordSessionActivity inserts a row into session_activity for the given session_id" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var db: sqlite.SqliteBackend = sqlite.SqliteBackend{};
    try db.init(std.testing.io, ":memory:");
    defer db.deinit();

    try setupTables(allocator, &db);

    const session_id = "test_session_abc";
    const description = "[2026-08-13 10:00] test @ /test | Thinking | Working on it";

    try llm_history.recordSessionActivity(allocator, std.testing.io, &db, session_id, description);

    // Exactly 1 row, with the exact session_id + description.
    var q = try db.query(allocator,
        "SELECT session_id, description FROM session_activity WHERE session_id = ?",
        &.{session_id});
    defer q.deinit();
    const row = (try q.next()) orelse return error.RowMissing;
    defer row.deinit(allocator);
    try std.testing.expectEqualStrings(session_id, row.values[0]);
    try std.testing.expectEqualStrings(description, row.values[1]);

    // No further rows.
    try std.testing.expect((try q.next()) == null);
}

test "recordSessionActivity appends a new row each call (same description -> two rows)" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var db: sqlite.SqliteBackend = sqlite.SqliteBackend{};
    try db.init(std.testing.io, ":memory:");
    defer db.deinit();

    try setupTables(allocator, &db);

    const session_id = "test_session_xyz";
    const description = "[2026-08-13 10:00] test @ /test | Repeated thought";

    try llm_history.recordSessionActivity(allocator, std.testing.io, &db, session_id, description);
    try llm_history.recordSessionActivity(allocator, std.testing.io, &db, session_id, description);

    // Exactly 2 rows for this session_id.
    var q = try db.query(allocator,
        "SELECT COUNT(*) FROM session_activity WHERE session_id = ?",
        &.{session_id});
    defer q.deinit();
    const row = (try q.next()) orelse return error.RowMissing;
    defer row.deinit(allocator);
    try std.testing.expectEqualStrings("2", row.values[0]);
}