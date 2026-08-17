//! Behavioural tests for the `set_element_parent` LLM tool —
//! re-parents an existing element to a new group/frame, or back to
//! top-level via `null`.
//!
//! Plan: docs/superpowers/plans/2026-07-29-design-element-parent-id-tools.md
//! (Task 5)
//!
//! Tests:
//!   1. set_element_parent moves a top-level element into an existing
//!      group; the DB row is updated (verified via design_model.getElement).
//!   2. set_element_parent rejects a leaf-type parent (rectangle)
//!      with a structured error (the LLM can self-correct).
//!   3. set_element_parent rejects a non-existent element_id.
//!   4. set_element_parent to a non-existent parent_id errors.
//!   5. set_element_parent invalid element_id prefix returns XML error.

const std = @import("std");
const testing = std.testing;
const nalarcore = @import("nalarcore");
const sqlite = nalarcore.sqlite;

const set_element_parent = @import("set_element_parent.zig");
const design_model = @import("../../../ai_workflow/tui/agentic_loop/design_model.zig");

/// Open a fresh in-memory sqlite DB with the v6 design schema. Same
/// shape as the other test files (`setupDbAndItem`) — copied locally
/// for self-containment.
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

    const item_id_const = "item_design_set_parent_tool";
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

// ─── Test 1: happy path — re-parent into an existing frame ───────────────

test "executeSetElementParentToString moves element into existing group" {
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

    // Call the LLM tool.
    const xml = try set_element_parent.executeSetElementParentToString(alloc, &ctx.db, .{
        .element_id = child_id,
        .new_parent_id = group_id,
    });
    defer alloc.free(xml);
    // Tool response shape: `<set_element_parent><element id="..." parent_id="..." .../></set_element_parent>`.
    // It must NOT contain `<error>` on the happy path.
    try testing.expect(!std.mem.containsAtLeast(u8, xml, 1, "<error>"));
    try testing.expect(std.mem.indexOf(u8, xml, "<set_element_parent>") != null);
    try testing.expect(std.mem.indexOf(u8, xml, group_id) != null);

    // Verify the DB state directly (round-trip via design_model).
    const got = try design_model.getElement(alloc, &ctx.db, child_id);
    defer design_model.freeElement(alloc, got);
    try testing.expectEqualStrings(group_id, got.parent_id);
}

// ─── Test 2: reject leaf-type parent ──────────────────────────────────────

test "executeSetElementParentToString rejects leaf-type parent" {
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
        .name = "leaf",
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

    const xml = try set_element_parent.executeSetElementParentToString(alloc, &ctx.db, .{
        .element_id = child_id,
        .new_parent_id = leaf_id,
    });
    defer alloc.free(xml);
    try testing.expect(std.mem.indexOf(u8, xml, "<error>") != null);
    try testing.expect(std.mem.indexOf(u8, xml, "group") != null); // error mentions "group or frame"
}

// ─── Test 3: reject non-existent element_id ──────────────────────────────

test "executeSetElementParentToString rejects non-existent element_id" {
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

    const xml = try set_element_parent.executeSetElementParentToString(alloc, &ctx.db, .{
        .element_id = "elem_does_not_exist",
        .new_parent_id = group_id,
    });
    defer alloc.free(xml);
    try testing.expect(std.mem.indexOf(u8, xml, "<error>") != null);
}

// ─── Test 4: invalid element_id prefix returns XML error ──────────────────

test "executeSetElementParentToString rejects element_id with invalid prefix" {
    const alloc = testing.allocator;
    var ctx = try setupDbAndItem();
    defer teardown(&ctx.db, &ctx.threaded);
    defer alloc.free(ctx.item_id);
    defer alloc.free(ctx.item_path);

    const xml = try set_element_parent.executeSetElementParentToString(alloc, &ctx.db, .{
        .element_id = "not_elem_anything",
        .new_parent_id = "elem_anything",
    });
    defer alloc.free(xml);
    try testing.expect(std.mem.indexOf(u8, xml, "<error>") != null);
    try testing.expect(std.mem.indexOf(u8, xml, "element_id") != null);
}

// ─── Test 5: set_element_parent to null moves element to top-level ─────

test "executeSetElementParentToString with null moves element to top-level" {
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

    // Create a child with parent_id = group_id via direct SQL
    // (addElement always sets parent_id = NULL).
    try ctx.db.exec(alloc,
        \\INSERT INTO design_page_elements
        \\   (id, page_id, name, file_path, x, y, width, height, z_index, position,
        \\    type, rotation, fill, stroke, stroke_width, corner_radius, opacity,
        \\    text_content, text_style, image_url, parent_id,
        \\    created_at, updated_at)
        \\VALUES
        \\   ('elem_inner', ?, 'inner', '', 10, 10, 20, 20, 0, 0,
        \\    'rectangle', 0.0, '', '', 0, 0, 1.0,
        \\    '', '', '', ?, datetime('now'), datetime('now'))
    , &.{ page_id, group_id });

    // Call set_element_parent with null.
    const xml = try set_element_parent.executeSetElementParentToString(alloc, &ctx.db, .{
        .element_id = "elem_inner",
        .new_parent_id = null,
    });
    defer alloc.free(xml);
    try testing.expect(!std.mem.containsAtLeast(u8, xml, 1, "<error>"));

    // Verify DB state.
    const got = try design_model.getElement(alloc, &ctx.db, "elem_inner");
    defer design_model.freeElement(alloc, got);
    try testing.expectEqual(@as(usize, 0), got.parent_id.len);
}
