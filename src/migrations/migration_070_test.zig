//! Behavioural regression checks for Migration 070
//! (`workspace_item_tasks.cwd`).
//!
//! Why this file exists
//! ────────────────────
//! Migration 070 adds a `cwd TEXT NOT NULL DEFAULT ''` column to
//! `workspace_item_tasks` so each task can carry its own cwd_session
//! (which becomes the cwd_session for that task's chat sessions).
//! Per-task cwd OVERRIDES the kanban-level path (`workspace_items.path`)
//! which OVERRIDES the per-session sandbox fallback
//! (`$TMPDIR/session_<id>/`). The chain is implemented in
//! `session_create.zig::useCase`.
//!
//! The migration must:
//!   1. Add the `cwd` column with `TEXT NOT NULL DEFAULT ''`.
//!   2. Be idempotent on re-run (re-running must not crash with
//!      "duplicate column name").
//!   3. Leave existing rows at `cwd = ''` (the canonical "no per-task
//!      cwd" sentinel — every historical task predates the feature).
//!   4. Be registered in `allMigrations` — defining the struct alone
//!      is a silent-skip bug per project memory
//!      `migration-registration-trap`.
//!
//! Plan: docs/superpowers/plans/2026-08-06-kanban-cwd-session-optional.md
//! Tasks: task_1785959915548 (kanban cwd → optional + per-task cwd picker)

const std = @import("std");
const testing = std.testing;
const sqlite = @import("nalarcore").sqlite;

const Migration070AddTaskCwd = @import("migration.zig").Migration070AddTaskCwd;

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

    // Minimal `workspace_item_tasks` schema matching the pre-Migration-070
    // shape — no `cwd` column yet (that's exactly what the migration adds).
    // Production walks migrations 001 → 069 first, so `description`
    // (Migration 062), `tags` (Migration 067), and `image_urls`
    // (Migration 069) are already there; we include them so the
    // migration's addColumnIfMissing succeeds and the schema mirrors
    // what real production rows look like.
    try db.exec(alloc,
        \\CREATE TABLE workspace_item_tasks (
        \\    id TEXT PRIMARY KEY,
        \\    name TEXT NOT NULL,
        \\    workspace_item_id TEXT NOT NULL,
        \\    task_type TEXT NOT NULL DEFAULT 'standard',
        \\    description TEXT NOT NULL DEFAULT '',
        \\    tags TEXT NOT NULL DEFAULT '',
        \\    image_urls TEXT NOT NULL DEFAULT ''
        \\)
    , &.{});
    // Minimal `workspace_items` table so the FK target exists for
    // round-trip tests that need to INSERT a parent row first.
    // Production walks migrations 001 → 069 first, so this table is
    // always there; the test mirrors that.
    try db.exec(alloc,
        \\CREATE TABLE workspace_items (
        \\    id TEXT PRIMARY KEY,
        \\    workspace_id TEXT NOT NULL,
        \\    item_type TEXT NOT NULL
        \\)
    , &.{});
    return .{ .db = db, .threaded = threaded };
}

test "Migration070 adds cwd column to workspace_item_tasks" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    // Sanity: column does NOT exist before the migration.
    {
        var q = try ctx.db.query(alloc,
            \\SELECT 1 FROM pragma_table_info('workspace_item_tasks')
            \\WHERE name = 'cwd'
        , &.{});
        defer q.deinit();
        try testing.expect((try q.next()) == null);
    }

    // Apply the migration.
    try Migration070AddTaskCwd.up(&ctx.db, alloc);

    // Confirm the column exists with the expected name.
    var q = try ctx.db.query(alloc,
        \\SELECT name FROM pragma_table_info('workspace_item_tasks')
        \\WHERE name = 'cwd'
    , &.{});
    defer q.deinit();
    const row = (try q.next()) orelse return error.ColumnMissing;
    defer row.deinit(alloc);
    try testing.expectEqualStrings("cwd", row.values[0]);

    // Type + nullability + default sanity: the column must be
    // TEXT NOT NULL DEFAULT '' (the canonical "no per-task cwd" sentinel
    // — matches the `description` / `tags` / `image_urls` patterns from
    // Migrations 062 / 067 / 069).
    var qt = try ctx.db.query(alloc,
        \\SELECT type, "notnull", dflt_value
        \\FROM pragma_table_info('workspace_item_tasks')
        \\WHERE name = 'cwd'
    , &.{});
    defer qt.deinit();
    const type_row = (try qt.next()) orelse return error.RowMissing;
    defer type_row.deinit(alloc);
    try testing.expectEqualStrings("TEXT", type_row.values[0]);
    // "notnull" is 1 when NOT NULL.
    try testing.expectEqualStrings("1", type_row.values[1]);
    // Default value is the SQL `''` literal (the canonical "no
    // per-task cwd" sentinel). `pragma_table_info` reports it as the
    // SQL literal text (i.e. `''` with the single quotes — same pattern
    // as the other NOT NULL DEFAULT '' columns). Accept either the bare
    // empty string or the single-quoted empty-string literal — both
    // represent the same semantic default.
    const dflt = type_row.values[2];
    try testing.expect(dflt.len == 0 or std.mem.eql(u8, dflt, "''"));
}

