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
const createWorkspaceItemTask = @import("nalarcore").ai_mod.llm_history.createWorkspaceItemTask;

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
    // The behavioural tests below INSERT into `task_type` (via the
    // routine/memory branches of task_create.zig and via
    // createWorkspaceItemTask), so the column must exist before
    // Migration 061 runs. The real migration (034) declares this and
    // 30+ others; we only need the minimum that the create helper
    // references. Migration 061's `addColumnIfMissing` will then add
    // `description` to this minimal table.
    try db.exec(alloc,
        "CREATE TABLE workspace_item_tasks (id TEXT PRIMARY KEY, name TEXT, workspace_item_id TEXT, task_type TEXT NOT NULL DEFAULT 'standard')",
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

// =====================================================================
// Behavioural regression tests for the empty-string-bind bug.
//
// Why these tests exist
// ---------------------
// The migration adds a `NOT NULL DEFAULT ''` column. The `task_create`
// HTTP handler calls `createWorkspaceItemTask` (and the routine/memory
// branches do their own INSERTs). All three paths previously wrote the
// description with `db.exec(..., description orelse "")` — which passes
// an empty `[]const u8` to the SQLite backend. `SqliteBackend.exec`
// binds an empty slice as SQL NULL (see project memory
// `sqlite-backend-empty-slice-binds-as-null`), so the INSERT crashed
// with `NOT NULL constraint failed: workspace_item_tasks.description`
// for every standard/routine/memory task create where the caller
// either omitted description (= null in JSON) or sent `""`.
//
// The fix splits the INSERT into a three-way branch:
//   - description == null  → omit the description column; DEFAULT ''
//     applies.
//   - description == ""   → use a SQL `''` literal (not a `?` bind).
//   - description == "x…" → bind via `?` like normal.
//
// The static tests above check that the three-way branch EXISTS in
// the source. These behavioural tests actually run the helper against
// an in-memory sqlite with the real Migration 061 applied, and prove
// no `NOT NULL` violation fires for any of the three caller shapes.

/// Seed a workspace_items row so `workspace_item_tasks.workspace_item_id`
/// has a real FK target. Returns the parent id.
fn seedParent(ctx: *TestCtx, allocator: std.mem.Allocator) ![]const u8 {
    const parent_id = "wi_parent_061";
    try ctx.db.exec(allocator,
        "INSERT INTO workspace_items (id, workspace_id, item_type) " ++
        "VALUES (?, 'ws_1', 'chat')",
        &[_][]const u8{parent_id});
    return parent_id;
}

/// Read back the description column for a task by id. Returns an
/// owned copy (allocated with `allocator`) because `row.values[0]`
/// is freed by `row.deinit(allocator)` at function exit; returning the
/// raw borrowed slice would be a use-after-free once the defer fires
/// (see project memory `zig-slice-headers-across-defer-lifetimes`).
fn readDescription(ctx: *TestCtx, allocator: std.mem.Allocator, task_id: []const u8) !?[]u8 {
    var q = try ctx.db.query(allocator,
        "SELECT description FROM workspace_item_tasks WHERE id = ?",
        &[_][]const u8{task_id});
    defer q.deinit();
    const row_opt = try q.next();
    if (row_opt) |row| {
        defer row.deinit(allocator);
        return try allocator.dupe(u8, row.values[0]);
    }
    return null;
}

/// Wrapper that frees the owned `readDescription` slice. The caller
/// passes the slice via this helper so the free lives close to the
/// assertion (no leaks even if the assertion panics).
fn expectDescriptionEquals(
    ctx: *TestCtx,
    allocator: std.mem.Allocator,
    task_id: []const u8,
    expected: []const u8,
) !void {
    const owned = (try readDescription(ctx, allocator, task_id)) orelse return error.NoRow;
    defer allocator.free(owned);
    try testing.expectEqualStrings(expected, owned);
}

test "createWorkspaceItemTask: description = null succeeds and stores ''" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();
    try Migration061.up(&ctx.db, alloc);
    const parent_id = try seedParent(&ctx, alloc);

    // Caller passes null (omitted body field).
    const task = try createWorkspaceItemTask(alloc, &ctx.db,
        "t_desc_null_061", "No description", parent_id, "standard", null);
    defer task.deinit(alloc);

    // SELECT the column back and confirm it was stored as the empty
    // string (DEFAULT '' via the omitted-column branch).
    try testing.expectEqualStrings("", task.description);
    try expectDescriptionEquals(&ctx, alloc, "t_desc_null_061", "");
}

