//! Behavioural tests for `updateElementsBatch` — atomic N-element
//! geometry update in a single SQL transaction.
//!
//! Plan: docs/superpowers/plans/2026-07-30-design-drag-debounce-batch.md
//! (Chunk 1, Task 1.1) — the backend mitigation that collapses N
//! per-element PATCHes into one PATCH for multi-element drag.
//!
//! Tests:
//!   1. updateElementsBatch moves 3 elements in one transaction and
//!      returns updated rows in input order.
//!   2. updateElementsBatch rejects empty input with EmptyUpdates.
//!   3. updateElementsBatch rolls back when ANY element_id is missing
//!      (no partial writes — the transaction is atomic).
//!   4. updateElementsBatch accepts a single-element batch (N=1).
//!   5. updateElementsBatch preserves untouched fields when only one
//!      geometry field is in the update (e.g. y only → x unchanged).

const std = @import("std");
const testing = std.testing;
const nalarcore = @import("nalarcore");
const sqlite = nalarcore.sqlite;

const design_model = @import("design_model.zig");

/// Open a fresh in-memory sqlite DB with the minimum tables needed for
/// the design SQL. Same shape as `design_model_set_element_parent_test.zig`.
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

    const item_id_const = "item_design_geometry_batch";
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

/// Insert a single design_page_elements row via raw SQL and return the
/// assigned id. The model layer's `addElement` is too heavy (creates
/// the on-disk HTML file, runs INSERT-or-UPDATE on parent_id, etc.) —
/// these tests want raw-row inserts so they can focus on
/// `updateElementsBatch` semantics.
fn insertElementRaw(
    alloc: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    page_id: []const u8,
    name: []const u8,
    x: i64,
    y: i64,
    width: i64,
    height: i64,
) ![]u8 {
    const id = try std.fmt.allocPrint(alloc, "elem_{s}", .{name});
    errdefer alloc.free(id);
    const x_str = try std.fmt.allocPrint(alloc, "{d}", .{x});
    defer alloc.free(x_str);
    const y_str = try std.fmt.allocPrint(alloc, "{d}", .{y});
    defer alloc.free(y_str);
    const w_str = try std.fmt.allocPrint(alloc, "{d}", .{width});
    defer alloc.free(w_str);
    const h_str = try std.fmt.allocPrint(alloc, "{d}", .{height});
    defer alloc.free(h_str);

    try db.exec(alloc,
        \\INSERT INTO design_page_elements (
        \\    id, page_id, name, file_path, x, y, width, height,
        \\    z_index, position, type, rotation,
        \\    fill, stroke, stroke_width, corner_radius, opacity,
        \\    text_content, text_style, image_url, parent_id,
        \\    created_at, updated_at
        \\) VALUES (
        \\    ?, ?, ?, '', ?, ?, ?, ?,
        \\    0, 0, 'rectangle', 0,
        \\    '', '', 0, 0, 1.0,
        \\    '', '', '', NULL,
        \\    datetime('now'), datetime('now')
        \\)
    , &.{ id, page_id, name, x_str, y_str, w_str, h_str });

    return id;
}

// ─── Test 1: happy path — 3 elements in one tx, returned in input order ──

test "updateElementsBatch moves 3 elements in one transaction and returns updated rows in input order" {
    const alloc = testing.allocator;
    var ctx = try setupDbAndItem();
    defer teardown(&ctx.db, &ctx.threaded);
    defer alloc.free(ctx.item_id);
    defer alloc.free(ctx.item_path);

    const page_id = try design_model.setDesignPage(alloc, &ctx.db, .{
        .item_id = ctx.item_id,
        .page_name = "Test Page",
        .width = 1440,
        .height = 1024,
    });
    defer alloc.free(page_id);

    const a = try insertElementRaw(alloc, &ctx.db, page_id, "a", 0, 0, 100, 100);
    defer alloc.free(a);
    const b = try insertElementRaw(alloc, &ctx.db, page_id, "b", 0, 0, 100, 100);
    defer alloc.free(b);
    const c = try insertElementRaw(alloc, &ctx.db, page_id, "c", 0, 0, 100, 100);
    defer alloc.free(c);

    const result = try design_model.updateElementsBatch(alloc, &ctx.db, .{
        .page_id = page_id,
        .updates = &.{
            .{ .element_id = a, .x = 100 },
            .{ .element_id = b, .x = 200 },
            .{ .element_id = c, .x = 300 },
        },
    });
    defer design_model.freeElements(alloc, result);

    try testing.expectEqual(@as(usize, 3), result.len);
    // Returned in input order: a, b, c (not sorted by id).
    try testing.expectEqualStrings(a, result[0].id);
    try testing.expectEqualStrings(b, result[1].id);
    try testing.expectEqualStrings(c, result[2].id);
    try testing.expectEqual(@as(i64, 100), result[0].x);
    try testing.expectEqual(@as(i64, 200), result[1].x);
    try testing.expectEqual(@as(i64, 300), result[2].x);

    // DB state mirrors the response.
    const all = try design_model.listElements(alloc, &ctx.db, page_id);
    defer design_model.freeElements(alloc, all);
    try testing.expectEqual(@as(usize, 3), all.len);
    for (all) |el| {
        if (std.mem.eql(u8, el.id, a)) try testing.expectEqual(@as(i64, 100), el.x);
        if (std.mem.eql(u8, el.id, b)) try testing.expectEqual(@as(i64, 200), el.x);
        if (std.mem.eql(u8, el.id, c)) try testing.expectEqual(@as(i64, 300), el.x);
    }
}

// ─── Test 2: empty input rejected ────────────────────────────────────────