test "Migration070 is idempotent on a re-run" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    // Run the migration once…
    try Migration070AddTaskCwd.up(&ctx.db, alloc);
    // …and a second time. Must not crash with "duplicate column name".
    try Migration070AddTaskCwd.up(&ctx.db, alloc);

    // Still exactly one cwd column.
    var q = try ctx.db.query(alloc,
        \\SELECT COUNT(*) FROM pragma_table_info('workspace_item_tasks')
        \\WHERE name = 'cwd'
    , &.{});
    defer q.deinit();
    const row = (try q.next()) orelse return error.RowMissing;
    defer row.deinit(alloc);
    try testing.expectEqualStrings("1", row.values[0]);
}

test "Migration070 leaves pre-existing rows at cwd='' (the no-per-task-cwd sentinel)" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    // Insert one existing row BEFORE applying the migration. Every
    // historical task predates the feature; the migration MUST
    // backfill cwd = '' for every row (the column has NOT NULL
    // DEFAULT '' and ADD COLUMN applies DEFAULT to existing rows at
    // the storage layer).
    try ctx.db.exec(alloc,
        "INSERT INTO workspace_item_tasks (id, name, workspace_item_id) " ++
            "VALUES ('task_pre_070', 'Pre-existing task', 'item_1')",
        &.{});

    try Migration070AddTaskCwd.up(&ctx.db, alloc);

    var q = try ctx.db.query(alloc,
        "SELECT cwd FROM workspace_item_tasks WHERE id = 'task_pre_070'",
        &.{});
    defer q.deinit();
    const row = (try q.next()) orelse return error.RowMissing;
    defer row.deinit(alloc);
    try testing.expectEqualStrings("", row.values[0]);
}

test "Migration070 round-trips a per-task cwd path" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    try Migration070AddTaskCwd.up(&ctx.db, alloc);

    // Insert a task with an absolute path on disk as its per-task cwd.
    // Confirm the raw string round-trips — the column stores bytes
    // verbatim, the resolution chain (task.cwd → item.path → sandbox)
    // is the caller's responsibility.
    const cwd_path = "/home/me/projects/repo-A";
    try ctx.db.exec(alloc,
        "INSERT INTO workspace_item_tasks (id, name, workspace_item_id, cwd) " ++
            "VALUES ('task_cwd', 'Per-task cwd task', 'item_1', ?)",
        &[_][]const u8{cwd_path});

    var q = try ctx.db.query(alloc,
        "SELECT cwd FROM workspace_item_tasks WHERE id = 'task_cwd'",
        &.{});
    defer q.deinit();
    const row = (try q.next()) orelse return error.RowMissing;
    defer row.deinit(alloc);
    try testing.expectEqualStrings(cwd_path, row.values[0]);
}

test "Migration070 is registered in allMigrations" {
    // Catches the silent-skip regression where the struct is defined
    // but the registration tuple is missing (per project memory
    // `migration-registration-trap`). Search the slice by version
    // number so the test stays stable across reordering.
    const all = @import("migration.zig").allMigrations;
    for (all) |m| {
        if (m.version == Migration070AddTaskCwd.version) return;
    }
    return error.Migration070NotRegistered;
}

// ─── createWorkspaceItemTask round-trip tests (Migration 070) ───────────
//
// These tests exercise the model's createWorkspaceItemTask function
// (the canonical INSERT path for new tasks) to lock in the contract:
// the new `cwd` arg must (a) be accepted as the 10th parameter,
// (b) store the supplied path verbatim, and (c) default to '' when
// the caller passes null (matches the description / tags / image_urls
// pattern).

