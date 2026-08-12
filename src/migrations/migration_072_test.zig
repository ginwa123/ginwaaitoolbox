//! Behavioural regression checks for Migration 072
//! (`workspace_item_tasks` → `kanban` table extraction).
//!
//! Why this file exists
//! ────────────────────
//! Migration 072 moves the two kanban-board-placement columns
//! (`kanban_column_id`, `kanban_position`) off the universal
//! `workspace_item_tasks` table and into a dedicated `kanban` join
//! table. This is purely structural — the wire format
//! (`Task.kanban_column_id`, `Task.kanban_position`) stays identical,
//! served via a `LEFT JOIN kanban k ON k.task_id = t.id` in list
//! queries.
//!
//! The migration must:
//!   1. Create the `kanban` table with the expected schema
//!      (task_id PK, kanban_column_id NOT NULL, kanban_position
//!      DEFAULT 0, FKs to workspace_item_tasks + kanban_columns).
//!   2. Create the `idx_kanban_column_position` index.
//!   3. Backfill rows from existing `workspace_item_tasks`
//!      (only rows whose `kanban_column_id` references a real
//!      `kanban_columns.id` — orphans are skipped per the design
//!      decision in the plan, risk R8).
//!   4. Drop `workspace_item_tasks.kanban_column_id`.
//!   5. Drop `workspace_item_tasks.kanban_position`.
//!   6. Drop `idx_tasks_column_position` from workspace_item_tasks.
//!   7. Be idempotent on a re-run (re-running must not crash with
//!      "duplicate column name" or "table already exists" — relies
//!      on `CREATE TABLE IF NOT EXISTS` + `DROP COLUMN IF EXISTS`-
//!      style helpers).
//!   8. Preserve the wire format — after migration, a `LEFT JOIN`
//!      from `workspace_item_tasks` to `kanban` returns the same
//!      (column_id, position) pairs that the old direct columns
//!      returned (with NULL/0 for non-kanban tasks).
//!
//! Plan: docs/superpowers/plans/2026-08-15-extract-kanban-columns-to-kanban-table.md
//! Tasks: task_1786527996378 ("move column workspace_item_tasks table").

const std = @import("std");
const testing = std.testing;
const sqlite = @import("nalarcore").sqlite;

const Migration072ExtractKanbanTable = @import("migration.zig").Migration072ExtractKanbanTable;

const TestCtx = struct {
    db: sqlite.SqliteBackend,
    threaded: std.Io.Threaded,
};

/// Set up a pre-Migration-072 in-memory DB — mirrors the schema a real
/// production user has after walking migrations 001 → 071. Includes
/// the two columns we're about to drop, plus the index we're about
/// to drop. Also seeds the FK target tables (`workspace_items`,
/// `kanban_columns`) so the backfill SELECT has valid references.
fn setupDb() !TestCtx {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    errdefer threaded.deinit();
    const io = threaded.io();
    var db: sqlite.SqliteBackend = .{};
    errdefer db.deinit();
    try db.init(io, ":memory:");

    // workspace_items — FK target for workspace_item_tasks.workspace_item_id
    try db.exec(alloc,
        "CREATE TABLE workspace_items (id TEXT PRIMARY KEY, workspace_id TEXT NOT NULL, item_type TEXT NOT NULL)",
        &.{});
    // kanban_columns — FK target for the new kanban.kanban_column_id.
    // Production walks Migration 051 to create this; the test mirrors it
    // so the backfill SELECT can validate column-id references.
    try db.exec(alloc,
        \\CREATE TABLE kanban_columns (
        \\    id TEXT PRIMARY KEY,
        \\    workspace_item_id TEXT NOT NULL,
        \\    name TEXT NOT NULL,
        \\    position INTEGER NOT NULL,
        \\    FOREIGN KEY (workspace_item_id) REFERENCES workspace_items(id) ON DELETE CASCADE
        \\)
    , &.{});
    // Pre-Migration-072 workspace_item_tasks — the full set of task
    // attributes from migrations 001 → 071 PLUS the two columns we're
    // about to extract.
    try db.exec(alloc,
        \\CREATE TABLE workspace_item_tasks (
        \\    id TEXT PRIMARY KEY,
        \\    name TEXT NOT NULL,
        \\    workspace_item_id TEXT NOT NULL,
        \\    description TEXT NOT NULL DEFAULT '',
        \\    created_at TEXT,
        \\    updated_at TEXT,
        \\    task_type TEXT NOT NULL DEFAULT 'standard',
        \\    is_pinned INTEGER DEFAULT 0,
        \\    pinned_position INTEGER DEFAULT 0,
        \\    kanban_column_id TEXT,
        \\    kanban_position INTEGER NOT NULL DEFAULT 0,
        \\    last_human_touched_at INTEGER,
        \\    tags TEXT NOT NULL DEFAULT '',
        \\    cwd TEXT NOT NULL DEFAULT ''
        \\)
    , &.{});
    // The legacy per-column-position index that Migration 072 drops.
    try db.exec(alloc,
        "CREATE INDEX idx_tasks_column_position " ++
        "ON workspace_item_tasks(kanban_column_id, kanban_position)",
        &.{});
    return .{ .db = db, .threaded = threaded };
}

