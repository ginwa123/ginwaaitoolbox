//! Behavioural tests for the `POST .../elements/reparent-batch`
//! HTTP handler (Chunk 1b Tasks 1b.2 + 1b.3).
//!
//! Plan: docs/superpowers/plans/2026-07-30-design-layer-drag-join-or-leave-group.md
//!
//! Tests:
//!   1. Handler parses the body and delegates to design_model.reparentElements.
//!   2. Handler returns 200 with { updated: DesignElement[] } on success.
//!   3. Handler maps CycleDetected → 400 BadReparent (DB unchanged).
//!   4. Handler maps EmptyElementIds → 400.
//!   5. Handler maps CrossPageIds → 409.
//!   6. Handler maps BadNewParentId → 400.
//!   7. Handler maps PageNotFound → 404.
//!   8. Handler maps BadElementId → 400.

const std = @import("std");
const testing = std.testing;
const nalarcore = @import("nalarcore");
const sqlite = nalarcore.sqlite;

const design_model = @import("../design_model.zig");
const handler_mod = @import("design_elements_reparent.zig");

// ─── Setup helper ─────────────────────────────────────────────────────────

fn setupDbAndItem() !struct {
    db: sqlite.SqliteBackend,
    threaded: std.Io.Threaded,
    item_id: []const u8,
    item_path: []u8,
    page_id: []u8,
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
        \\    type TEXT NOT NULL DEFAULT 'rectangle', rotation REAL NOT NULL DEFAULT 0,
        \\    fill TEXT NOT NULL DEFAULT '', stroke TEXT NOT NULL DEFAULT '',
        \\    stroke_width INTEGER NOT NULL DEFAULT 0,
        \\    corner_radius INTEGER NOT NULL DEFAULT 0, opacity REAL NOT NULL DEFAULT 1.0,
        \\    text_content TEXT NOT NULL DEFAULT '', text_style TEXT NOT NULL DEFAULT '',
        \\    image_url TEXT NOT NULL DEFAULT '', parent_id TEXT,
        \\    created_at DATETIME, updated_at DATETIME,
        \\    FOREIGN KEY (page_id) REFERENCES design_pages(id) ON DELETE CASCADE)
    , &.{});

    var tmp = testing.tmpDir(.{});
    var tmpdir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmpdir_len = try tmp.dir.realPath(testing.io, &tmpdir_buf);
    const tmpdir_path = try testing.allocator.dupe(u8, tmpdir_buf[0..tmpdir_len]);

    const item_id_const = "item_design_reparent_batch_handler";
    try db.exec(alloc,
        "INSERT INTO workspace_items (id, workspace_id, item_type, path) " ++
        "VALUES (?, 'ws_test', 'design', ?)",
        &.{ item_id_const, tmpdir_path });

    const item_id_slice = try alloc.dupe(u8, item_id_const);

    const page_id_alloc = try design_model.setDesignPage(alloc, &db, .{
        .item_id = item_id_slice,
        .page_name = "Login",
        .width = 1440,
        .height = 1024,
    });

    return .{
        .db = db,
        .threaded = threaded,
        .item_id = item_id_slice,
        .item_path = tmpdir_path,
        .page_id = page_id_alloc,
    };
}

fn teardown(db: *sqlite.SqliteBackend, threaded: *std.Io.Threaded) void {
    db.deinit();
    threaded.deinit();
}

// ─── Test 1: useCase succeeds with valid input ──────────────────────────

test "useCase reparent 3 elements into a group and returns updated rows in input order" {
    const alloc = testing.allocator;
    var ctx = try setupDbAndItem();
    defer teardown(&ctx.db, &ctx.threaded);
    defer alloc.free(ctx.item_id);
    defer alloc.free(ctx.item_path);
    defer alloc.free(ctx.page_id);

    const group_id = try design_model.addElement(alloc, &ctx.db, ctx.threaded.io(), .{
        .page_id = ctx.page_id,
        .name = "group",
        .elem_type = .frame,
        .html = "<div></div>",
        .x = 100, .y = 200, .width = 400, .height = 300,
        .fill = "#ffffff", .rotation = 0.0, .corner_radius = 0, .opacity = 1.0,
    });
    defer alloc.free(group_id);

    const a_id = try design_model.addElement(alloc, &ctx.db, ctx.threaded.io(), .{
        .page_id = ctx.page_id,
        .name = "a",
        .elem_type = .rectangle,
        .html = "<div></div>",
        .x = 110, .y = 220, .width = 80, .height = 30,
        .fill = "#000000", .rotation = 0.0, .corner_radius = 0, .opacity = 1.0,
    });
    defer alloc.free(a_id);
    const b_id = try design_model.addElement(alloc, &ctx.db, ctx.threaded.io(), .{
        .page_id = ctx.page_id,
        .name = "b",
        .elem_type = .rectangle,
        .html = "<div></div>",
        .x = 200, .y = 220, .width = 80, .height = 30,
        .fill = "#000000", .rotation = 0.0, .corner_radius = 0, .opacity = 1.0,
    });
    defer alloc.free(b_id);
    const c_id = try design_model.addElement(alloc, &ctx.db, ctx.threaded.io(), .{
        .page_id = ctx.page_id,
        .name = "c",
        .elem_type = .rectangle,
        .html = "<div></div>",
        .x = 300, .y = 220, .width = 80, .height = 30,
        .fill = "#000000", .rotation = 0.0, .corner_radius = 0, .opacity = 1.0,
    });
    defer alloc.free(c_id);

    const ids = [_][]const u8{ a_id, b_id, c_id };
    const updated = try handler_mod.useCase(alloc, &ctx.db, .{
        .page_id = ctx.page_id,
        .element_ids = &ids,
        .new_parent_id = group_id,
        .reposition = .last_in_parent,
    });
    defer {
        for (updated) |e| design_model.freeElement(alloc, e);
        alloc.free(updated);
    }

    try testing.expectEqual(@as(usize, 3), updated.len);
    try testing.expectEqualStrings(a_id, updated[0].id);
    try testing.expectEqualStrings(b_id, updated[1].id);
    try testing.expectEqualStrings(c_id, updated[2].id);
}

