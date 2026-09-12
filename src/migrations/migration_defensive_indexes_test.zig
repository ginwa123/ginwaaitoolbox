//! Behavioral tests for Migration 049 (add defensive indexes).
//!
//! Why a behavioral DB test (not a static check)?
//! ───────────────────────────────────────────────
//! Migration 049 adds two low-cost insurance indexes — one on
//! `workspace_items(position DESC, id ASC)` and one on
//! `routines(last_status)`. A static source check would not catch a
//! misspelled index name, a wrong column order, or a dropped
//! `CREATE INDEX` statement — all of which would make the planner
//! silently fall back to a full table scan. We assert the indexes
//! actually exist in `sqlite_master` after `up()` runs, mirroring the
//! pattern from `migration_chat_list_index_test.zig` (the most recent
//! precedent) and `migration_routines_test.zig`.
//!
//! The SqliteBackend's public API (see
//! `ruangsql src/sqlite/Sqlite.zig (github.com/ginwa123/ruangsql)`) is: `init`, `exec`,
//! `query` (returns `Rows` with `next()` → `?Row` carrying
//! `values: [][]u8`). There is no `prepare`/`step`/`columnText`/
//! `columnInt` public API — column reads go through `Row.values[i]`,
//! which is always text.
//!
//! Plan: docs/plans/2026-06-19-performance-indexes.md (Chunk 3)

const std = @import("std");
const testing = std.testing;
const nalarcore = @import("nalarcore");
const sqlite = nalarcore.sqlite;

const migration = @import("migration.zig");
const Migration049AddDefensiveIndexes = migration.Migration049AddDefensiveIndexes;

// ─── Test helpers ─────────────────────────────────────────────────────────

/// Open a fresh in-memory sqlite DB with BOTH `workspace_items` and
/// `routines` (plus the FK parent `workspace_item_tasks`) present —
/// matching the schema state just before Migration 049 runs. Migration
/// 049 does not add any columns, only two new indexes on existing
/// tables, so the minimum column set is whatever the two target
/// indexes reference.
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

    // workspace_item_tasks — parent of the routines.task_id FK.
    // The new indexes don't reference it, but the routines table
    // declares an FK to it so SQLite will reject CREATE TABLE
    // without it (the FK is a column-level constraint, so the
    // referenced table must exist before CREATE TABLE routines).
    try db.exec(alloc,
        \\CREATE TABLE workspace_item_tasks (
        \\    id TEXT PRIMARY KEY,
        \\    name TEXT NOT NULL,
        \\    workspace_item_id TEXT NOT NULL
        \\)
    , &.{});

    // workspace_items — minimum columns for the position_id index.
    // The index covers (position DESC, id ASC), so both columns must
    // exist with compatible types. We mirror Migration 028's original
    // schema (id, workspace_id, item_type) and add `position` (the
    // Migration 045 schema). The test never inserts rows, so the
    // other columns are inert.
    try db.exec(alloc,
        \\CREATE TABLE workspace_items (
        \\    id TEXT PRIMARY KEY,
        \\    workspace_id TEXT NOT NULL,
        \\    item_type TEXT NOT NULL,
        \\    name TEXT,
        \\    path TEXT,
        \\    position INTEGER NOT NULL DEFAULT 0,
        \\    created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
        \\    updated_at DATETIME DEFAULT CURRENT_TIMESTAMP
        \\)
    , &.{});

    // routines — minimum columns for the last_status index. We
    // mirror the full Migration 044 CREATE TABLE (sans the
    // created_at / updated_at defaults which the test doesn't care
    // about) so the new index is guaranteed compatible.
    try db.exec(alloc,
        \\CREATE TABLE routines (
        \\    id TEXT PRIMARY KEY,
        \\    task_id TEXT NOT NULL UNIQUE,
        \\    schedule TEXT NOT NULL,
        \\    initial_prompt TEXT NOT NULL,
        \\    enabled INTEGER NOT NULL DEFAULT 1,
        \\    last_run_at DATETIME,
        \\    next_run_at DATETIME NOT NULL,
        \\    last_status TEXT,
        \\    last_error TEXT,
        \\    FOREIGN KEY (task_id) REFERENCES workspace_item_tasks(id) ON DELETE CASCADE
        \\)
    , &.{});

    return .{ .db = db, .threaded = threaded };
}

