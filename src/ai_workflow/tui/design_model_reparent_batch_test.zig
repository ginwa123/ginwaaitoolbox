//! Behavioural tests for `design_model.reparentElements` — the atomic
//! N-element reparent model function backing the new
//! `POST .../elements/reparent-batch` endpoint.
//!
//! Plan: docs/superpowers/plans/2026-07-30-design-layer-drag-join-or-leave-group.md
//! (Chunk 1b — Tasks 1b.1, 1b.2)
//!
//! Tests:
//!   1. reparentElements moves 3 top-level leaves into a group; positions
//!      are 0, 1, 2 (preserving input order).
//!   2. reparentElements leaves parent_id NULL when new_parent_id is null.
//!   3. reparentElements returns CycleDetected if ANY element would cycle,
//!      rejecting the whole batch (DB unchanged).
//!   4. reparentElements returns CrossPageIds when any element is on a
//!      different page.
//!   5. reparentElements returns BadNewParentId when the new parent is a
//!      leaf type (not a container).
//!   6. reparentElements returns BadNewParentId when the new parent does
//!      not exist.
//!   7. reparentElements returns EmptyElementIds for an empty input list.
//!   8. reparentElements returns BadElementId when an id does not exist.

const std = @import("std");
const testing = std.testing;
const nalarcore = @import("nalarcore");
const sqlite = nalarcore.sqlite;

const design_model = @import("design_model.zig");

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

    const item_id_const = "item_design_reparent_batch";
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

// ─── Test 1: 3 leaves moved into a group in one transaction ──────────────

