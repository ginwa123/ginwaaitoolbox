//! Static + behavioural regression checks for Migration 065
//! (`workspace_item_tasks.last_human_touched_at`).
//!
//! Why this file exists
//! ────────────────────
//! Migration 065 adds a single nullable INTEGER column that stamps the
//! last time a HUMAN (not the AI agent) interacted with a task —
//! dragged it, renamed it, edited its description, pinned it, sent a
//! chat message, or opened its chat. The kanban card UI uses this
//! column together with `sessions.last_finish_reason` to decide
//! whether to show the "AI finished — awaiting review" dot or the
//! "reviewed" checkmark (see docs/plans/2026-07-26-kanban-task-notification-icon.md).
//!
//! The migration must:
//!   1. Add `last_human_touched_at INTEGER` (nullable, no DEFAULT —
//!      NULL = "never touched", which the kanban SELECT uses to mean
//!      "AI finished and human hasn't seen it").
//!   2. Be idempotent on re-run (re-running must not crash with
//!      "duplicate column name" — see the project's hard-fought
//!      knowledge about fresh-DB migration cascades in
//!      `nalar-data-and-routines.md` §"Migration #009-#052 fresh-DB
//!      cascade is fragile").
//!   3. Be safe for fresh-DB installs that already declare the column
//!      in their canonical CREATE TABLE — use `addColumnIfMissing` so
//!      the helper handles both fresh-DB and upgrade-from-v1 paths.
//!   4. Leave existing rows at NULL (NOT 0 or the current time — the
//!      "user has touched this task" semantic is binary; we cannot
//!      retroactively know whether a row from before the migration was
//!      reviewed).
//!
//! Plan: docs/plans/2026-07-26-kanban-task-notification-icon.md (Chunk 1)

const std = @import("std");
const testing = std.testing;
const sqlite = @import("nalarcore").sqlite;

const Migration065AddTaskHumanTouchedAt = @import("migration.zig").Migration065AddTaskHumanTouchedAt;

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
    // and workspace_item_tasks itself must exist before the migration
    // can run. Production walks migrations 001 → 064 first, so they're
    // already there; we create minimal mirrors here for the unit test.
    // The minimal `workspace_item_tasks` schema matches the v1 shape —
    // no `last_human_touched_at` column yet, that's exactly what the
    // migration adds.
    try db.exec(alloc,
        "CREATE TABLE workspace_items (id TEXT PRIMARY KEY, workspace_id TEXT, item_type TEXT)",
        &.{});
    try db.exec(alloc,
        "CREATE TABLE workspace_item_tasks (id TEXT PRIMARY KEY, name TEXT, workspace_item_id TEXT, task_type TEXT NOT NULL DEFAULT 'standard')",
        &.{});
    return .{ .db = db, .threaded = threaded };
}

test "Migration065 adds last_human_touched_at column to workspace_item_tasks" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    // Sanity: column does NOT exist before the migration.
    {
        var q = try ctx.db.query(alloc,
            \\SELECT 1 FROM pragma_table_info('workspace_item_tasks')
            \\WHERE name = 'last_human_touched_at'
        , &.{});
        defer q.deinit();
        try testing.expect((try q.next()) == null);
    }

    // Apply the migration.
    try Migration065AddTaskHumanTouchedAt.up(&ctx.db, alloc);

    // Confirm the column exists with the expected name.
    var q = try ctx.db.query(alloc,
        \\SELECT name FROM pragma_table_info('workspace_item_tasks')
        \\WHERE name = 'last_human_touched_at'
    , &.{});
    defer q.deinit();
    const row = (try q.next()) orelse return error.ColumnMissing;
    defer row.deinit(alloc);
    try testing.expectEqualStrings("last_human_touched_at", row.values[0]);

    // Confirm there are no extra rows (i.e. only one match — not the
    // "column literally named INTEGER" footgun from passing only a
    // type to addColumnIfMissing; see project memory
    // `addColumnIfMissing-requires-name-type`).
    try testing.expect((try q.next()) == null);

    // Type sanity: the column must be INTEGER (so unix-ms comparisons
    // work as arithmetic), not TEXT or a literal "INTEGER" string in
    // the column-name slot.
    var qt = try ctx.db.query(alloc,
        \\SELECT type FROM pragma_table_info('workspace_item_tasks')
        \\WHERE name = 'last_human_touched_at'
    , &.{});
    defer qt.deinit();
    const type_row = (try qt.next()) orelse return error.RowMissing;
    defer type_row.deinit(alloc);
    try testing.expectEqualStrings("INTEGER", type_row.values[0]);
}

test "Migration065 is idempotent on a re-run" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    // Run the migration once…
    try Migration065AddTaskHumanTouchedAt.up(&ctx.db, alloc);
    // …and a second time. Must not crash with "duplicate column name".
    try Migration065AddTaskHumanTouchedAt.up(&ctx.db, alloc);

    // Still exactly one column of that name.
    var q = try ctx.db.query(alloc,
        \\SELECT COUNT(*) FROM pragma_table_info('workspace_item_tasks')
        \\WHERE name = 'last_human_touched_at'
    , &.{});
    defer q.deinit();
    const row = (try q.next()) orelse return error.RowMissing;
    defer row.deinit(alloc);
    try testing.expectEqualStrings("1", row.values[0]);
}

