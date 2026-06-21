//! Unit tests for `kanban_model.zig` (kanban column CRUD data layer).
//!
//! Setup mirrors `migration_051_test.zig`: in-memory sqlite with a
//! minimal `workspace_items` + (sometimes) `workspace_item_tasks`
//! schema, ready for the kanban SQL to run against.
//!
//! Plan: docs/superpowers/plans/2026-06-21-workspace-item-kanban.md (Chunk 2)

const std = @import("std");
const testing = std.testing;
const nalarcore = @import("nalarcore");
const sqlite = nalarcore.sqlite;

const kanban = @import("kanban_model.zig");

/// Open a fresh in-memory sqlite DB with the bare minimum tables the
/// kanban_model functions need: `workspace_items` (for the FK
/// reference) and `kanban_columns` (the table being queried). Tests
/// that exercise task movement additionally `CREATE TABLE
/// workspace_item_tasks` after calling this helper.
fn setupDb() !struct { db: sqlite.SqliteBackend, threaded: std.Io.Threaded } {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    errdefer threaded.deinit();
    const io = threaded.io();

    var db: sqlite.SqliteBackend = .{};
    errdefer db.deinit();
    try db.init(io, ":memory:");

    return .{ .db = db, .threaded = threaded };
}

// ─── Test: listColumns orders by position ────────────────────────────────

test "listColumns returns columns ordered by position" {
    const alloc = testing.allocator;
    var s = try setupDb();
    defer s.threaded.deinit();
    defer s.db.deinit();

    try s.db.exec(alloc,
        "CREATE TABLE workspace_items (id TEXT PRIMARY KEY, workspace_id TEXT, item_type TEXT)", &.{});
    try s.db.exec(alloc,
        \\CREATE TABLE kanban_columns (
        \\    id TEXT PRIMARY KEY, workspace_item_id TEXT, name TEXT,
        \\    position INTEGER, created_at DATETIME DEFAULT CURRENT_TIMESTAMP)
    , &.{});
    try s.db.exec(alloc,
        "INSERT INTO workspace_items (id, workspace_id, item_type) VALUES ('item_1', 'ws_1', 'kanban')", &.{});
    try s.db.exec(alloc,
        "INSERT INTO kanban_columns (id, workspace_item_id, name, position) VALUES ('c1', 'item_1', 'todo', 0)", &.{});
    try s.db.exec(alloc,
        "INSERT INTO kanban_columns (id, workspace_item_id, name, position) VALUES ('c2', 'item_1', 'in progress', 1)", &.{});
    try s.db.exec(alloc,
        "INSERT INTO kanban_columns (id, workspace_item_id, name, position) VALUES ('c3', 'item_1', 'done', 2)", &.{});

    const cols = try kanban.listColumns(alloc, &s.db, "item_1");
    defer kanban.freeColumns(alloc, cols);

    try testing.expectEqual(@as(usize, 3), cols.len);
    try testing.expectEqualStrings("c1", cols[0].id);
    try testing.expectEqualStrings("todo", cols[0].name);
    try testing.expectEqualStrings("c2", cols[1].id);
    try testing.expectEqualStrings("c3", cols[2].id);
}