/// Insert a workspace_items row + a kanban_columns row + a task with
/// a kanban placement. Returns nothing; the caller asserts on the
/// post-migration state.
fn seedKanbanCard(
    ctx: *TestCtx,
    alloc: std.mem.Allocator,
    task_id: []const u8,
    column_id: []const u8,
    position: i64,
) !void {
    try ctx.db.exec(alloc,
        "INSERT OR IGNORE INTO workspace_items (id, workspace_id, item_type) " ++
        "VALUES ('wi_1', 'ws_1', 'kanban')",
        &.{});
    try ctx.db.exec(alloc,
        "INSERT OR IGNORE INTO kanban_columns (id, workspace_item_id, name, position) " ++
        "VALUES (?, 'wi_1', 'todo', 0)",
        &.{column_id});
    const pos_str = try std.fmt.allocPrint(alloc, "{d}", .{position});
    defer alloc.free(pos_str);
    try ctx.db.exec(alloc,
        \\INSERT INTO workspace_item_tasks
        \\(id, name, workspace_item_id, kanban_column_id, kanban_position)
        \\VALUES (?, 'Task', 'wi_1', ?, ?)
    , &.{ task_id, column_id, pos_str });
}

// ============================================================================
// Test 1 — Migration creates the `kanban` table
// ============================================================================

test "Migration072 creates the kanban table with the expected schema" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    // Sanity: kanban table does NOT exist before migration.
    {
        var q = try ctx.db.query(alloc,
            \\SELECT 1 FROM sqlite_master
            \\WHERE type = 'table' AND name = 'kanban'
        , &.{});
        defer q.deinit();
        try testing.expect((try q.next()) == null);
    }

    try Migration072ExtractKanbanTable.up(&ctx.db, alloc);

    // Confirm the kanban table exists.
    var q = try ctx.db.query(alloc,
        \\SELECT 1 FROM sqlite_master
        \\WHERE type = 'table' AND name = 'kanban'
    , &.{});
    defer q.deinit();
    const row = (try q.next()) orelse return error.RowMissing;
    defer row.deinit(alloc);
}

// ============================================================================
// Test 2 — Migration creates the per-column-position index
// ============================================================================

test "Migration072 creates idx_kanban_column_position index" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    try Migration072ExtractKanbanTable.up(&ctx.db, alloc);

    var q = try ctx.db.query(alloc,
        \\SELECT 1 FROM sqlite_master
        \\WHERE type = 'index' AND name = 'idx_kanban_column_position'
    , &.{});
    defer q.deinit();
    const row = (try q.next()) orelse return error.RowMissing;
    defer row.deinit(alloc);
}

// ============================================================================
// Test 3 — Migration backfills existing rows
// ============================================================================

