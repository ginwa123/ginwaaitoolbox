//! Behavioural tests for the `move_design_element` LLM tool —
//! translates an existing design element by a (dx, dy) delta; when
//! `apply_to_children=true` (the default), the delta cascades to
//! every transitive descendant via the backend's recursive CTE.
//!
//! Plan: docs/superpowers/plans/2026-08-06-move-element-with-descendants.md
//! (Chunk 5, Task 5.1)
//!
//! Tests:
//!   1. apply_to_children=true cascades delta to descendants.
//!   2. apply_to_children=false moves only the root element.
//!   3. width/height/rotation apply to root only (never cascades).
//!   4. Non-existent element_id returns XML error.
//!   5. Invalid element_id prefix returns XML error.

const std = @import("std");
const testing = std.testing;
const nalarcore = @import("nalarcore");
const sqlite = nalarcore.sqlite;

const move_design_element = @import("move_design_element.zig");
const design_model = @import("../../../ai_workflow/tui/design_model.zig");

fn setupDbAndItem() !struct {
    db: sqlite.SqliteBackend,
    threaded: std.Io.Threaded,
    item_id: []const u8,
    item_path: []u8,
} {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    errdefer threaded.deinit();
    const io = threaded.io();

    var db: sqlite.SqliteBackend = .{};
    errdefer db.deinit();
    try db.init(io, ":memory:");

    try db.exec(alloc,
        \\CREATE TABLE workspace_items (
        \\    id TEXT PRIMARY KEY, workspace_id TEXT NOT NULL,
        \\    item_type TEXT NOT NULL, name TEXT, path TEXT,
        \\    position INTEGER NOT NULL DEFAULT 0,
        \\    created_at DATETIME, updated_at DATETIME)
    , &.{});

    try db.exec(alloc,
        \\CREATE TABLE workspace_item_tasks (
        \\    id TEXT PRIMARY KEY, name TEXT NOT NULL,
        \\    workspace_item_id TEXT NOT NULL,
        \\    task_type TEXT NOT NULL DEFAULT 'standard',
        \\    description TEXT NOT NULL DEFAULT '')
    , &.{});

    try db.exec(alloc,
        \\CREATE TABLE design_pages (
        \\    id TEXT PRIMARY KEY,
        \\    workspace_item_id TEXT NOT NULL,
        \\    name TEXT NOT NULL DEFAULT '',
        \\    workspace_item_task_id TEXT,
        \\    width INTEGER NOT NULL DEFAULT 1440,
        \\    height INTEGER NOT NULL DEFAULT 1024,
        \\    x INTEGER NOT NULL DEFAULT 0,
        \\    y INTEGER NOT NULL DEFAULT 0,
        \\    position INTEGER NOT NULL DEFAULT 0,
        \\    created_at DATETIME,
        \\    updated_at DATETIME,
        \\    UNIQUE (workspace_item_id, name),
        \\    FOREIGN KEY (workspace_item_id) REFERENCES workspace_items(id) ON DELETE CASCADE)
    , &.{});

    try db.exec(alloc,
        \\CREATE TABLE design_page_elements (
        \\    id TEXT PRIMARY KEY, page_id TEXT NOT NULL, name TEXT NOT NULL DEFAULT '',
        \\    file_path TEXT NOT NULL DEFAULT '',
        \\    x INTEGER NOT NULL DEFAULT 0, y INTEGER NOT NULL DEFAULT 0,
        \\    width INTEGER NOT NULL DEFAULT 375, height INTEGER NOT NULL DEFAULT 667,
        \\    z_index INTEGER NOT NULL DEFAULT 0, position INTEGER NOT NULL DEFAULT 0,
        \\        type TEXT NOT NULL DEFAULT 'rectangle', rotation REAL NOT NULL DEFAULT 0,
        \\        fill TEXT NOT NULL DEFAULT '', stroke TEXT NOT NULL DEFAULT '',
        \\        stroke_width INTEGER NOT NULL DEFAULT 0,
        \\        corner_radius INTEGER NOT NULL DEFAULT 0, opacity REAL NOT NULL DEFAULT 1.0,
        \\        text_content TEXT NOT NULL DEFAULT '', text_style TEXT NOT NULL DEFAULT '',
        \\        image_url TEXT NOT NULL DEFAULT '', parent_id TEXT,
        \\        created_at DATETIME, updated_at DATETIME,
        \\        FOREIGN KEY (page_id) REFERENCES design_pages(id) ON DELETE CASCADE)
    , &.{});

    var tmp = testing.tmpDir(.{});
    var tmpdir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmpdir_len = try tmp.dir.realPath(testing.io, &tmpdir_buf);
    const tmpdir_path = try testing.allocator.dupe(u8, tmpdir_buf[0..tmpdir_len]);

    const item_id_const = "item_design_move_element_tool";
    try db.exec(alloc,
        "INSERT INTO workspace_items (id, workspace_id, item_type, path) " ++
        "VALUES (?, 'ws_test', 'design', ?)",
        &.{ item_id_const, tmpdir_path });

    const item_id_slice = try alloc.dupe(u8, item_id_const);
    return .{
        .db = db,
        .threaded = threaded,
        .item_id = item_id_slice,
        .item_path = tmpdir_path,
    };
}

