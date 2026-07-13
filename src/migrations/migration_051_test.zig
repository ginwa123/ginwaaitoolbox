//! Behavioral tests for Migration 051 (add kanban columns + task column refs).
//!
//! NOTE on numbering: The plan was written before Migrations 048 (chat-list
//! index), 049 (defensive indexes), and 050 (pinned-to-workspace-item-tasks)
//! landed on the branch. Per the plan's "find the LAST migration and add
//! after it" instruction, this migration uses the next available number
//! (051) instead of the originally proposed 048.
//!
//! What Migration 051 adds
//! ───────────────────────
//! 1. `kanban_columns` table with FK ON DELETE CASCADE to `workspace_items(id)`
//! 2. Index `idx_kanban_columns_item_position` on (workspace_item_id, position)
//! 3. Two new columns on `workspace_item_tasks`:
//!      `kanban_column_id TEXT` (nullable — NULL for non-kanban items)
//!      `kanban_position INTEGER NOT NULL DEFAULT 0` (per-column ordering)
//! 4. Index `idx_tasks_column_position` on (kanban_column_id, kanban_position)
//!
//! Why a behavioral DB test (not a static check)?
//! ───────────────────────────────────────────────
//! A static source check would not catch a misspelled table name, missing
//! column, wrong DEFAULT, or missing FK clause. Asserting the actual
//! schema after `up()` runs mirrors the pattern used by
//! `migration_chat_list_index_test.zig` and `migration_routines_test.zig`.
//!
//! The SqliteBackend's public API (see
//! `src/modules/databases/sqlite/Sqlite.zig`) is: `init`, `exec`, `query`
//! (returns `Rows` with `next()` → `?Row` carrying `values: [][]u8`).
//! Column reads go through `Row.values[i]`, which is always text.
//!
//! Plan: docs/superpowers/plans/2026-06-21-workspace-item-kanban.md (Chunk 1)

const std = @import("std");
const testing = std.testing;
const nalarcore = @import("nalarcore");
const sqlite = nalarcore.sqlite;

const migration = @import("migration.zig");
const Migration051AddKanban = migration.Migration051AddKanban;

// ─── Test helpers ─────────────────────────────────────────────────────────

/// Open a fresh in-memory sqlite DB with `workspace_items` and
/// `workspace_item_tasks` tables present (matching the schema after
/// Migrations 028 and 034), ready for Migration 051 to add the kanban
/// schema on top.
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

    // Mirror the state left by Migration 028 + 034 — same column names
    // that Migration 051's FK references and ALTER TABLE statements
    // depend on.
    try db.exec(alloc,
        "CREATE TABLE workspace_items (id TEXT PRIMARY KEY, workspace_id TEXT, item_type TEXT)",
        &.{});
    try db.exec(alloc,
        "CREATE TABLE workspace_item_tasks (id TEXT PRIMARY KEY, name TEXT, workspace_item_id TEXT)",
        &.{});

    return .{ .db = db, .threaded = threaded };
}

// ─── Test 1: kanban_columns has the expected columns ──────────────────────

test "Migration051 creates kanban_columns table with expected columns" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    try Migration051AddKanban.up(&ctx.db, alloc);

    // Assert kanban_columns exists with the expected columns in the
    // expected order. pragma_table_info orders rows by cid (column
    // ordinal), so the iteration order matches CREATE TABLE column order.
    var q = try ctx.db.query(alloc,
        "SELECT name FROM pragma_table_info('kanban_columns') ORDER BY cid",
        &.{});
    defer q.deinit();

    const expected = [_][]const u8{
        "id",
        "workspace_item_id",
        "name",
        "position",
        "created_at",
    };
    var i: usize = 0;
    while (try q.next()) |row| {
        defer row.deinit(alloc);
        try testing.expect(i < expected.len);
        try testing.expectEqualStrings(expected[i], row.values[0]);
        i += 1;
    }
    try testing.expectEqual(@as(usize, expected.len), i);
}

// ─── Test 2: workspace_item_tasks gets the two new columns ───────────────

test "Migration051 adds kanban_column_id and kanban_position to workspace_item_tasks" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    try Migration051AddKanban.up(&ctx.db, alloc);

    // Assert the two new columns are present. Sorted by name for a
    // stable assertion regardless of ALTER TABLE execution order.
    var q = try ctx.db.query(alloc,
        "SELECT name FROM pragma_table_info('workspace_item_tasks') " ++
        "WHERE name IN ('kanban_column_id', 'kanban_position') " ++
        "ORDER BY name",
        &.{});
    defer q.deinit();

    const expected = [_][]const u8{ "kanban_column_id", "kanban_position" };
    var i: usize = 0;
    while (try q.next()) |row| {
        defer row.deinit(alloc);
        try testing.expectEqualStrings(expected[i], row.values[0]);
        i += 1;
    }
    try testing.expectEqual(@as(usize, expected.len), i);
}