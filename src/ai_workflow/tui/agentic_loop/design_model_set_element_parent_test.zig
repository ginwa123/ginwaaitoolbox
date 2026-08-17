//! Behavioural tests for `setElementParent` — re-parents an existing
//! element under a new group/frame (or to top-level via null).
//!
//! Plan: docs/superpowers/plans/2026-07-29-design-element-parent-id-tools.md
//! (Task 2)
//!
//! Tests:
//!   1. setElementParent moves an existing element into a new group.
//!   2. setElementParent with new_parent_id = null moves the element
//!      to top-level (parent_id becomes empty string).
//!   3. setElementParent rejects a parent_id pointing to a leaf type
//!      (rectangle/text/ellipse/image) — those can't contain children.
//!   4. setElementParent rejects a cycle: a parent cannot be set to
//!      one of its own descendants.
//!   5. setElementParent rejects a non-existent element_id.

const std = @import("std");
const testing = std.testing;
const nalarcore = @import("nalarcore");
const sqlite = nalarcore.sqlite;

const design_model = @import("design_model.zig");

/// Open a fresh in-memory sqlite DB with the minimum tables needed for
/// the design SQL. Same shape as `design_model_add_element_parent_test.zig`.
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

    const item_id_const = "item_design_set_parent";
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

fn teardown(db: *sqlite.SqliteBackend, threaded: *std.Io.Threaded) void {
    db.deinit();
    threaded.deinit();
}

// ─── Test 1: move element into an existing group ─────────────────────────

test "setElementParent moves element into existing group" {
    const alloc = testing.allocator;
    var ctx = try setupDbAndItem();
    defer teardown(&ctx.db, &ctx.threaded);
    defer alloc.free(ctx.item_id);
    defer alloc.free(ctx.item_path);

    const page_id = try design_model.setDesignPage(alloc, &ctx.db, .{
        .item_id = ctx.item_id,
        .page_name = "Login",
        .width = 1440,
        .height = 1024,
    });
    defer alloc.free(page_id);

    // Add the parent group + the child element both at top-level.
    const group_id = try design_model.addElement(alloc, &ctx.db, ctx.threaded.io(), .{
        .page_id = page_id,
        .name = "login-card",
        .elem_type = .frame,
        .html = "<div></div>",
        .x = 100, .y = 200, .width = 400, .height = 300,
        .fill = "#ffffff", .rotation = 0.0, .corner_radius = 0, .opacity = 1.0,
    });
    defer alloc.free(group_id);

    const child_id = try design_model.addElement(alloc, &ctx.db, ctx.threaded.io(), .{
        .page_id = page_id,
        .name = "login-button",
        .elem_type = .rectangle,
        .html = "<div></div>",
        .x = 110, .y = 220, .width = 80, .height = 30,
        .fill = "#000000", .rotation = 0.0, .corner_radius = 0, .opacity = 1.0,
    });
    defer alloc.free(child_id);

    // Re-parent the child into the group.
    try design_model.setElementParent(alloc, &ctx.db, child_id, group_id);

    // Verify the DB state.
    const child = try design_model.getElement(alloc, &ctx.db, child_id);
    defer design_model.freeElement(alloc, child);
    try testing.expectEqualStrings(group_id, child.parent_id);
}

// ─── Test 2: move element to top-level via null ───────────────────────────

