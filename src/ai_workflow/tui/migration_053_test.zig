//! Static regression checks for Migration 053 (add kanban_column.description).
//!
//! Why this file exists
//! ────────────────────
//! Migration 053 introduces the optional `description` column on
//! `kanban_columns` so each column can carry a free-text "meaning"
//! alongside its display name. The migration must:
//!   1. ALTER TABLE kanban_columns ADD COLUMN description TEXT NOT NULL DEFAULT ''
//!   2. Be idempotent (use DEFAULT so existing rows survive)
//!   3. Add `description` to the pragma_table_info result set
//!
//! Plan: docs/superpowers/plans/2026-06-27-kanban-column-description-settings.md
//!   (Chunk 1, Task 1.1)

const std = @import("std");
const testing = std.testing;
const sqlite = @import("nalarcore").sqlite;
const Migration051AddKanban = @import("migration.zig").Migration051AddKanban;
const Migration053AddKanbanColumnDescription = @import("migration.zig").Migration053AddKanbanColumnDescription;

fn setupDb() !struct { db: sqlite.SqliteBackend, threaded: std.Io.Threaded } {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    errdefer threaded.deinit();
    const io = threaded.io();
    var db: sqlite.SqliteBackend = .{};
    errdefer db.deinit();
    try db.init(io, ":memory:");
    // Migration 051 needs `workspace_items` (FK target) and
    // `workspace_item_tasks` (ALTER TABLE target). Mirror
    // migration_051_test.zig's setup; 051 assumes these tables exist
    // (the production migrator walks 001 → 051 in order, so by the
    // time 051 runs they are already there).
    try db.exec(alloc,
        "CREATE TABLE workspace_items (id TEXT PRIMARY KEY, workspace_id TEXT, item_type TEXT)",
        &.{});
    try db.exec(alloc,
        "CREATE TABLE workspace_item_tasks (id TEXT PRIMARY KEY, name TEXT, workspace_item_id TEXT)",
        &.{});
    // Migration 051 creates kanban_columns — must run before 053.
    try Migration051AddKanban.up(&db, alloc);
    return .{ .db = db, .threaded = threaded };
}

test "migration 053 adds description column with default empty string" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    // Sanity: kanban_columns exists (051 seeded it).
    var q = try ctx.db.query(alloc,
        \\SELECT name FROM pragma_table_info('kanban_columns') ORDER BY cid
    , &.{});
    defer q.deinit();
    const names_before: [5][]const u8 = .{ "id", "workspace_item_id", "name", "position", "created_at" };
    var idx: usize = 0;
    while (try q.next()) |row| {
        defer row.deinit(alloc);
        try testing.expect(idx < names_before.len);
        try testing.expectEqualStrings(names_before[idx], row.values[0]);
        idx += 1;
    }
    try testing.expectEqual(@as(usize, 5), idx);

    // Apply migration 053.
    try Migration053AddKanbanColumnDescription.up(&ctx.db, alloc);

    // Re-check pragma_table_info — description is now present.
    var q2 = try ctx.db.query(alloc,
        \\SELECT name FROM pragma_table_info('kanban_columns') ORDER BY cid
    , &.{});
    defer q2.deinit();
    const names_after: [6][]const u8 = .{ "id", "workspace_item_id", "name", "position", "created_at", "description" };
    var idx2: usize = 0;
    while (try q2.next()) |row| {
        defer row.deinit(alloc);
        try testing.expect(idx2 < names_after.len);
        try testing.expectEqualStrings(names_after[idx2], row.values[0]);
        idx2 += 1;
    }
    try testing.expectEqual(@as(usize, 6), idx2);
}

test "migration 053 is safe on populated kanban_columns tables" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    // Insert one existing row (no description column yet).
    try ctx.db.exec(alloc,
        "INSERT INTO kanban_columns (id, workspace_item_id, name, position) " ++
        "VALUES ('col_pre_053', 'wi_1', 'todo', 0)",
        &.{},
    );

    // Apply migration 053 — the existing row should get description=''.
    try Migration053AddKanbanColumnDescription.up(&ctx.db, alloc);

    var q = try ctx.db.query(alloc,
        "SELECT description FROM kanban_columns WHERE id = 'col_pre_053'",
        &.{},
    );
    defer q.deinit();
    const row = (try q.next()) orelse return error.RowMissing;
    defer row.deinit(alloc);
    try testing.expectEqualStrings("", row.values[0]);
}