test "updateElementsBatch rejects empty input with EmptyUpdates" {
    const alloc = testing.allocator;
    var ctx = try setupDbAndItem();
    defer teardown(&ctx.db, &ctx.threaded);
    defer alloc.free(ctx.item_id);
    defer alloc.free(ctx.item_path);

    const page_id = try design_model.setDesignPage(alloc, &ctx.db, .{
        .item_id = ctx.item_id,
        .page_name = "Empty Page",
        .width = 1440,
        .height = 1024,
    });
    defer alloc.free(page_id);

    const result = design_model.updateElementsBatch(alloc, &ctx.db, .{
        .page_id = page_id,
        .updates = &.{},
    });
    try testing.expectError(error.EmptyUpdates, result);
}

// ─── Test 3: atomicity — bad element_id rolls back the whole batch ──────

test "updateElementsBatch rolls back when ANY element_id is missing (no partial writes)" {
    const alloc = testing.allocator;
    var ctx = try setupDbAndItem();
    defer teardown(&ctx.db, &ctx.threaded);
    defer alloc.free(ctx.item_id);
    defer alloc.free(ctx.item_path);

    const page_id = try design_model.setDesignPage(alloc, &ctx.db, .{
        .item_id = ctx.item_id,
        .page_name = "Atomicity Page",
        .width = 1440,
        .height = 1024,
    });
    defer alloc.free(page_id);

    const a = try insertElementRaw(alloc, &ctx.db, page_id, "a", 0, 0, 100, 100);
    defer alloc.free(a);
    const b = try insertElementRaw(alloc, &ctx.db, page_id, "b", 0, 0, 100, 100);
    defer alloc.free(b);

    // Snapshot pre-batch DB state.
    var pre_a_x: i64 = 0;
    var pre_b_x: i64 = 0;
    {
        const all = try design_model.listElements(alloc, &ctx.db, page_id);
        defer design_model.freeElements(alloc, all);
        for (all) |el| {
            if (std.mem.eql(u8, el.id, a)) pre_a_x = el.x;
            if (std.mem.eql(u8, el.id, b)) pre_b_x = el.x;
        }
    }

    // Batch contains a non-existent id — must roll back atomically.
    const result = design_model.updateElementsBatch(alloc, &ctx.db, .{
        .page_id = page_id,
        .updates = &.{
            .{ .element_id = a, .x = 100 },
            .{ .element_id = "elem_missing", .x = 200 },
            .{ .element_id = b, .x = 300 },
        },
    });
    try testing.expectError(error.ElementNotFound, result);

    // Verify NOTHING was committed.
    const post = try design_model.listElements(alloc, &ctx.db, page_id);
    defer design_model.freeElements(alloc, post);
    try testing.expectEqual(@as(usize, 2), post.len);
    for (post) |el| {
        if (std.mem.eql(u8, el.id, a)) try testing.expectEqual(pre_a_x, el.x);
        if (std.mem.eql(u8, el.id, b)) try testing.expectEqual(pre_b_x, el.x);
    }
}

// ─── Test 4: single-element batch works (N=1) ──────────────────────────────

test "updateElementsBatch accepts a single-element batch (N=1)" {
    const alloc = testing.allocator;
    var ctx = try setupDbAndItem();
    defer teardown(&ctx.db, &ctx.threaded);
    defer alloc.free(ctx.item_id);
    defer alloc.free(ctx.item_path);

    const page_id = try design_model.setDesignPage(alloc, &ctx.db, .{
        .item_id = ctx.item_id,
        .page_name = "Single Page",
        .width = 1440,
        .height = 1024,
    });
    defer alloc.free(page_id);

    const a = try insertElementRaw(alloc, &ctx.db, page_id, "a", 0, 0, 100, 100);
    defer alloc.free(a);

    const result = try design_model.updateElementsBatch(alloc, &ctx.db, .{
        .page_id = page_id,
        .updates = &.{.{ .element_id = a, .x = 999 }},
    });
    defer design_model.freeElements(alloc, result);

    try testing.expectEqual(@as(usize, 1), result.len);
    try testing.expectEqualStrings(a, result[0].id);
    try testing.expectEqual(@as(i64, 999), result[0].x);
}

// ─── Test 5: partial field update — x only → y unchanged ─────────────────

test "updateElementsBatch accepts a single field per update (no other fields required)" {
    const alloc = testing.allocator;
    var ctx = try setupDbAndItem();
    defer teardown(&ctx.db, &ctx.threaded);
    defer alloc.free(ctx.item_id);
    defer alloc.free(ctx.item_path);

    const page_id = try design_model.setDesignPage(alloc, &ctx.db, .{
        .item_id = ctx.item_id,
        .page_name = "Partial Page",
        .width = 1440,
        .height = 1024,
    });
    defer alloc.free(page_id);

    // Insert at (50, 50, 200, 200).
    const a = try insertElementRaw(alloc, &ctx.db, page_id, "a", 50, 50, 200, 200);
    defer alloc.free(a);

    // Batch with ONLY y changed.
    const result = try design_model.updateElementsBatch(alloc, &ctx.db, .{
        .page_id = page_id,
        .updates = &.{.{ .element_id = a, .y = 75 }},
    });
    defer design_model.freeElements(alloc, result);

    try testing.expectEqual(@as(usize, 1), result.len);
    try testing.expectEqual(@as(i64, 50), result[0].x); // unchanged
    try testing.expectEqual(@as(i64, 75), result[0].y); // updated
    try testing.expectEqual(@as(i64, 200), result[0].width); // unchanged
    try testing.expectEqual(@as(i64, 200), result[0].height); // unchanged
}