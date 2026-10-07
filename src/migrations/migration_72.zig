const std = @import("std");
const common = @import("common.zig");

const SqliteBackend = common.SqliteBackend;
const addColumnIfMissing = common.addColumnIfMissing;
const dropColumnIfExists = common.dropColumnIfExists;
const renameColumnIfExists = common.renameColumnIfExists;
const helpers = @import("helpers");

/// Migration 072 — Extract `kanban_column_id` + `kanban_position` from
/// `workspace_item_tasks` into a dedicated `kanban` join table.
///
/// Before: the two placement columns live on the universal
/// `workspace_item_tasks` table (alongside chat/routine/kanban task
/// attributes like `description`, `tags`, `image_urls`, `cwd`, etc.).
/// After: a new `kanban(workspace_item_task_id, kanban_column_id, kanban_position)`
/// table holds the 1:1 task-to-board placement; non-kanban tasks
/// simply have no row.
///
/// Wire format UNCHANGED — `Task.kanban_column_id` and
/// `Task.kanban_position` continue to appear on every Task JSON via
/// a `LEFT JOIN kanban k ON k.workspace_item_task_id = t.id` in list queries. The
/// frontend stores/components/SSE handlers stay byte-for-byte the
/// same.
///
/// Plan: docs/superpowers/plans/2026-08-15-extract-kanban-columns-to-kanban-table.md
/// Task: task_1786527996378 (kanban: sprint bulan juni → "move column
///   workspace_item_tasks table").
///
/// Steps (inside a single tx for atomicity — a crash mid-
/// migration would otherwise leave the DB with both new and old
/// columns populated, which the model layer's `LEFT JOIN` would
/// silently drop data from):
///   1. CREATE TABLE IF NOT EXISTS kanban (...) — fresh-DB-safe
///   2. CREATE INDEX IF NOT EXISTS idx_kanban_column_position ...
///   3. DROP INDEX IF EXISTS idx_tasks_column_position — must run
///      BEFORE the INSERT, otherwise SQLite's "database table is
///      locked" (SQLITE_LOCKED) fires because the INSERT writes to
///      a table with FKs referencing workspace_item_tasks.
///   4. INSERT OR IGNORE INTO kanban (...) SELECT … FROM
///      workspace_item_tasks WHERE kanban_column_id IS NOT NULL AND
///      kanban_column_id IN (SELECT id FROM kanban_columns) — skip
///      orphans (R8). Wrapped in a check: if the source columns are
///      already gone (re-run), skip the INSERT entirely.
///   5. DROP COLUMN kanban_column_id (dropColumnIfExists for fresh-DB
///      safety)
///   6. DROP COLUMN kanban_position
pub const Migration072ExtractKanbanTable = struct {
    pub const version: u32 = 72;
    pub const name = "extract_kanban_table";

    pub fn up(db: *SqliteBackend, allocator: std.mem.Allocator) anyerror!void {
        // Wrap in a tx (db.begin/tx.exec/tx.commit) so the CREATE+INSERT+DROP sequence is
        // atomic. Without the wrapper, SQLite auto-commits each step
        // and a crash between step 3 (backfill) and step 5 (DROP
        // COLUMN) would leave the DB with both new and old columns
        // populated.
        var tx = try db.begin();
        defer tx.commitOrRollback() catch {};
        errdefer tx.rollback() catch {};

        // Step 1: CREATE kanban (idempotent via IF NOT EXISTS)
        try tx.exec(allocator,
            \\CREATE TABLE IF NOT EXISTS kanban (
            \\    workspace_item_task_id TEXT PRIMARY KEY,
            \\    kanban_column_id       TEXT NOT NULL,
            \\    kanban_position        INTEGER NOT NULL DEFAULT 0,
            \\    FOREIGN KEY (workspace_item_task_id)
            \\        REFERENCES workspace_item_tasks(id) ON DELETE CASCADE,
            \\    FOREIGN KEY (kanban_column_id)
            \\        REFERENCES kanban_columns(id)       ON DELETE CASCADE
            \\)
        , &[_][]const u8{});

        // Step 2: per-column ordering index
        try tx.exec(allocator,
            "CREATE INDEX IF NOT EXISTS idx_kanban_column_position " ++
            "ON kanban(kanban_column_id, kanban_position)",
            &[_][]const u8{},
        );

        // Step 4: drop the per-column index on workspace_item_tasks
        // BEFORE the INSERT (which would otherwise create a pending
        // read lock on the same table via the kanban FK validation,
        // blocking the DROP). SQLite's "database table is locked"
        // (SQLITE_LOCKED) error fires when an unfinished WRITE
        // transaction is touching a table that another statement
        // (here, DROP INDEX) needs an exclusive lock on.
        try tx.exec(allocator,
            "DROP INDEX IF EXISTS idx_tasks_column_position",
            &[_][]const u8{},
        );

        // Step 3: backfill from existing data. Two filters:
        //   - `kanban_column_id IS NOT NULL` skips chat/routine/design
        //     tasks (they shouldn't be on a kanban anyway, but be
        //     defensive).
        //   - `kanban_column_id IN (SELECT id FROM kanban_columns)`
        //     skips orphan references (R8 — a task's column could
        //     have been hard-deleted before the FK existed; we don't
        //     surface unassigned rows retroactively).
        // INSERT OR IGNORE makes a re-run safe (won't crash on the
        // PRIMARY KEY collision).
        //
        // We only run the INSERT if the source columns still exist —
        // on a re-run they were already dropped by step 5/6 of the
        // first run, so the SELECT would fail with "no such column".
        // A first-run DB has the columns; a re-run DB does not.
        var check_buf: [256]u8 = undefined;
        const check_sql = std.fmt.bufPrint(
            &check_buf,
            "SELECT 1 FROM pragma_table_info('workspace_item_tasks') " ++
                "WHERE name = 'kanban_column_id'",
            .{},
        ) catch return error.BufferTooSmall;
        var q = try tx.query(allocator, check_sql, &.{});
        defer q.deinit();
        if (try q.next()) |row| {
            // Source columns still exist — first run, do the backfill.
            row.deinit(allocator);
            try tx.exec(allocator,
                \\INSERT OR IGNORE INTO kanban (workspace_item_task_id, kanban_column_id, kanban_position)
                \\SELECT t.id, t.kanban_column_id, COALESCE(t.kanban_position, 0)
                \\FROM workspace_item_tasks t
                \\WHERE t.kanban_column_id IS NOT NULL
                \\  AND t.kanban_column_id IN (SELECT id FROM kanban_columns)
            , &[_][]const u8{});
        }
        // else: re-run — backfill already happened on the first run.

        // Step 5 + 6: drop the two columns. dropColumnIfExists is the
        // safe pattern (used in Migration 052) — fresh-DB users who
        // walked the canonical schema may not have these columns if
        // we eventually move them out of the canonical CREATE TABLE.
        try dropColumnIfExists(.{ .tx = &tx }, allocator, "workspace_item_tasks", "kanban_column_id");
        try dropColumnIfExists(.{ .tx = &tx }, allocator, "workspace_item_tasks", "kanban_position");

        // Commit the transaction. After this, Migration 072 is "done"
        // and the new schema is durable.
        try tx.commit();

        // ANALYZE so the query planner sees the new index (mirrors
        // Migration 051 / 041 / 042 / 043 / 048 / 049 / 050).
        try db.exec(allocator, "ANALYZE", &[_][]const u8{});
    }
};