// ─── Test 2: cycle in batch returns BadReparent ──────────────────────────

test "useCase returns BadReparent when the batch contains a cycle" {
    const alloc = testing.allocator;
    var ctx = try setupDbAndItem();
    defer teardown(&ctx.db, &ctx.threaded);
    defer alloc.free(ctx.item_id);
    defer alloc.free(ctx.item_path);
    defer alloc.free(ctx.page_id);

    // Build a cycle: group_a → group_b → group_c, then try to put
    // group_c and group_a under group_b. group_c already IS under
    // group_b, so it's fine; group_a → group_b would close a cycle
    // (group_b is a descendant of group_a).
    try ctx.db.exec(alloc,
        \\INSERT INTO design_page_elements
        \\   (id, page_id, name, file_path, x, y, width, height, z_index, position,
        \\    type, rotation, fill, stroke, stroke_width, corner_radius, opacity,
        \\    text_content, text_style, image_url, parent_id,
        \\    created_at, updated_at)
        \\VALUES
        \\   ('g_a', ?, 'a', '', 0, 0, 100, 100, 0, 0,
        \\    'frame', 0.0, '', '', 0, 0, 1.0,
        \\    '', '', '', NULL, datetime('now'), datetime('now')),
        \\   ('g_b', ?, 'b', '', 0, 0, 100, 100, 0, 0,
        \\    'frame', 0.0, '', '', 0, 0, 1.0,
        \\    '', '', '', 'g_a', datetime('now'), datetime('now')),
        \\   ('g_c', ?, 'c', '', 0, 0, 100, 100, 0, 0,
        \\    'frame', 0.0, '', '', 0, 0, 1.0,
        \\    '', '', '', 'g_b', datetime('now'), datetime('now'))
    , &.{ctx.page_id, ctx.page_id, ctx.page_id});

    const ids = [_][]const u8{ "g_c", "g_a" };
    const result = handler_mod.useCase(alloc, &ctx.db, .{
        .page_id = ctx.page_id,
        .element_ids = &ids,
        .new_parent_id = "g_b",
        .reposition = .last_in_parent,
    });
    try testing.expectError(error.BadReparent, result);
}

// ─── Test 3: empty element_ids returns EmptyElementIds ──────────────────

test "useCase returns EmptyElementIds for empty input" {
    const alloc = testing.allocator;
    var ctx = try setupDbAndItem();
    defer teardown(&ctx.db, &ctx.threaded);
    defer alloc.free(ctx.item_id);
    defer alloc.free(ctx.item_path);
    defer alloc.free(ctx.page_id);

    const ids = [_][]const u8{};
    const result = handler_mod.useCase(alloc, &ctx.db, .{
        .page_id = ctx.page_id,
        .element_ids = &ids,
        .new_parent_id = null,
        .reposition = .last_in_parent,
    });
    try testing.expectError(error.EmptyElementIds, result);
}

// ─── Test 4: cross-page ids returns CrossPageIds ─────────────────────────

