//! Static + behavioural regression checks for Migration 067
//! (`workspace_item_tasks.tags`).
//!
//! Why this file exists
//! ────────────────────
//! Migration 067 adds a `tags TEXT NOT NULL DEFAULT ''` column to
//! `workspace_item_tasks` to support the kanban task tags feature
//! (plan: docs/superpowers/plans/2026-07-28-kanban-task-tags.md).
//! Tags are stored as a JSON-encode array string (e.g.
//! `'["bug","urgent","frontend"]'`); empty string = "no tags".
//!
//! The migration must:
//!   1. Add `tags TEXT NOT NULL DEFAULT ''` to `workspace_item_tasks`.
//!   2. Be idempotent on re-run (re-running must not crash with
//!      "duplicate column name").
//!   3. Be safe for fresh-DB installs that already declare the column
//!      in their canonical CREATE TABLE — use `addColumnIfMissing` so
//!      the helper handles both fresh-DB and upgrade-from-v1 paths.
//!   4. Leave existing rows at '' (the canonical "no tags" sentinel).
//!   5. Be registered in `allMigrations` — defining the struct alone
//!      is a silent-skip bug per project memory
//!      `migration-registration-trap`.
//!
//! Plan: docs/superpowers/plans/2026-07-28-kanban-task-tags.md (Task 1)

const std = @import("std");
const testing = std.testing;
const sqlite = @import("nalarcore").sqlite;

const Migration067AddTaskTags = @import("migration.zig").Migration067AddTaskTags;

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
    // can run. Production walks migrations 001 → 066 first, so they're
    // already there; we create minimal mirrors here for the unit test.
    // The minimal `workspace_item_tasks` schema matches the v1 shape —
    // no `tags` column yet, that's exactly what the migration adds.
    try db.exec(alloc,
        "CREATE TABLE workspace_items (id TEXT PRIMARY KEY, workspace_id TEXT, item_type TEXT)",
        &.{});
    try db.exec(alloc,
        "CREATE TABLE workspace_item_tasks (id TEXT PRIMARY KEY, name TEXT, workspace_item_id TEXT, task_type TEXT NOT NULL DEFAULT 'standard')",
        &.{});
    return .{ .db = db, .threaded = threaded };
}

test "Migration067 adds tags column to workspace_item_tasks" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    // Sanity: column does NOT exist before the migration.
    {
        var q = try ctx.db.query(alloc,
            \\SELECT 1 FROM pragma_table_info('workspace_item_tasks')
            \\WHERE name = 'tags'
        , &.{});
        defer q.deinit();
        try testing.expect((try q.next()) == null);
    }

    // Apply the migration.
    try Migration067AddTaskTags.up(&ctx.db, alloc);

    // Confirm the column exists with the expected name.
    var q = try ctx.db.query(alloc,
        \\SELECT name FROM pragma_table_info('workspace_item_tasks')
        \\WHERE name = 'tags'
    , &.{});
    defer q.deinit();
    const row = (try q.next()) orelse return error.ColumnMissing;
    defer row.deinit(alloc);
    try testing.expectEqualStrings("tags", row.values[0]);

    // Confirm there are no extra rows (guards against the "column literally
    // named TEXT" footgun from passing only a type to addColumnIfMissing;
    // see project memory `addColumnIfMissing-requires-name-type`).
    try testing.expect((try q.next()) == null);

    // Type sanity: the column must be TEXT (NOT NULL DEFAULT '' applies
    // independently of the type).
    var qt = try ctx.db.query(alloc,
        \\SELECT type FROM pragma_table_info('workspace_item_tasks')
        \\WHERE name = 'tags'
    , &.{});
    defer qt.deinit();
    const type_row = (try qt.next()) orelse return error.RowMissing;
    defer type_row.deinit(alloc);
    try testing.expectEqualStrings("TEXT", type_row.values[0]);
}

test "Migration067 is idempotent on a re-run" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    // Run the migration once…
    try Migration067AddTaskTags.up(&ctx.db, alloc);
    // …and a second time. Must not crash with "duplicate column name".
    try Migration067AddTaskTags.up(&ctx.db, alloc);

    // Still exactly one column of that name.
    var q = try ctx.db.query(alloc,
        \\SELECT COUNT(*) FROM pragma_table_info('workspace_item_tasks')
        \\WHERE name = 'tags'
    , &.{});
    defer q.deinit();
    const row = (try q.next()) orelse return error.RowMissing;
    defer row.deinit(alloc);
    try testing.expectEqualStrings("1", row.values[0]);
}

