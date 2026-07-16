//! Static regression checks for Migration 061
//! (workspace_item_tasks.description).
//!
//! Why this file exists
//! ────────────────────
//! Migration 061 introduces a free-form `description` column on
//! `workspace_item_tasks` so each task (chat / routine / kanban) can
//! carry a user-visible "notes" field alongside its display name.
//! The detail dialog (frontend, Chunk 2) reads and writes it; the
//! backend persists it. The migration must:
//!   1. Add `description TEXT NOT NULL DEFAULT ''` to the table
//!   2. Be idempotent (existing rows survive via DEFAULT '')
//!   3. Be safe for fresh-DB installs that already declare the column
//!      in their canonical CREATE TABLE — use `addColumnIfMissing`
//!      so the helper handles both fresh-DB and upgrade-from-v1 paths
//!      gracefully (see memory `nalar-fresh-db-migration-cascade`).
//!
//! Plan: docs/superpowers/plans/2026-07-16-kanban-task-detail-dialog.md
//!   (Chunk 1, Task 1.1)

const std = @import("std");
const testing = std.testing;
const sqlite = @import("nalarcore").sqlite;
const Migration061 = @import("migration.zig").Migration061AddTaskDescription;

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
    // workspace_items (FK target for workspace_item_tasks.workspace_item_id)
    // and workspace_item_tasks itself must exist before migration 061
    // can run — production walks migrations 001 → 061 in order, so by
    // the time 061 runs they're already there. We create minimal
    // mirrors here for the unit test.
    try db.exec(alloc,
        "CREATE TABLE workspace_items (id TEXT PRIMARY KEY, workspace_id TEXT, item_type TEXT)",
        &.{});
    try db.exec(alloc,
        "CREATE TABLE workspace_item_tasks (id TEXT PRIMARY KEY, name TEXT, workspace_item_id TEXT)",
        &.{});
    return .{ .db = db, .threaded = threaded };
}

test "Migration061 adds description column to workspace_item_tasks" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    // Sanity: description does NOT exist before the migration.
    {
        var q = try ctx.db.query(alloc,
            \\SELECT 1 FROM pragma_table_info('workspace_item_tasks')
            \\WHERE name = 'description'
        , &.{});
        defer q.deinit();
        try testing.expect((try q.next()) == null);
    }

    // Apply migration 061.
    try Migration061.up(&ctx.db, alloc);

    // Confirm the column exists with the expected name.
    var q = try ctx.db.query(alloc,
        \\SELECT name FROM pragma_table_info('workspace_item_tasks')
        \\WHERE name = 'description'
    , &.{});
    defer q.deinit();
    const row = (try q.next()) orelse return error.ColumnMissing;
    defer row.deinit(alloc);
    try testing.expectEqualStrings("description", row.values[0]);

    // Confirm there are no extra rows (i.e. only one match).
    try testing.expect((try q.next()) == null);
}

test "Migration061 is idempotent on a column that already exists" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    // Simulate a fresh-DB install where the canonical CREATE TABLE
    // already includes `description TEXT NOT NULL DEFAULT ''`. The
    // migration must be a no-op (NOT a "duplicate column" crash).
    // Drop the minimal table from setupDb() and re-create it with the
    // canonical schema that already declares description.
    try ctx.db.exec(alloc, "DROP TABLE workspace_item_tasks", &.{});
    try ctx.db.exec(alloc,
        \\CREATE TABLE workspace_item_tasks (
        \\    id TEXT PRIMARY KEY,
        \\    name TEXT,
        \\    workspace_item_id TEXT,
        \\    description TEXT NOT NULL DEFAULT ''
        \\)
    , &.{});

    // Should not error — `addColumnIfMissing` detects the column
    // already exists and short-circuits.
    try Migration061.up(&ctx.db, alloc);

    // Re-check: still one `description` column (no duplicates).
    var q = try ctx.db.query(alloc,
        \\SELECT COUNT(*) FROM pragma_table_info('workspace_item_tasks')
        \\WHERE name = 'description'
    , &.{});
    defer q.deinit();
    const row = (try q.next()) orelse return error.RowMissing;
    defer row.deinit(alloc);
    try testing.expectEqualStrings("1", row.values[0]);
}

test "Migration061 gives pre-existing rows an empty-string description" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    // Insert one existing task (no description column yet — it's
    // added by the migration).
    try ctx.db.exec(alloc,
        "INSERT INTO workspace_items (id, workspace_id, item_type) " ++
        "VALUES ('wi_1', 'ws_1', 'chat')",
        &.{});
    try ctx.db.exec(alloc,
        "INSERT INTO workspace_item_tasks (id, name, workspace_item_id) " ++
        "VALUES ('task_pre_061', 'Task', 'wi_1')",
        &.{});

    // Apply migration 061 — the existing row should get description=''.
    try Migration061.up(&ctx.db, alloc);

    var q = try ctx.db.query(alloc,
        "SELECT description FROM workspace_item_tasks WHERE id = 'task_pre_061'",
        &.{});
    defer q.deinit();
    const row = (try q.next()) orelse return error.RowMissing;
    defer row.deinit(alloc);
    try testing.expectEqualStrings("", row.values[0]);
}
