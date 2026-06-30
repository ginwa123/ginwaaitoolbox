//! Unit tests for kanban column description (Chunk 1 of
//! kanban-column-description-settings plan).
//!
//! Covers:
//!   1. `addColumn` writes the description
//!   2. `listColumns` returns the description
//!   3. `updateColumn` with only description (no name) leaves the
//!      name unchanged
//!   4. `updateColumn` with only name (no description) leaves the
//!      description unchanged
//!   5. `updateColumn` with both writes both
//!   6. `seedDefaultColumns` writes empty descriptions (NOT NULL
//!      default constraint holds)
//!   7. `updateColumn` with empty-string description CLEARS the
//!      existing description (this is the bug-fix test for the
//!      2026-06-30 PATCH bug where `description: ""` was silently
//!      skipped — see plan: kanban-empty-description-patch)

const std = @import("std");
const testing = std.testing;
const sqlite = @import("nalarcore").sqlite;
const kanban_model = @import("kanban_model.zig");

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
    // migration_051_test.zig's setup; 051 assumes these tables
    // exist (the production migrator walks 001 → 051 in order, so
    // by the time 051 runs they are already there).
    try db.exec(alloc,
        "CREATE TABLE workspace_items (id TEXT PRIMARY KEY, workspace_id TEXT, item_type TEXT)",
        &.{});
    try db.exec(alloc,
        "CREATE TABLE workspace_item_tasks (id TEXT PRIMARY KEY, name TEXT, workspace_item_id TEXT)",
        &.{});
    const migration = @import("migration.zig");
    try migration.Migration051AddKanban.up(&db, alloc);
    try migration.Migration053AddKanbanColumnDescription.up(&db, alloc);
    return .{ .db = db, .threaded = threaded };
}

test "addColumn writes description to the new row" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const id = try kanban_model.addColumn(
        alloc, &ctx.db, "wi_1", "in_review", "Awaiting code review", 0,
    );
    defer alloc.free(id);

    const cols = try kanban_model.listColumns(alloc, &ctx.db, "wi_1");
    defer kanban_model.freeColumns(alloc, cols);

    try testing.expectEqual(@as(usize, 1), cols.len);
    try testing.expectEqualStrings("in_review", cols[0].name);
    try testing.expectEqualStrings("Awaiting code review", cols[0].description);
}

test "updateColumn with only description leaves name unchanged" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const id = try kanban_model.addColumn(
        alloc, &ctx.db, "wi_1", "todo", "Not started", 0,
    );
    defer alloc.free(id);

    try kanban_model.updateColumn(
        alloc, &ctx.db, "wi_1", id, null, "Not started yet — work in queue",
    );

    const cols = try kanban_model.listColumns(alloc, &ctx.db, "wi_1");
    defer kanban_model.freeColumns(alloc, cols);

    try testing.expectEqualStrings("todo", cols[0].name);
    try testing.expectEqualStrings("Not started yet — work in queue", cols[0].description);
}

test "updateColumn with only name leaves description unchanged" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const id = try kanban_model.addColumn(
        alloc, &ctx.db, "wi_1", "todo", "Not started", 0,
    );
    defer alloc.free(id);

    try kanban_model.updateColumn(alloc, &ctx.db, "wi_1", id, "backlog", null);

    const cols = try kanban_model.listColumns(alloc, &ctx.db, "wi_1");
    defer kanban_model.freeColumns(alloc, cols);

    try testing.expectEqualStrings("backlog", cols[0].name);
    try testing.expectEqualStrings("Not started", cols[0].description);
}

test "updateColumn with both name and description writes both" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const id = try kanban_model.addColumn(
        alloc, &ctx.db, "wi_1", "todo", "old", 0,
    );
    defer alloc.free(id);

    try kanban_model.updateColumn(
        alloc, &ctx.db, "wi_1", id, "backlog", "Newly triaged items",
    );

    const cols = try kanban_model.listColumns(alloc, &ctx.db, "wi_1");
    defer kanban_model.freeColumns(alloc, cols);

    try testing.expectEqualStrings("backlog", cols[0].name);
    try testing.expectEqualStrings("Newly triaged items", cols[0].description);
}