fn teardownDb(db: *sqlite.SqliteBackend, threaded: *std.Io.Threaded) void {
    db.deinit();
    threaded.deinit();
}

fn readX(
    alloc: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    element_id: []const u8,
) !i64 {
    var q = try db.query(alloc,
        "SELECT x FROM design_page_elements WHERE id = ?",
        &.{element_id});
    defer q.deinit();
    const row = (try q.next()) orelse return error.ElementNotFound;
    defer row.deinit(alloc);
    return std.fmt.parseInt(i64, row.values[0], 10) catch 0;
}

test "executeMoveDesignElementToString with apply_to_children=true (default) cascades dx/dy to descendants" {
    const alloc = testing.allocator;
    var ctx = try setupDbAndItem();
    defer teardownDb(&ctx.db, &ctx.threaded);
    defer alloc.free(ctx.item_id);
    defer alloc.free(ctx.item_path);

    const page_id = try design_model.setDesignPage(alloc, &ctx.db, .{
        .item_id = ctx.item_id,
        .page_name = "MoveTest",
        .width = 1440,
        .height = 1024,
    });
    defer alloc.free(page_id);

    const group = try design_model.addElement(alloc, &ctx.db, ctx.threaded.io(), .{
        .page_id = page_id,
        .name = "group",
        .elem_type = .frame,
        .html = "<div></div>",
        .x = 50, .y = 100, .width = 300, .height = 200,
        .fill = "#ffffff", .rotation = 0.0, .corner_radius = 0, .opacity = 1.0,
    });
    defer alloc.free(group);

    const child1 = try design_model.addElement(alloc, &ctx.db, ctx.threaded.io(), .{
        .page_id = page_id,
        .name = "child1",
        .elem_type = .rectangle,
        .html = "<div></div>",
        .x = 70, .y = 110, .width = 30, .height = 30,
        .fill = "#000000", .rotation = 0.0, .corner_radius = 0, .opacity = 1.0,
        .parent_id = group,
    });
    defer alloc.free(child1);

    const child2 = try design_model.addElement(alloc, &ctx.db, ctx.threaded.io(), .{
        .page_id = page_id,
        .name = "child2",
        .elem_type = .rectangle,
        .html = "<div></div>",
        .x = 200, .y = 200, .width = 30, .height = 30,
        .fill = "#000000", .rotation = 0.0, .corner_radius = 0, .opacity = 1.0,
        .parent_id = group,
    });
    defer alloc.free(child2);

    // Call with apply_to_children omitted (defaults to true).
    const xml = try move_design_element.executeMoveDesignElementToString(
        alloc,
        &ctx.db, .{ .element_id = group, .dx = 100, .dy = 50 },
    );
    defer alloc.free(xml);

    // Tool response shape: `<move_design_element><updated>...<element id="..." x="..." y="..."/>...</updated></move_design_element>`.
    try testing.expect(std.mem.indexOf(u8, xml, "<move_design_element>") != null);
    try testing.expect(std.mem.indexOf(u8, xml, "</move_design_element>") != null);
    try testing.expect(std.mem.indexOf(u8, xml, "<updated>") != null);
    try testing.expect(std.mem.indexOf(u8, xml, "</updated>") != null);
    // No error block.
    try testing.expect(std.mem.indexOf(u8, xml, "<error>") == null);

    // DB cascade verified — group + children all moved by (100, 50).
    try testing.expectEqual(@as(i64, 150), try readX(alloc, &ctx.db, group));
    try testing.expectEqual(@as(i64, 170), try readX(alloc, &ctx.db, child1));
    try testing.expectEqual(@as(i64, 300), try readX(alloc, &ctx.db, child2));
}

test "executeMoveDesignElementToString with apply_to_children=false moves ONLY the root element" {
    const alloc = testing.allocator;
    var ctx = try setupDbAndItem();
    defer teardownDb(&ctx.db, &ctx.threaded);
    defer alloc.free(ctx.item_id);
    defer alloc.free(ctx.item_path);

    const page_id = try design_model.setDesignPage(alloc, &ctx.db, .{
        .item_id = ctx.item_id,
        .page_name = "SingleMoveTest",
        .width = 1440,
        .height = 1024,
    });
    defer alloc.free(page_id);

    const leaf = try design_model.addElement(alloc, &ctx.db, ctx.threaded.io(), .{
        .page_id = page_id,
        .name = "leaf",
        .elem_type = .rectangle,
        .html = "<div></div>",
        .x = 100, .y = 100, .width = 50, .height = 50,
        .fill = "#000000", .rotation = 0.0, .corner_radius = 0, .opacity = 1.0,
    });
    defer alloc.free(leaf);

    const xml = try move_design_element.executeMoveDesignElementToString(
        alloc,
        &ctx.db, .{ .element_id = leaf, .dx = 30, .dy = 20, .apply_to_children = false },
    );
    defer alloc.free(xml);

    try testing.expect(std.mem.indexOf(u8, xml, "<move_design_element>") != null);
    try testing.expect(std.mem.indexOf(u8, xml, "<error>") == null);

    try testing.expectEqual(@as(i64, 130), try readX(alloc, &ctx.db, leaf));
}