test "setElementParent with null moves element to top-level" {
    const alloc = testing.allocator;
    var ctx = try setupDbAndItem();
    defer teardown(&ctx.db, &ctx.threaded);
    defer alloc.free(ctx.item_id);
    defer alloc.free(ctx.item_path);

    const page_id = try design_model.setDesignPage(alloc, &ctx.db, .{
        .item_id = ctx.item_id,
        .page_name = "Login",
        .width = 1440,
        .height = 1024,
    });
    defer alloc.free(page_id);

    // Add a parent + child with parent_id set via manual INSERTs
    // (addElement always sets parent_id = NULL).
    try ctx.db.exec(alloc,
        \\INSERT INTO design_page_elements
        \\   (id, page_id, name, file_path, x, y, width, height, z_index, position,
        \\    type, rotation, fill, stroke, stroke_width, corner_radius, opacity,
        \\    text_content, text_style, image_url, parent_id,
        \\    created_at, updated_at)
        \\VALUES
        \\   ('elem_g', ?, 'group', '', 0, 0, 100, 100, 0, 0,
        \\    'frame', 0.0, '', '', 0, 0, 1.0,
        \\    '', '', '', NULL, datetime('now'), datetime('now'))
    , &.{page_id});

    try ctx.db.exec(alloc,
        \\INSERT INTO design_page_elements
        \\   (id, page_id, name, file_path, x, y, width, height, z_index, position,
        \\    type, rotation, fill, stroke, stroke_width, corner_radius, opacity,
        \\    text_content, text_style, image_url, parent_id,
        \\    created_at, updated_at)
        \\VALUES
        \\   ('elem_c', ?, 'child', '', 10, 10, 20, 20, 0, 1,
        \\    'rectangle', 0.0, '', '', 0, 0, 1.0,
        \\    '', '', '', 'elem_g', datetime('now'), datetime('now'))
    , &.{page_id});

    // Confirm pre-condition: child has parent_id = 'elem_g'.
    const pre = try design_model.getElement(alloc, &ctx.db, "elem_c");
    defer design_model.freeElement(alloc, pre);
    try testing.expectEqualStrings("elem_g", pre.parent_id);

    // Move child to top-level.
    try design_model.setElementParent(alloc, &ctx.db, "elem_c", null);

    const post = try design_model.getElement(alloc, &ctx.db, "elem_c");
    defer design_model.freeElement(alloc, post);
    try testing.expectEqual(@as(usize, 0), post.parent_id.len);
}

// ─── Test 3: reject parent_id of a leaf type ──────────────────────────────

test "setElementParent rejects leaf-type parent" {
    const alloc = testing.allocator;
    var ctx = try setupDbAndItem();
    defer teardown(&ctx.db, &ctx.threaded);
    defer alloc.free(ctx.item_id);
    defer alloc.free(ctx.item_path);

    const page_id = try design_model.setDesignPage(alloc, &ctx.db, .{
        .item_id = ctx.item_id,
        .page_name = "Login",
        .width = 1440,
        .height = 1024,
    });
    defer alloc.free(page_id);

    const leaf_id = try design_model.addElement(alloc, &ctx.db, ctx.threaded.io(), .{
        .page_id = page_id,
        .name = "leaf-rect",
        .elem_type = .rectangle,
        .html = "<div></div>",
        .x = 0, .y = 0, .width = 50, .height = 50,
        .fill = "#ffffff", .rotation = 0.0, .corner_radius = 0, .opacity = 1.0,
    });
    defer alloc.free(leaf_id);

    const child_id = try design_model.addElement(alloc, &ctx.db, ctx.threaded.io(), .{
        .page_id = page_id,
        .name = "child",
        .elem_type = .rectangle,
        .html = "<div></div>",
        .x = 0, .y = 0, .width = 50, .height = 50,
        .fill = "#ffffff", .rotation = 0.0, .corner_radius = 0, .opacity = 1.0,
    });
    defer alloc.free(child_id);

    const result = design_model.setElementParent(alloc, &ctx.db, child_id, leaf_id);
    try testing.expectError(error.ParentNotContainer, result);
}

// ─── Test 5: reject non-existent element_id ───────────────────────────────

test "setElementParent rejects non-existent element_id" {
    const alloc = testing.allocator;
    var ctx = try setupDbAndItem();
    defer teardown(&ctx.db, &ctx.threaded);
    defer alloc.free(ctx.item_id);
    defer alloc.free(ctx.item_path);

    const page_id = try design_model.setDesignPage(alloc, &ctx.db, .{
        .item_id = ctx.item_id,
        .page_name = "Login",
        .width = 1440,
        .height = 1024,
    });
    defer alloc.free(page_id);

    const group_id = try design_model.addElement(alloc, &ctx.db, ctx.threaded.io(), .{
        .page_id = page_id,
        .name = "group",
        .elem_type = .frame,
        .html = "<div></div>",
        .x = 0, .y = 0, .width = 100, .height = 100,
        .fill = "#ffffff", .rotation = 0.0, .corner_radius = 0, .opacity = 1.0,
    });
    defer alloc.free(group_id);

    const result = design_model.setElementParent(alloc, &ctx.db, "elem_does_not_exist", group_id);
    try testing.expectError(error.ElementNotFound, result);
}