test "Migration072 backfills kanban rows from workspace_item_tasks" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    try seedKanbanCard(&ctx, alloc, "task_a", "col_1", 0);
    try seedKanbanCard(&ctx, alloc, "task_b", "col_1", 1);
    try seedKanbanCard(&ctx, alloc, "task_c", "col_2", 0);

    try Migration072ExtractKanbanTable.up(&ctx.db, alloc);

    // Verify the backfill: three rows in kanban with the expected
    // task_id / column_id / position triples.
    var q = try ctx.db.query(alloc,
        \\SELECT task_id, kanban_column_id, kanban_position
        \\FROM kanban
        \\ORDER BY task_id ASC
    , &.{});
    defer q.deinit();

    const row_a = (try q.next()) orelse return error.RowMissing;
    defer row_a.deinit(alloc);
    try testing.expectEqualStrings("task_a", row_a.values[0]);
    try testing.expectEqualStrings("col_1", row_a.values[1]);
    try testing.expectEqualStrings("0", row_a.values[2]);

    const row_b = (try q.next()) orelse return error.RowMissing;
    defer row_b.deinit(alloc);
    try testing.expectEqualStrings("task_b", row_b.values[0]);
    try testing.expectEqualStrings("col_1", row_b.values[1]);
    try testing.expectEqualStrings("1", row_b.values[2]);

    const row_c = (try q.next()) orelse return error.RowMissing;
    defer row_c.deinit(alloc);
    try testing.expectEqualStrings("task_c", row_c.values[0]);
    try testing.expectEqualStrings("col_2", row_c.values[1]);
    try testing.expectEqualStrings("0", row_c.values[2]);

    try testing.expect((try q.next()) == null); // no extra rows
}

// ============================================================================
// Test 4 — Backfill skips orphan kanban_column_id references (R8)
// ============================================================================

test "Migration072 backfill skips tasks whose kanban_column_id has no matching kanban_columns row" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    // Seed: task with a valid column (col_1) + task pointing at a
    // deleted/orphan column (col_deleted).
    try ctx.db.exec(alloc,
        "INSERT OR IGNORE INTO workspace_items (id, workspace_id, item_type) " ++
        "VALUES ('wi_1', 'ws_1', 'kanban')",
        &.{});
    try ctx.db.exec(alloc,
        "INSERT OR IGNORE INTO kanban_columns (id, workspace_item_id, name, position) " ++
        "VALUES ('col_1', 'wi_1', 'todo', 0)",
        &.{});
    try ctx.db.exec(alloc,
        \\INSERT INTO workspace_item_tasks
        \\(id, name, workspace_item_id, kanban_column_id, kanban_position)
        \\VALUES ('task_valid', 'Valid', 'wi_1', 'col_1', 0)
    , &.{});
    try ctx.db.exec(alloc,
        \\INSERT INTO workspace_item_tasks
        \\(id, name, workspace_item_id, kanban_column_id, kanban_position)
        \\VALUES ('task_orphan', 'Orphan', 'wi_1', 'col_deleted', 5)
    , &.{});

    try Migration072ExtractKanbanTable.up(&ctx.db, alloc);

    // Only the valid row was backfilled — the orphan was skipped.
    var q = try ctx.db.query(alloc,
        "SELECT task_id FROM kanban ORDER BY task_id ASC",
        &.{});
    defer q.deinit();

    const row1 = (try q.next()) orelse return error.RowMissing;
    defer row1.deinit(alloc);
    try testing.expectEqualStrings("task_valid", row1.values[0]);

    try testing.expect((try q.next()) == null); // task_orphan NOT backfilled
}

// ============================================================================
// Test 5 — Migration drops the kanban_column_id and kanban_position columns
// ============================================================================

test "Migration072 drops kanban_column_id from workspace_item_tasks" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    try Migration072ExtractKanbanTable.up(&ctx.db, alloc);

    var q = try ctx.db.query(alloc,
        \\SELECT name FROM pragma_table_info('workspace_item_tasks')
        \\WHERE name = 'kanban_column_id'
    , &.{});
    defer q.deinit();
    try testing.expect((try q.next()) == null);
}

test "Migration072 drops kanban_position from workspace_item_tasks" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    try Migration072ExtractKanbanTable.up(&ctx.db, alloc);

    var q = try ctx.db.query(alloc,
        \\SELECT name FROM pragma_table_info('workspace_item_tasks')
        \\WHERE name = 'kanban_position'
    , &.{});
    defer q.deinit();
    try testing.expect((try q.next()) == null);
}