test "reparentElements moves 3 top-level leaves into a group; positions are 0, 1, 2" {
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
        .name = "leaf-a",
        .elem_type = .rectangle,
        .html = "<div></div>",
        .x = 110, .y = 220, .width = 80, .height = 30,
        .fill = "#000000", .rotation = 0.0, .corner_radius = 0, .opacity = 1.0,
    });
    defer alloc.free(a_id);
    const b_id = try design_model.addElement(alloc, &ctx.db, ctx.threaded.io(), .{
        .page_id = ctx.page_id,
        .name = "leaf-b",
        .elem_type = .rectangle,
        .html = "<div></div>",
        .x = 200, .y = 220, .width = 80, .height = 30,
        .fill = "#000000", .rotation = 0.0, .corner_radius = 0, .opacity = 1.0,
    });
    defer alloc.free(b_id);
    const c_id = try design_model.addElement(alloc, &ctx.db, ctx.threaded.io(), .{
        .page_id = ctx.page_id,
        .name = "leaf-c",
        .elem_type = .rectangle,
        .html = "<div></div>",
        .x = 300, .y = 220, .width = 80, .height = 30,
        .fill = "#000000", .rotation = 0.0, .corner_radius = 0, .opacity = 1.0,
    });
    defer alloc.free(c_id);

    // Batch reparent all 3 into the group.
    const ids = [_][]const u8{ a_id, b_id, c_id };
    const updated = try design_model.reparentElements(alloc, &ctx.db, .{
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

    // Verify positions are 0, 1, 2 (preserving input order).
    const got_a = try design_model.getElement(alloc, &ctx.db, a_id);
    defer design_model.freeElement(alloc, got_a);
    const got_b = try design_model.getElement(alloc, &ctx.db, b_id);
    defer design_model.freeElement(alloc, got_b);
    const got_c = try design_model.getElement(alloc, &ctx.db, c_id);
    defer design_model.freeElement(alloc, got_c);

    try testing.expectEqualStrings(group_id, got_a.parent_id);
    try testing.expectEqual(@as(i64, 0), got_a.position);
    try testing.expectEqualStrings(group_id, got_b.parent_id);
    try testing.expectEqual(@as(i64, 1), got_b.position);
    try testing.expectEqualStrings(group_id, got_c.parent_id);
    try testing.expectEqual(@as(i64, 2), got_c.position);
}

// ─── Test 2: batch with new_parent_id = null moves elements to top-level ─

test "reparentElements with new_parent_id = null moves elements to top-level" {
    const alloc = testing.allocator;
    var ctx = try setupDbAndItem();
    defer teardown(&ctx.db, &ctx.threaded);
    defer alloc.free(ctx.item_id);
    defer alloc.free(ctx.item_path);
    defer alloc.free(ctx.page_id);

    // Manually INSERT two leaves nested under a group.
    try ctx.db.exec(alloc,
        \\INSERT INTO design_page_elements
        \\   (id, page_id, name, file_path, x, y, width, height, z_index, position,
        \\    type, rotation, fill, stroke, stroke_width, corner_radius, opacity,
        \\    text_content, text_style, image_url, parent_id,
        \\    created_at, updated_at)
        \\VALUES
        \\   ('elem_g', ?, 'g', '', 0, 0, 100, 100, 0, 0,
        \\    'frame', 0.0, '', '', 0, 0, 1.0,
        \\    '', '', '', NULL, datetime('now'), datetime('now')),
        \\   ('elem_nested_1', ?, 'n1', '', 0, 0, 50, 50, 0, 0,
        \\    'rectangle', 0.0, '', '', 0, 0, 1.0,
        \\    '', '', '', 'elem_g', datetime('now'), datetime('now')),
        \\   ('elem_nested_2', ?, 'n2', '', 0, 0, 50, 50, 0, 1,
        \\    'rectangle', 0.0, '', '', 0, 0, 1.0,
        \\    '', '', '', 'elem_g', datetime('now'), datetime('now'))
    , &.{ctx.page_id, ctx.page_id, ctx.page_id});

    const ids = [_][]const u8{ "elem_nested_1", "elem_nested_2" };
    const updated = try design_model.reparentElements(alloc, &ctx.db, .{
        .page_id = ctx.page_id,
        .element_ids = &ids,
        .new_parent_id = null,
        .reposition = .last_in_parent,
    });
    defer {
        for (updated) |e| design_model.freeElement(alloc, e);
        alloc.free(updated);
    }

    try testing.expectEqual(@as(usize, 2), updated.len);

    const got1 = try design_model.getElement(alloc, &ctx.db, "elem_nested_1");
    defer design_model.freeElement(alloc, got1);
    const got2 = try design_model.getElement(alloc, &ctx.db, "elem_nested_2");
    defer design_model.freeElement(alloc, got2);

    // COALESCE(parent_id, '') returns '' for NULL parent_ids.
    try testing.expectEqual(@as(usize, 0), got1.parent_id.len);
    try testing.expectEqual(@as(usize, 0), got2.parent_id.len);
}

// ─── Test 3: cycle in batch rejects everything atomically ────────────────

test "reparentElements returns CycleDetected if ANY element would cycle, rejecting the whole batch" {
    const alloc = testing.allocator;
    var ctx = try setupDbAndItem();
    defer teardown(&ctx.db, &ctx.threaded);
    defer alloc.free(ctx.item_id);
    defer alloc.free(ctx.item_path);
    defer alloc.free(ctx.page_id);

    // Manually INSERT: group_a (top-level), group_b parented to group_a,
    // leaf parented to group_b. Now try to reparent [leaf, group_a]
    // under group_b — group_a would close a cycle (group_a → ... →
    // group_b → group_a).
    try ctx.db.exec(alloc,
        \\INSERT INTO design_page_elements
        \\   (id, page_id, name, file_path, x, y, width, height, z_index, position,
        \\    type, rotation, fill, stroke, stroke_width, corner_radius, opacity,
        \\    text_content, text_style, image_url, parent_id,
        \\    created_at, updated_at)
        \\VALUES
        \\   ('elem_a', ?, 'a', '', 0, 0, 100, 100, 0, 0,
        \\    'frame', 0.0, '', '', 0, 0, 1.0,
        \\    '', '', '', NULL, datetime('now'), datetime('now')),
        \\   ('elem_b', ?, 'b', '', 0, 0, 100, 100, 0, 0,
        \\    'frame', 0.0, '', '', 0, 0, 1.0,
        \\    '', '', '', 'elem_a', datetime('now'), datetime('now')),
        \\   ('elem_leaf', ?, 'leaf', '', 0, 0, 50, 50, 0, 0,
        \\    'rectangle', 0.0, '', '', 0, 0, 1.0,
        \\    '', '', '', 'elem_b', datetime('now'), datetime('now'))
    , &.{ctx.page_id, ctx.page_id, ctx.page_id});

    const ids = [_][]const u8{ "elem_leaf", "elem_a" };
    const result = design_model.reparentElements(alloc, &ctx.db, .{
        .page_id = ctx.page_id,
        .element_ids = &ids,
        .new_parent_id = "elem_b",
        .reposition = .last_in_parent,
    });
    try testing.expectError(error.CycleDetected, result);

    // Verify DB state unchanged: group_a still top-level, leaf still
    // under group_b.
    const got_a = try design_model.getElement(alloc, &ctx.db, "elem_a");
    defer design_model.freeElement(alloc, got_a);
    try testing.expectEqual(@as(usize, 0), got_a.parent_id.len);

    const got_leaf = try design_model.getElement(alloc, &ctx.db, "elem_leaf");
    defer design_model.freeElement(alloc, got_leaf);
    try testing.expectEqualStrings("elem_b", got_leaf.parent_id);
}

// ─── Test 4: cross-page ids rejected ──────────────────────────────────────

test "reparentElements returns CrossPageIds when any element is on a different page" {
    const alloc = testing.allocator;
    var ctx = try setupDbAndItem();
    defer teardown(&ctx.db, &ctx.threaded);
    defer alloc.free(ctx.item_id);
    defer alloc.free(ctx.item_path);
    defer alloc.free(ctx.page_id);

    // Create a second page on the same item.
    const page2_id = try design_model.setDesignPage(alloc, &ctx.db, .{
        .item_id = ctx.item_id,
        .page_name = "Second",
        .width = 1440,
        .height = 1024,
    });
    defer alloc.free(page2_id);

    // Add a leaf on page 1 and a leaf on page 2.
    const leaf1 = try design_model.addElement(alloc, &ctx.db, ctx.threaded.io(), .{
        .page_id = ctx.page_id,
        .name = "leaf-on-page-1",
        .elem_type = .rectangle,
        .html = "<div></div>",
        .x = 0, .y = 0, .width = 50, .height = 50,
        .fill = "#000000", .rotation = 0.0, .corner_radius = 0, .opacity = 1.0,
    });
    defer alloc.free(leaf1);

    const leaf2 = try design_model.addElement(alloc, &ctx.db, ctx.threaded.io(), .{
        .page_id = page2_id,
        .name = "leaf-on-page-2",
        .elem_type = .rectangle,
        .html = "<div></div>",
        .x = 0, .y = 0, .width = 50, .height = 50,
        .fill = "#000000", .rotation = 0.0, .corner_radius = 0, .opacity = 1.0,
    });
    defer alloc.free(leaf2);

    // Add a group on page 1.
    const group = try design_model.addElement(alloc, &ctx.db, ctx.threaded.io(), .{
        .page_id = ctx.page_id,
        .name = "group",
        .elem_type = .frame,
        .html = "<div></div>",
        .x = 100, .y = 100, .width = 100, .height = 100,
        .fill = "#ffffff", .rotation = 0.0, .corner_radius = 0, .opacity = 1.0,
    });
    defer alloc.free(group);

    // Try to reparent both leaves under the group on page 1 — leaf2 is
    // on page 2 so this should fail with CrossPageIds.
    const ids = [_][]const u8{ leaf1, leaf2 };
    const result = design_model.reparentElements(alloc, &ctx.db, .{
        .page_id = ctx.page_id,
        .element_ids = &ids,
        .new_parent_id = group,
        .reposition = .last_in_parent,
    });
    try testing.expectError(error.CrossPageIds, result);
}

// ─── Test 5: bad new parent (leaf type) ─────────────────────────────────

test "reparentElements returns BadNewParentId when the new parent is a leaf type" {
    const alloc = testing.allocator;
    var ctx = try setupDbAndItem();
    defer teardown(&ctx.db, &ctx.threaded);
    defer alloc.free(ctx.item_id);
    defer alloc.free(ctx.item_path);
    defer alloc.free(ctx.page_id);

    const a_id = try design_model.addElement(alloc, &ctx.db, ctx.threaded.io(), .{
        .page_id = ctx.page_id,
        .name = "leaf-a",
        .elem_type = .rectangle,
        .html = "<div></div>",
        .x = 0, .y = 0, .width = 50, .height = 50,
        .fill = "#000000", .rotation = 0.0, .corner_radius = 0, .opacity = 1.0,
    });
    defer alloc.free(a_id);

    const b_id = try design_model.addElement(alloc, &ctx.db, ctx.threaded.io(), .{
        .page_id = ctx.page_id,
        .name = "leaf-b",
        .elem_type = .rectangle,
        .html = "<div></div>",
        .x = 60, .y = 0, .width = 50, .height = 50,
        .fill = "#000000", .rotation = 0.0, .corner_radius = 0, .opacity = 1.0,
    });
    defer alloc.free(b_id);

    // Try to reparent both leaves under leaf-a (a leaf can't contain children).
    const ids = [_][]const u8{ a_id, b_id };
    const result = design_model.reparentElements(alloc, &ctx.db, .{
        .page_id = ctx.page_id,
        .element_ids = &ids,
        .new_parent_id = a_id,
        .reposition = .last_in_parent,
    });
    try testing.expectError(error.BadNewParentId, result);
}

// ─── Test 6: non-existent new parent ─────────────────────────────────────

test "reparentElements returns BadNewParentId when the new parent does not exist" {
    const alloc = testing.allocator;
    var ctx = try setupDbAndItem();
    defer teardown(&ctx.db, &ctx.threaded);
    defer alloc.free(ctx.item_id);
    defer alloc.free(ctx.item_path);
    defer alloc.free(ctx.page_id);

    const a_id = try design_model.addElement(alloc, &ctx.db, ctx.threaded.io(), .{
        .page_id = ctx.page_id,
        .name = "leaf-a",
        .elem_type = .rectangle,
        .html = "<div></div>",
        .x = 0, .y = 0, .width = 50, .height = 50,
        .fill = "#000000", .rotation = 0.0, .corner_radius = 0, .opacity = 1.0,
    });
    defer alloc.free(a_id);

    const ids = [_][]const u8{a_id};
    const result = design_model.reparentElements(alloc, &ctx.db, .{
        .page_id = ctx.page_id,
        .element_ids = &ids,
        .new_parent_id = "elem_nonexistent",
        .reposition = .last_in_parent,
    });
    try testing.expectError(error.BadNewParentId, result);
}

// ─── Test 7: empty element_ids rejected ──────────────────────────────────

test "reparentElements returns EmptyElementIds for an empty input list" {
    const alloc = testing.allocator;
    var ctx = try setupDbAndItem();
    defer teardown(&ctx.db, &ctx.threaded);
    defer alloc.free(ctx.item_id);
    defer alloc.free(ctx.item_path);
    defer alloc.free(ctx.page_id);

    const ids = [_][]const u8{};
    const result = design_model.reparentElements(alloc, &ctx.db, .{
        .page_id = ctx.page_id,
        .element_ids = &ids,
        .new_parent_id = null,
        .reposition = .last_in_parent,
    });
    try testing.expectError(error.EmptyElementIds, result);
}

// ─── Test 8: bad element_id rejected ─────────────────────────────────────

test "reparentElements returns BadElementId when an id does not exist" {
    const alloc = testing.allocator;
    var ctx = try setupDbAndItem();
    defer teardown(&ctx.db, &ctx.threaded);
    defer alloc.free(ctx.item_id);
    defer alloc.free(ctx.item_path);
    defer alloc.free(ctx.page_id);

    const a_id = try design_model.addElement(alloc, &ctx.db, ctx.threaded.io(), .{
        .page_id = ctx.page_id,
        .name = "leaf-a",
        .elem_type = .rectangle,
        .html = "<div></div>",
        .x = 0, .y = 0, .width = 50, .height = 50,
        .fill = "#000000", .rotation = 0.0, .corner_radius = 0, .opacity = 1.0,
    });
    defer alloc.free(a_id);

    const ids = [_][]const u8{ a_id, "elem_nonexistent" };
    const result = design_model.reparentElements(alloc, &ctx.db, .{
        .page_id = ctx.page_id,
        .element_ids = &ids,
        .new_parent_id = null,
        .reposition = .last_in_parent,
    });
    try testing.expectError(error.BadElementId, result);
}