const createWorkspaceItemTask = @import("nalarcore").ai_mod.llm_history.createWorkspaceItemTask;

test "createWorkspaceItemTask: cwd = '/home/me/proj-A' round-trips verbatim" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();
    try Migration070AddTaskCwd.up(&ctx.db, alloc);

    const parent_id = try insertWorkspaceItem(&ctx, alloc, "item_001");

    const task = try createWorkspaceItemTask(
        alloc,
        &ctx.db,
        "t_cwd_001",
        "Task with cwd",
        parent_id,
        "standard",
        null, // description
        null, // tags
        null, // image_urls
        "/home/me/proj-A", // cwd (Migration 070 10th arg)
    );
    defer task.deinit(alloc);

    try testing.expectEqualStrings("/home/me/proj-A", task.cwd);

    // Read back from DB to verify persistence.
    var q = try ctx.db.query(alloc,
        "SELECT cwd FROM workspace_item_tasks WHERE id = 't_cwd_001'",
        &.{});
    defer q.deinit();
    const row = (try q.next()) orelse return error.RowMissing;
    defer row.deinit(alloc);
    try testing.expectEqualStrings("/home/me/proj-A", row.values[0]);
}

test "createWorkspaceItemTask: cwd = '' stores '' (SQL '' literal, NOT NULL DEFAULT '')" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();
    try Migration070AddTaskCwd.up(&ctx.db, alloc);

    const parent_id = try insertWorkspaceItem(&ctx, alloc, "item_002");

    // Empty-string cwd — must use the SQL '' literal branch (NOT
    // bind via `?`, which would NULL-bind and fail NOT NULL).
    const task = try createWorkspaceItemTask(
        alloc,
        &ctx.db,
        "t_cwd_002",
        "Task with empty cwd",
        parent_id,
        "standard",
        null,
        null,
        null,
        "", // cwd
    );
    defer task.deinit(alloc);

    try testing.expectEqualStrings("", task.cwd);

    var q = try ctx.db.query(alloc,
        "SELECT cwd FROM workspace_item_tasks WHERE id = 't_cwd_002'",
        &.{});
    defer q.deinit();
    const row = (try q.next()) orelse return error.RowMissing;
    defer row.deinit(alloc);
    try testing.expectEqualStrings("", row.values[0]);
}

test "createWorkspaceItemTask: cwd = null omits column (DEFAULT '' applies)" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();
    try Migration070AddTaskCwd.up(&ctx.db, alloc);

    const parent_id = try insertWorkspaceItem(&ctx, alloc, "item_003");

    // null cwd — column omitted from INSERT, DEFAULT '' applies.
    const task = try createWorkspaceItemTask(
        alloc,
        &ctx.db,
        "t_cwd_003",
        "Task with null cwd",
        parent_id,
        "standard",
        null,
        null,
        null,
        null, // cwd — omitted, DEFAULT '' fills in
    );
    defer task.deinit(alloc);

    try testing.expectEqualStrings("", task.cwd);

    var q = try ctx.db.query(alloc,
        "SELECT cwd FROM workspace_item_tasks WHERE id = 't_cwd_003'",
        &.{});
    defer q.deinit();
    const row = (try q.next()) orelse return error.RowMissing;
    defer row.deinit(alloc);
    try testing.expectEqualStrings("", row.values[0]);
}

// Helper for the round-trip tests above — inserts a minimal
// workspace_item row so the FK constraint on
// workspace_item_tasks.workspace_item_id is satisfied. Returns
// the input slice borrowed from the caller's stack — caller MUST
// NOT free it.
fn insertWorkspaceItem(
    ctx: *TestCtx,
    alloc: std.mem.Allocator,
    item_id: []const u8,
) ![]const u8 {
    try ctx.db.exec(alloc,
        \\INSERT INTO workspace_items (id, workspace_id, item_type)
        \\VALUES (?, 'ws_test', 'kanban')
    , &.{item_id});
    // Borrow the input — caller owns the backing memory (the
    // literal `"item_001"` lives in the test function's stack
    // frame; the test ends before the literal's lifetime ends).
    return item_id;
}