test "executeMoveDesignElementToString with width/height/rotation applies to root only (never cascades)" {
    const alloc = testing.allocator;
    var ctx = try setupDbAndItem();
    defer teardownDb(&ctx.db, &ctx.threaded);
    defer alloc.free(ctx.item_id);
    defer alloc.free(ctx.item_path);

    const page_id = try design_model.setDesignPage(alloc, &ctx.db, .{
        .item_id = ctx.item_id,
        .page_name = "ExtrasTest",
        .width = 1440,
        .height = 1024,
    });
    defer alloc.free(page_id);

    const group = try design_model.addElement(alloc, &ctx.db, ctx.threaded.io(), .{
        .page_id = page_id,
        .name = "g",
        .elem_type = .frame,
        .html = "<div></div>",
        .x = 0, .y = 0, .width = 200, .height = 150,
        .fill = "#ffffff", .rotation = 0.0, .corner_radius = 0, .opacity = 1.0,
    });
    defer alloc.free(group);

    const child = try design_model.addElement(alloc, &ctx.db, ctx.threaded.io(), .{
        .page_id = page_id,
        .name = "c",
        .elem_type = .rectangle,
        .html = "<div></div>",
        .x = 10, .y = 10, .width = 80, .height = 60,
        .fill = "#000000", .rotation = 0.0, .corner_radius = 0, .opacity = 1.0,
        .parent_id = group,
    });
    defer alloc.free(child);

    const xml = try move_design_element.executeMoveDesignElementToString(
        alloc,
        &ctx.db, .{
            .element_id = group,
            .dx = 0,
            .dy = 0,
            .width = 500,
            .height = 300,
            .rotation = 0.5,
        },
    );
    defer alloc.free(xml);

    try testing.expect(std.mem.indexOf(u8, xml, "<error>") == null);

    // Group resized in DB.
    {
        var q = try ctx.db.query(alloc,
            "SELECT width, height, rotation FROM design_page_elements WHERE id = ?",
            &.{group});
        defer q.deinit();
        const row = (try q.next()) orelse unreachable;
        defer row.deinit(alloc);
        const w = std.fmt.parseInt(i64, row.values[0], 10) catch 0;
        const h = std.fmt.parseInt(i64, row.values[1], 10) catch 0;
        const r = std.fmt.parseFloat(f64, row.values[2]) catch 0.0;
        try testing.expectEqual(@as(i64, 500), w);
        try testing.expectEqual(@as(i64, 300), h);
        try testing.expectApproxEqAbs(@as(f64, 0.5), r, 0.0001);
    }

    // Child width UNCHANGED.
    {
        var q = try ctx.db.query(alloc,
            "SELECT width FROM design_page_elements WHERE id = ?",
            &.{child});
        defer q.deinit();
        const row = (try q.next()) orelse unreachable;
        defer row.deinit(alloc);
        const cw = std.fmt.parseInt(i64, row.values[0], 10) catch 0;
        try testing.expectEqual(@as(i64, 80), cw);
    }
}

test "executeMoveDesignElementToString returns <error> for non-existent element_id" {
    const alloc = testing.allocator;
    var ctx = try setupDbAndItem();
    defer teardownDb(&ctx.db, &ctx.threaded);
    defer alloc.free(ctx.item_id);
    defer alloc.free(ctx.item_path);

    const xml = try move_design_element.executeMoveDesignElementToString(
        alloc,
        &ctx.db, .{ .element_id = "elem_ghost", .dx = 10, .dy = 0 },
    );
    defer alloc.free(xml);

    try testing.expect(std.mem.indexOf(u8, xml, "<error>") != null);
    try testing.expect(std.mem.indexOf(u8, xml, "element_id does not reference") != null);
}

test "executeMoveDesignElementToString returns <error> for invalid element_id prefix" {
    const alloc = testing.allocator;
    var ctx = try setupDbAndItem();
    defer teardownDb(&ctx.db, &ctx.threaded);
    defer alloc.free(ctx.item_id);
    defer alloc.free(ctx.item_path);

    const xml = try move_design_element.executeMoveDesignElementToString(
        alloc,
        &ctx.db, .{ .element_id = "page_something", .dx = 10, .dy = 0 },
    );
    defer alloc.free(xml);

    try testing.expect(std.mem.indexOf(u8, xml, "<error>") != null);
    try testing.expect(std.mem.indexOf(u8, xml, "PAGE id") != null);
}