test "Migration065 is idempotent on a fresh-DB install where the canonical schema already declares the column" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    // Simulate a fresh-DB install where the canonical CREATE TABLE
    // already includes `last_human_touched_at INTEGER`. The migration
    // must be a no-op (NOT a "duplicate column" crash). This is the
    // same fresh-DB-vs-upgrade split that bit Migration 020 / 052 —
    // see project memory `nalar-data-and-routines.md` §"Migration
    // #009-#052 fresh-DB cascade is fragile".
    try ctx.db.exec(alloc, "DROP TABLE workspace_item_tasks", &.{});
    try ctx.db.exec(alloc,
        \\CREATE TABLE workspace_item_tasks (
        \\    id TEXT PRIMARY KEY,
        \\    name TEXT,
        \\    workspace_item_id TEXT,
        \\    task_type TEXT NOT NULL DEFAULT 'standard',
        \\    last_human_touched_at INTEGER
        \\)
    , &.{});

    // Should not error — addColumnIfMissing detects the column exists.
    try Migration065AddTaskHumanTouchedAt.up(&ctx.db, alloc);

    // Re-check: still exactly one column.
    var q = try ctx.db.query(alloc,
        \\SELECT COUNT(*) FROM pragma_table_info('workspace_item_tasks')
        \\WHERE name = 'last_human_touched_at'
    , &.{});
    defer q.deinit();
    const row = (try q.next()) orelse return error.RowMissing;
    defer row.deinit(alloc);
    try testing.expectEqualStrings("1", row.values[0]);
}

test "Migration065 leaves pre-existing rows at NULL (not 0, not now)" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    // Insert one existing task BEFORE applying the migration. The
    // semantics matter: we cannot retroactively know whether the user
    // touched this task before the migration ran, so the value must
    // be NULL (the "I don't know" state) — NOT 0 (which the kanban
    // SELECT would interpret as "touched at unix epoch 0, i.e. way
    // before the AI's finish_reason update, i.e. still needs review"
    // — semantically equivalent but misleading in logs) and NOT the
    // current time (which would silently mark every legacy task as
    // "reviewed" the moment the migration runs).
    try ctx.db.exec(alloc,
        "INSERT INTO workspace_items (id, workspace_id, item_type) " ++
        "VALUES ('wi_1', 'ws_1', 'chat')",
        &.{});
    try ctx.db.exec(alloc,
        "INSERT INTO workspace_item_tasks (id, name, workspace_item_id) " ++
        "VALUES ('task_pre_065', 'Legacy task', 'wi_1')",
        &.{});

    try Migration065AddTaskHumanTouchedAt.up(&ctx.db, alloc);

    // SQL NULL is surfaced as "" by SqliteBackend.query — see project
    // memory `sqlite-backend-empty-slice-binds-as-null` and the
    // existing Migration063 test for the same convention.
    var q = try ctx.db.query(alloc,
        "SELECT last_human_touched_at FROM workspace_item_tasks WHERE id = 'task_pre_065'",
        &.{});
    defer q.deinit();
    const row = (try q.next()) orelse return error.RowMissing;
    defer row.deinit(alloc);
    try testing.expectEqualStrings("", row.values[0]);
}

test "Migration065 stamps a value when set after the migration" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    try ctx.db.exec(alloc,
        "INSERT INTO workspace_items (id, workspace_id, item_type) " ++
        "VALUES ('wi_1', 'ws_1', 'chat')",
        &.{});
    try ctx.db.exec(alloc,
        "INSERT INTO workspace_item_tasks (id, name, workspace_item_id) " ++
        "VALUES ('task_a', 'A', 'wi_1')",
        &.{});

    try Migration065AddTaskHumanTouchedAt.up(&ctx.db, alloc);

    // Now stamp a unix-ms timestamp — should persist as the literal
    // integer (formatted as TEXT by SqliteBackend.bind). This is the
    // exact call shape that llm_history.updateTaskLastHumanTouchedAt
    // will use.
    const now_ms_str = try std.fmt.allocPrint(alloc, "{d}", .{@as(i64, 1_786_000_000_000)});
    defer alloc.free(now_ms_str);
    try ctx.db.exec(alloc,
        "UPDATE workspace_item_tasks SET last_human_touched_at = ? WHERE id = ?",
        &[_][]const u8{ now_ms_str, "task_a" });

    var q = try ctx.db.query(alloc,
        "SELECT last_human_touched_at FROM workspace_item_tasks WHERE id = 'task_a'",
        &.{});
    defer q.deinit();
    const row = (try q.next()) orelse return error.RowMissing;
    defer row.deinit(alloc);
    try testing.expectEqualStrings("1786000000000", row.values[0]);
}