test "seedDefaultColumns writes empty descriptions" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try kanban_model.seedDefaultColumns(alloc, &ctx.db, "wi_1");

    const cols = try kanban_model.listColumns(alloc, &ctx.db, "wi_1");
    defer kanban_model.freeColumns(alloc, cols);

    try testing.expectEqual(@as(usize, 3), cols.len);
    for (cols) |c| {
        try testing.expectEqualStrings("", c.description);
    }
}

test "updateColumn with empty-string description clears existing description" {
    // Regression test for the 2026-06-30 PATCH bug:
    //   curl -X PATCH .../kanban/columns/col_X \
    //        --data-raw '{"name":"in_review_planning","description":""}'
    // The old code treated `""` identically to `null` (both
    // skipped the UPDATE), so the existing description stayed in
    // the DB and the response echoed the old value back. After the
    // fix, `""` clears the description while `null` leaves it
    // unchanged — three distinct states.
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const id = try kanban_model.addColumn(
        alloc, &ctx.db, "wi_1", "in_review", "Awaiting code review", 0,
    );
    defer alloc.free(id);

    // Sanity check: description was set on creation.
    {
        const cols = try kanban_model.listColumns(alloc, &ctx.db, "wi_1");
        defer kanban_model.freeColumns(alloc, cols);
        try testing.expectEqualStrings("Awaiting code review", cols[0].description);
    }

    // PATCH with description="" — must CLEAR the description (not
    // skip the UPDATE). The name stays unchanged.
    try kanban_model.updateColumn(
        alloc, &ctx.db, "wi_1", id, null, "",
    );

    const cols = try kanban_model.listColumns(alloc, &ctx.db, "wi_1");
    defer kanban_model.freeColumns(alloc, cols);

    try testing.expectEqualStrings("in_review", cols[0].name);
    try testing.expectEqualStrings("", cols[0].description);
}

test "updateColumn with null description leaves existing description unchanged" {
    // Companion to the empty-clear test above. Verifies that
    // `null` still means "leave unchanged" (field absent from
    // PATCH body), distinct from `""` (clear). If this test ever
    // starts clearing too, the branch logic has regressed.
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const id = try kanban_model.addColumn(
        alloc, &ctx.db, "wi_1", "todo", "Not started", 0,
    );
    defer alloc.free(id);

    // PATCH with name only — description must NOT be cleared.
    try kanban_model.updateColumn(alloc, &ctx.db, "wi_1", id, "backlog", null);

    const cols = try kanban_model.listColumns(alloc, &ctx.db, "wi_1");
    defer kanban_model.freeColumns(alloc, cols);

    try testing.expectEqualStrings("backlog", cols[0].name);
    try testing.expectEqualStrings("Not started", cols[0].description);
}

test "updateColumn with both empty description and new name writes both" {
    // Mixed PATCH: rename the column AND clear its description in
    // the same call. Verifies the empty-description branch and the
    // name branch compose correctly without one stomping the other.
    // Mirrors the user's exact curl from the bug report.
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const id = try kanban_model.addColumn(
        alloc, &ctx.db, "wi_1", "in_review", "Awaiting code review", 0,
    );
    defer alloc.free(id);

    try kanban_model.updateColumn(
        alloc, &ctx.db, "wi_1", id, "in_review_planning", "",
    );

    const cols = try kanban_model.listColumns(alloc, &ctx.db, "wi_1");
    defer kanban_model.freeColumns(alloc, cols);

    try testing.expectEqualStrings("in_review_planning", cols[0].name);
    try testing.expectEqualStrings("", cols[0].description);
}