/// Look up a single scalar text value from a SELECT. Returns the
/// empty slice if there is no row.
fn scalarText(alloc: std.mem.Allocator, db: *sqlite.SqliteBackend, sql: []const u8, args: []const []const u8) ![]u8 {
    var q = try db.query(alloc, sql, args);
    defer q.deinit();
    if (try q.next()) |row| {
        defer row.deinit(alloc);
        return try alloc.dupe(u8, row.values[0]);
    }
    return try alloc.dupe(u8, "");
}

// ─── Test 1: idx_workspace_items_position_id exists in sqlite_master ─────

test "Migration049AddDefensiveIndexes creates idx_workspace_items_position_id index" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    try Migration049AddDefensiveIndexes.up(&ctx.db, alloc);

    // Query sqlite_master for the index name. If the migration forgot
    // to create the index, the query returns zero rows. We check
    // `name` (not just existence) so a typo in the index name is
    // caught — sqlite_master would still report it as a row.
    var q = try ctx.db.query(alloc,
        \\SELECT name FROM sqlite_master
        \\WHERE type = 'index'
        \\  AND name = 'idx_workspace_items_position_id'
    , &.{});
    defer q.deinit();

    var found = false;
    while (try q.next()) |row| {
        defer row.deinit(alloc);
        if (std.mem.eql(u8, row.values[0], "idx_workspace_items_position_id")) {
            found = true;
        }
    }
    try testing.expect(found);
}

// ─── Test 2: idx_routines_last_status exists in sqlite_master ────────────

test "Migration049AddDefensiveIndexes creates idx_routines_last_status index" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    try Migration049AddDefensiveIndexes.up(&ctx.db, alloc);

    // Same pattern as test 1 but for the routines index.
    var q = try ctx.db.query(alloc,
        \\SELECT name FROM sqlite_master
        \\WHERE type = 'index'
        \\  AND name = 'idx_routines_last_status'
    , &.{});
    defer q.deinit();

    var found = false;
    while (try q.next()) |row| {
        defer row.deinit(alloc);
        if (std.mem.eql(u8, row.values[0], "idx_routines_last_status")) {
            found = true;
        }
    }
    try testing.expect(found);
}

// ─── Test 3: migration is idempotent (re-running up() does not fail) ─────

test "Migration049AddDefensiveIndexes is idempotent on re-run" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    // The migration uses `CREATE INDEX IF NOT EXISTS` so a second
    // run is a no-op for both indexes. We assert no error is
    // returned. (Defensive: if a future change drops the IF NOT
    // EXISTS, this test fails immediately.)
    try Migration049AddDefensiveIndexes.up(&ctx.db, alloc);
    try Migration049AddDefensiveIndexes.up(&ctx.db, alloc);

    // And both indexes are still there exactly once. COUNT(*) is
    // returned as text per the SqliteBackend's row-as-text API.
    const wi_count = try scalarText(alloc, &ctx.db,
        \\SELECT COUNT(*) FROM sqlite_master
        \\WHERE type = 'index'
        \\  AND name = 'idx_workspace_items_position_id'
    , &.{});
    defer alloc.free(wi_count);
    try testing.expectEqualStrings("1", wi_count);

    const r_count = try scalarText(alloc, &ctx.db,
        \\SELECT COUNT(*) FROM sqlite_master
        \\WHERE type = 'index'
        \\  AND name = 'idx_routines_last_status'
    , &.{});
    defer alloc.free(r_count);
    try testing.expectEqualStrings("1", r_count);
}
