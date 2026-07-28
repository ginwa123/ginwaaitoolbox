//! Behavioural tests for `deleteElement` NULL-back-of-children.
//!
//! Plan: docs/superpowers/plans/2026-07-28-grouped-layers.md (Chunk 4)
//!
//! When a frame/group element is deleted, its children's `parent_id`
//! must be NULLed first so they become top-level again. Otherwise the
//! children would silently reference a non-existent parent. SQLite's
//! FK enforcement is OFF by default (no `PRAGMA foreign_keys = ON`),
//! so the handler MUST do the NULL-back explicitly.
//!
//! Order:
//!   1. UPDATE children SET parent_id = NULL WHERE parent_id = ?
//!   2. DELETE the parent element row.
//!   3. Delete the on-disk HTML file.
//!   4. Emit design_element_deleted SSE.

const std = @import("std");
const testing = std.testing;
const nalarcore = @import("nalarcore");
const sqlite = nalarcore.sqlite;

const design_model = @import("design_model.zig");

/// Same shape as design_model_test.zig::setupDbAndItem (kept inline
/// so this file is self-contained for the static checks).
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
        \\CREATE TABLE design_pages (
        \\    id TEXT PRIMARY KEY,
        \\    workspace_item_id TEXT NOT NULL,
        \\    name TEXT NOT NULL DEFAULT '',
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

    const item_id_const = "item_design_delete_parent";
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

/// Insert one design element with explicit (id, x, y, width, height,
/// parent_id) so we can build a parent + N children tree.
fn insertElement(
    alloc: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    id: []const u8,
    page_id: []const u8,
    name: []const u8,
    x: i64, y: i64, w: i64, h: i64,
    parent_id: []const u8,
) !void {
    const x_str = try std.fmt.allocPrint(alloc, "{d}", .{x});
    defer alloc.free(x_str);
    const y_str = try std.fmt.allocPrint(alloc, "{d}", .{y});
    defer alloc.free(y_str);
    const w_str = try std.fmt.allocPrint(alloc, "{d}", .{w});
    defer alloc.free(w_str);
    const h_str = try std.fmt.allocPrint(alloc, "{d}", .{h});
    defer alloc.free(h_str);
    try db.exec(alloc,
        \\INSERT INTO design_page_elements
        \\   (id, page_id, name, file_path, x, y, width, height, z_index, position,
        \\    type, rotation, fill, stroke, stroke_width, corner_radius, opacity,
        \\    text_content, text_style, image_url, parent_id,
        \\    created_at, updated_at)
        \\VALUES
        \\   (?, ?, ?, '', ?, ?, ?, ?, 0, 0,
        \\    'rectangle', 0.0, '#ffffff', '', 0, 0, 1.0,
        \\    '', '', '', ?, datetime('now'), datetime('now'))
    , &.{ id, page_id, name, x_str, y_str, w_str, h_str, parent_id });
}

/// Read parent_id of a row by id. Returns "NULL" when the column is
/// empty (NULL).
fn parentIdOf(alloc: std.mem.Allocator, db: *sqlite.SqliteBackend, id: []const u8) ![]u8 {
    var q = try db.query(alloc,
        "SELECT COALESCE(parent_id, 'NULL') FROM design_page_elements WHERE id = ?",
        &.{id});
    defer q.deinit();
    const row = (try q.next()) orelse return error.NotFound;
    defer row.deinit(alloc);
    return alloc.dupe(u8, row.values[0]);
}

// ─── Behavioural tests ───────────────────────────────────────────────────

test "deleteElement NULLs parent_id on children of a deleted parent" {
    const alloc = testing.allocator;
    var ctx = try setupDbAndItem();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();
    defer alloc.free(ctx.item_id);
    defer alloc.free(ctx.item_path);

    const page_id = try design_model.setDesignPage(alloc, &ctx.db, .{
        .item_id = ctx.item_id,
        .page_name = "Home",
        .width = 1440, .height = 1024,
    });
    defer alloc.free(page_id);

    // Build: parent (frame), with 2 children.
    try insertElement(alloc, &ctx.db, "elem_parent", page_id, "Parent", 0, 0, 200, 200, "");
    try insertElement(alloc, &ctx.db, "elem_child_a", page_id, "Child A", 10, 10, 50, 50, "elem_parent");
    try insertElement(alloc, &ctx.db, "elem_child_b", page_id, "Child B", 70, 70, 50, 50, "elem_parent");

    // Sanity: children have parent_id = elem_parent before delete.
    {
        const a_pid = try parentIdOf(alloc, &ctx.db, "elem_child_a");
        defer alloc.free(a_pid);
        try testing.expectEqualStrings("elem_parent", a_pid);

        const b_pid = try parentIdOf(alloc, &ctx.db, "elem_child_b");
        defer alloc.free(b_pid);
        try testing.expectEqualStrings("elem_parent", b_pid);
    }

    // Delete the parent.
    const was_deleted = try design_model.deleteElement(alloc, &ctx.db, "elem_parent");
    try testing.expect(was_deleted);

    // The children should STILL exist with parent_id = NULL
    // (i.e. they became top-level).
    const a_pid_after = try parentIdOf(alloc, &ctx.db, "elem_child_a");
    defer alloc.free(a_pid_after);
    try testing.expectEqualStrings("NULL", a_pid_after);

    const b_pid_after = try parentIdOf(alloc, &ctx.db, "elem_child_b");
    defer alloc.free(b_pid_after);
    try testing.expectEqualStrings("NULL", b_pid_after);

    // The parent itself should be gone (getElement returns ElementNotFound).
    const result = design_model.getElement(alloc, &ctx.db, "elem_parent");
    try testing.expectError(error.ElementNotFound, result);
}

test "deleteElement of a leaf element leaves no parent_id side-effects on others" {
    const alloc = testing.allocator;
    var ctx = try setupDbAndItem();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();
    defer alloc.free(ctx.item_id);
    defer alloc.free(ctx.item_path);

    const page_id = try design_model.setDesignPage(alloc, &ctx.db, .{
        .item_id = ctx.item_id,
        .page_name = "Home",
        .width = 1440, .height = 1024,
    });
    defer alloc.free(page_id);

    // 3 top-level elements (no parent_id anywhere). Deleting one
    // should not affect the others' parent_id state.
    try insertElement(alloc, &ctx.db, "elem_tl_1", page_id, "TL 1", 0, 0, 50, 50, "");
    try insertElement(alloc, &ctx.db, "elem_tl_2", page_id, "TL 2", 100, 0, 50, 50, "");
    try insertElement(alloc, &ctx.db, "elem_tl_3", page_id, "TL 3", 200, 0, 50, 50, "");

    const was_deleted = try design_model.deleteElement(alloc, &ctx.db, "elem_tl_2");
    try testing.expect(was_deleted);

    // elem_tl_1 and elem_tl_3 should still exist with NULL parent_id.
    const pid_1 = try parentIdOf(alloc, &ctx.db, "elem_tl_1");
    defer alloc.free(pid_1);
    try testing.expectEqualStrings("NULL", pid_1);

    const pid_3 = try parentIdOf(alloc, &ctx.db, "elem_tl_3");
    defer alloc.free(pid_3);
    try testing.expectEqualStrings("NULL", pid_3);
}

test "deleteElement of a parent with no children just deletes the row" {
    const alloc = testing.allocator;
    var ctx = try setupDbAndItem();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();
    defer alloc.free(ctx.item_id);
    defer alloc.free(ctx.item_path);

    const page_id = try design_model.setDesignPage(alloc, &ctx.db, .{
        .item_id = ctx.item_id,
        .page_name = "Home",
        .width = 1440, .height = 1024,
    });
    defer alloc.free(page_id);

    // Empty parent (no children reference it). Delete should be a
    // no-op for other rows + the parent row vanishes.
    try insertElement(alloc, &ctx.db, "elem_empty_parent", page_id, "EmptyParent", 0, 0, 100, 100, "");

    const was_deleted = try design_model.deleteElement(alloc, &ctx.db, "elem_empty_parent");
    try testing.expect(was_deleted);

    // The parent is gone.
    const result = design_model.getElement(alloc, &ctx.db, "elem_empty_parent");
    try testing.expectError(error.ElementNotFound, result);
}