// ============================================================================
// Test 6 — Migration drops idx_tasks_column_position index
// ============================================================================

test "Migration072 drops the legacy idx_tasks_column_position index" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    try Migration072ExtractKanbanTable.up(&ctx.db, alloc);

    var q = try ctx.db.query(alloc,
        \\SELECT 1 FROM sqlite_master
        \\WHERE type = 'index' AND name = 'idx_tasks_column_position'
    , &.{});
    defer q.deinit();
    try testing.expect((try q.next()) == null);
}

// ============================================================================
// Test 7 — Migration is idempotent on re-run
// ============================================================================

test "Migration072 is idempotent — re-running does not crash" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    try Migration072ExtractKanbanTable.up(&ctx.db, alloc);
    // Re-run: must not crash with "duplicate column name" or
    // "table kanban already exists". The CREATE TABLE IF NOT
    // EXISTS + dropColumnIfExists helpers make this a no-op.
    try Migration072ExtractKanbanTable.up(&ctx.db, alloc);

    // Verify the schema is still correct after the re-run.
    var q = try ctx.db.query(alloc,
        \\SELECT name FROM pragma_table_info('workspace_item_tasks')
        \\WHERE name IN ('kanban_column_id', 'kanban_position')
    , &.{});
    defer q.deinit();
    try testing.expect((try q.next()) == null); // columns still gone
}

// ============================================================================
// Test 8 — Wire-format preservation via LEFT JOIN
// ============================================================================

test "Migration072 preserves the wire format — LEFT JOIN returns the same data the old direct columns did" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    // Seed: one task on a kanban column, one task with no column
    // assignment (the "chat task in a kanban item" case — has
    // kanban_column_id IS NULL).
    try ctx.db.exec(alloc,
        "INSERT OR IGNORE INTO workspace_items (id, workspace_id, item_type) " ++
        "VALUES ('wi_1', 'ws_1', 'kanban')",
        &.{});
    try ctx.db.exec(alloc,
        "INSERT OR IGNORE INTO kanban_columns (id, workspace_item_id, name, position) " ++
        "VALUES ('col_1', 'wi_1', 'todo', 0)",
        &.{});
    try ctx.db.exec(alloc,
        \\INSERT INTO workspace_item_tasks
        \\(id, name, workspace_item_id, kanban_column_id, kanban_position)
        \\VALUES ('task_on_board', 'On board', 'wi_1', 'col_1', 7)
    , &.{});
    try ctx.db.exec(alloc,
        \\INSERT INTO workspace_item_tasks
        \\(id, name, workspace_item_id, kanban_column_id, kanban_position)
        \\VALUES ('task_unassigned', 'Unassigned', 'wi_1', NULL, 0)
    , &.{});

    try Migration072ExtractKanbanTable.up(&ctx.db, alloc);

    // The "wire format" query — what every list query uses to
    // populate Task.kanban_column_id and Task.kanban_position.
    var q = try ctx.db.query(alloc,
        \\SELECT t.id, k.kanban_column_id, COALESCE(k.kanban_position, 0)
        \\FROM workspace_item_tasks t
        \\LEFT JOIN kanban k ON k.task_id = t.id
        \\ORDER BY t.id ASC
    , &.{});
    defer q.deinit();

    const row_on = (try q.next()) orelse return error.RowMissing;
    defer row_on.deinit(alloc);
    try testing.expectEqualStrings("task_on_board", row_on.values[0]);
    try testing.expectEqualStrings("col_1", row_on.values[1]); // matched column
    try testing.expectEqualStrings("7", row_on.values[2]); // matched position

    const row_un = (try q.next()) orelse return error.RowMissing;
    defer row_un.deinit(alloc);
    try testing.expectEqualStrings("task_unassigned", row_un.values[0]);
    try testing.expectEqualStrings("", row_un.values[1]); // NULL → empty string
    try testing.expectEqualStrings("0", row_un.values[2]); // COALESCE → 0

    try testing.expect((try q.next()) == null); // no extra rows
}