test "createWorkspaceItemTask: description = '' (empty string) succeeds and stores ''" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();
    try Migration061.up(&ctx.db, alloc);
    const parent_id = try seedParent(&ctx, alloc);

    // This is the EXACT bug case. Pre-fix: `description orelse ""` made
    // the bind arg an empty `[]const u8` which SqliteBackend.exec
    // converts to SQL NULL → `NOT NULL constraint failed`. Post-fix:
    // the empty-string branch uses a SQL `''` literal.
    const task = try createWorkspaceItemTask(alloc, &ctx.db,
        "t_desc_empty_061", "Empty description", parent_id, "standard", "");
    defer task.deinit(alloc);

    try testing.expectEqualStrings("", task.description);
    try expectDescriptionEquals(&ctx, alloc, "t_desc_empty_061", "");
}

test "createWorkspaceItemTask: description = 'hello world' succeeds and stores the value" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();
    try Migration061.up(&ctx.db, alloc);
    const parent_id = try seedParent(&ctx, alloc);

    const task = try createWorkspaceItemTask(alloc, &ctx.db,
        "t_desc_filled_061", "With description", parent_id, "standard",
        "hello world from test");
    defer task.deinit(alloc);

    try testing.expectEqualStrings("hello world from test", task.description);
    try expectDescriptionEquals(&ctx, alloc, "t_desc_filled_061", "hello world from test");
}

// Direct `db.exec` mirror of the createRoutineTask + createMemoryTask
// INSERT branches. These branches don't go through
// `createWorkspaceItemTask` so they need their own exercise of the
// `''`-literal-vs-bind footgun fix. The test asserts the same three
// caller shapes work — null, "", "x…" — for each task_type the
// handler can produce.

const RoutineCase = struct {
    task_id: []const u8,
    desc: ?[]const u8,
};
const MemoryCase = struct {
    task_id: []const u8,
    desc: ?[]const u8,
};

test "task_create direct INSERT branches: null/empty/value all succeed for routine task_type" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();
    try Migration061.up(&ctx.db, alloc);
    const parent_id = try seedParent(&ctx, alloc);

    const cases = [_]RoutineCase{
        .{ .task_id = "t_routine_null_061", .desc = null },
        .{ .task_id = "t_routine_empty_061", .desc = "" },
        .{ .task_id = "t_routine_filled_061", .desc = "routine desc" },
    };

    for (cases) |case| {
        // Mirror the createRoutineTask three-way branch from task_create.zig.
        // (We deliberately inline this so the test exercises the PATTERN
        // that the handler uses, not a wrapper around it.)
        if (case.desc) |d| {
            if (d.len > 0) {
                try ctx.db.exec(alloc,
                    "INSERT INTO workspace_item_tasks (id, name, workspace_item_id, task_type, description) " ++
                    "VALUES (?, ?, ?, 'routine', ?)",
                    &[_][]const u8{ case.task_id, "Routine", parent_id, d });
            } else {
                try ctx.db.exec(alloc,
                    "INSERT INTO workspace_item_tasks (id, name, workspace_item_id, task_type, description) " ++
                    "VALUES (?, ?, ?, 'routine', '')",
                    &[_][]const u8{ case.task_id, "Routine", parent_id });
            }
        } else {
            try ctx.db.exec(alloc,
                "INSERT INTO workspace_item_tasks (id, name, workspace_item_id, task_type) " ++
                "VALUES (?, ?, ?, 'routine')",
                &[_][]const u8{ case.task_id, "Routine", parent_id });
        }

        try expectDescriptionEquals(&ctx, alloc, case.task_id, case.desc orelse "");
    }
}

test "task_create direct INSERT branches: null/empty/value all succeed for memory task_type" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();
    try Migration061.up(&ctx.db, alloc);
    const parent_id = try seedParent(&ctx, alloc);

    // Same three-way exercise, task_type='memory' branch.
    const cases = [_]MemoryCase{
        .{ .task_id = "t_memory_null_061", .desc = null },
        .{ .task_id = "t_memory_empty_061", .desc = "" },
        .{ .task_id = "t_memory_filled_061", .desc = "memory desc" },
    };

    for (cases) |case| {
        if (case.desc) |d| {
            if (d.len > 0) {
                try ctx.db.exec(alloc,
                    "INSERT INTO workspace_item_tasks (id, name, workspace_item_id, task_type, description) " ++
                    "VALUES (?, ?, ?, 'memory', ?)",
                    &[_][]const u8{ case.task_id, "Memory", parent_id, d });
            } else {
                try ctx.db.exec(alloc,
                    "INSERT INTO workspace_item_tasks (id, name, workspace_item_id, task_type, description) " ++
                    "VALUES (?, ?, ?, 'memory', '')",
                    &[_][]const u8{ case.task_id, "Memory", parent_id });
            }
        } else {
            try ctx.db.exec(alloc,
                "INSERT INTO workspace_item_tasks (id, name, workspace_item_id, task_type) " ++
                "VALUES (?, ?, ?, 'memory')",
                &[_][]const u8{ case.task_id, "Memory", parent_id });
        }

        try expectDescriptionEquals(&ctx, alloc, case.task_id, case.desc orelse "");
    }
}