test "Migration067 is idempotent on a fresh-DB install where the canonical schema already declares the column" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    // Simulate a fresh-DB install where the canonical CREATE TABLE
    // already includes `tags TEXT`. The migration must be a no-op
    // (NOT a "duplicate column" crash). Mirrors the fresh-DB-vs-
    // upgrade split that hit Migration 020 / 052 — see project memory
    // `nalar-data-and-routines.md` §"Migration #009-#052 fresh-DB
    // cascade is fragile".
    try ctx.db.exec(alloc, "DROP TABLE workspace_item_tasks", &.{});
    try ctx.db.exec(alloc,
        \\CREATE TABLE workspace_item_tasks (
        \\    id TEXT PRIMARY KEY,
        \\    name TEXT,
        \\    workspace_item_id TEXT,
        \\    task_type TEXT NOT NULL DEFAULT 'standard',
        \\    tags TEXT NOT NULL DEFAULT ''
        \\)
    , &.{});

    // Should not error — addColumnIfMissing detects the column exists.
    try Migration067AddTaskTags.up(&ctx.db, alloc);

    // Re-check: still exactly one column.
    var q = try ctx.db.query(alloc,
        \\SELECT COUNT(*) FROM pragma_table_info('workspace_item_tasks')
        \\WHERE name = 'tags'
    , &.{});
    defer q.deinit();
    const row = (try q.next()) orelse return error.RowMissing;
    defer row.deinit(alloc);
    try testing.expectEqualStrings("1", row.values[0]);
}

test "Migration067 leaves pre-existing rows at empty string (the no-tags sentinel)" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    // Insert one existing task BEFORE applying the migration. We
    // cannot retroactively know what tags the user wanted, so the
    // value must be '' (canonical "no tags" sentinel) — NOT NULL
    // (the column is NOT NULL DEFAULT ''). Matches the description
    // column (Migration 062) sentinel pattern.
    try ctx.db.exec(alloc,
        "INSERT INTO workspace_items (id, workspace_id, item_type) " ++
        "VALUES ('wi_1', 'ws_1', 'chat')",
        &.{});
    try ctx.db.exec(alloc,
        "INSERT INTO workspace_item_tasks (id, name, workspace_item_id) " ++
        "VALUES ('task_pre_067', 'Legacy task', 'wi_1')",
        &.{});

    try Migration067AddTaskTags.up(&ctx.db, alloc);

    var q = try ctx.db.query(alloc,
        "SELECT tags FROM workspace_item_tasks WHERE id = 'task_pre_067'",
        &.{});
    defer q.deinit();
    const row = (try q.next()) orelse return error.RowMissing;
    defer row.deinit(alloc);
    try testing.expectEqualStrings("", row.values[0]);
}

test "Migration067 accepts a JSON array string when set after the migration" {
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

    try Migration067AddTaskTags.up(&ctx.db, alloc);

    // Now update with a JSON array — should persist verbatim. This is
    // the exact call shape that llm_history.createWorkspaceItemTask
    // (with tags) will use post-Migration 067.
    try ctx.db.exec(alloc,
        "UPDATE workspace_item_tasks SET tags = ? WHERE id = ?",
        &[_][]const u8{ "[\"bug\",\"urgent\",\"frontend\"]", "task_a" });

    var q = try ctx.db.query(alloc,
        "SELECT tags FROM workspace_item_tasks WHERE id = 'task_a'",
        &.{});
    defer q.deinit();
    const row = (try q.next()) orelse return error.RowMissing;
    defer row.deinit(alloc);
    try testing.expectEqualStrings("[\"bug\",\"urgent\",\"frontend\"]", row.values[0]);
}

test "Migration067 is registered in allMigrations" {
    // Catches the silent-skip regression where the struct is defined
    // but the registration tuple is missing (per project memory
    // `migration-registration-trap`). Search the slice by version
    // number so the test stays stable across reordering.
    const all = @import("migration.zig").allMigrations;
    for (all) |m| {
        if (m.version == Migration067AddTaskTags.version) return;
    }
    return error.Migration067NotRegistered;
}