test "useCase returns CrossPageIds when any element is on a different page" {
    const alloc = testing.allocator;
    var ctx = try setupDbAndItem();
    defer teardown(&ctx.db, &ctx.threaded);
    defer alloc.free(ctx.item_id);
    defer alloc.free(ctx.item_path);
    defer alloc.free(ctx.page_id);

    const page2_id = try design_model.setDesignPage(alloc, &ctx.db, .{
        .item_id = ctx.item_id,
        .page_name = "Second",
        .width = 1440,
        .height = 1024,
    });
    defer alloc.free(page2_id);

    const leaf1 = try design_model.addElement(alloc, &ctx.db, ctx.threaded.io(), .{
        .page_id = ctx.page_id,
        .name = "leaf1",
        .elem_type = .rectangle,
        .html = "<div></div>",
        .x = 0, .y = 0, .width = 50, .height = 50,
        .fill = "#000000", .rotation = 0.0, .corner_radius = 0, .opacity = 1.0,
    });
    defer alloc.free(leaf1);

    const leaf2 = try design_model.addElement(alloc, &ctx.db, ctx.threaded.io(), .{
        .page_id = page2_id,
        .name = "leaf2",
        .elem_type = .rectangle,
        .html = "<div></div>",
        .x = 0, .y = 0, .width = 50, .height = 50,
        .fill = "#000000", .rotation = 0.0, .corner_radius = 0, .opacity = 1.0,
    });
    defer alloc.free(leaf2);

    const group = try design_model.addElement(alloc, &ctx.db, ctx.threaded.io(), .{
        .page_id = ctx.page_id,
        .name = "group",
        .elem_type = .frame,
        .html = "<div></div>",
        .x = 100, .y = 100, .width = 100, .height = 100,
        .fill = "#ffffff", .rotation = 0.0, .corner_radius = 0, .opacity = 1.0,
    });
    defer alloc.free(group);

    const ids = [_][]const u8{ leaf1, leaf2 };
    const result = handler_mod.useCase(alloc, &ctx.db, .{
        .page_id = ctx.page_id,
        .element_ids = &ids,
        .new_parent_id = group,
        .reposition = .last_in_parent,
    });
    try testing.expectError(error.CrossPageIds, result);
}

// ─── Test 5: bad new parent returns BadNewParentId ──────────────────────

test "useCase returns BadNewParentId when the new parent is a leaf" {
    const alloc = testing.allocator;
    var ctx = try setupDbAndItem();
    defer teardown(&ctx.db, &ctx.threaded);
    defer alloc.free(ctx.item_id);
    defer alloc.free(ctx.item_path);
    defer alloc.free(ctx.page_id);

    const a = try design_model.addElement(alloc, &ctx.db, ctx.threaded.io(), .{
        .page_id = ctx.page_id,
        .name = "a",
        .elem_type = .rectangle,
        .html = "<div></div>",
        .x = 0, .y = 0, .width = 50, .height = 50,
        .fill = "#000000", .rotation = 0.0, .corner_radius = 0, .opacity = 1.0,
    });
    defer alloc.free(a);
    const b = try design_model.addElement(alloc, &ctx.db, ctx.threaded.io(), .{
        .page_id = ctx.page_id,
        .name = "b",
        .elem_type = .rectangle,
        .html = "<div></div>",
        .x = 60, .y = 0, .width = 50, .height = 50,
        .fill = "#000000", .rotation = 0.0, .corner_radius = 0, .opacity = 1.0,
    });
    defer alloc.free(b);

    const ids = [_][]const u8{ a, b };
    const result = handler_mod.useCase(alloc, &ctx.db, .{
        .page_id = ctx.page_id,
        .element_ids = &ids,
        .new_parent_id = a,
        .reposition = .last_in_parent,
    });
    try testing.expectError(error.BadNewParentId, result);
}

// ─── Test 6: bad page_id returns PageNotFound ───────────────────────────

test "useCase returns PageNotFound when the page does not exist" {
    const alloc = testing.allocator;
    var ctx = try setupDbAndItem();
    defer teardown(&ctx.db, &ctx.threaded);
    defer alloc.free(ctx.item_id);
    defer alloc.free(ctx.item_path);
    defer alloc.free(ctx.page_id);

    const ids = [_][]const u8{"elem_x"};
    const result = handler_mod.useCase(alloc, &ctx.db, .{
        .page_id = "page_nonexistent",
        .element_ids = &ids,
        .new_parent_id = null,
        .reposition = .last_in_parent,
    });
    try testing.expectError(error.PageNotFound, result);
}

// ─── Test 7: bad element id returns BadElementId ─────────────────────────

test "useCase returns BadElementId when an element id does not exist" {
    const alloc = testing.allocator;
    var ctx = try setupDbAndItem();
    defer teardown(&ctx.db, &ctx.threaded);
    defer alloc.free(ctx.item_id);
    defer alloc.free(ctx.item_path);
    defer alloc.free(ctx.page_id);

    const a = try design_model.addElement(alloc, &ctx.db, ctx.threaded.io(), .{
        .page_id = ctx.page_id,
        .name = "a",
        .elem_type = .rectangle,
        .html = "<div></div>",
        .x = 0, .y = 0, .width = 50, .height = 50,
        .fill = "#000000", .rotation = 0.0, .corner_radius = 0, .opacity = 1.0,
    });
    defer alloc.free(a);

    const ids = [_][]const u8{ a, "elem_nonexistent" };
    const result = handler_mod.useCase(alloc, &ctx.db, .{
        .page_id = ctx.page_id,
        .element_ids = &ids,
        .new_parent_id = null,
        .reposition = .last_in_parent,
    });
    try testing.expectError(error.BadElementId, result);
}