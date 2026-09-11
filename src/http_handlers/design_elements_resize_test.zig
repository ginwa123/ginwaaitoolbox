//! Behavioural tests for the `POST .../resize` handler.
//!
//! Plan: docs/superpowers/plans/2026-08-06-split-move-resize.md
//!   (Task 1.2: split /geometry into /translate + /resize)

const std = @import("std");
const nalarcore = @import("nalarcore");
const sqlite = nalarcore.sqlite;
const design_model = @import("../agentic_loop/design_model.zig");
const http_handlers = @import("mod.zig");
const migration = @import("../migrations/migration.zig");

const testing = std.testing;
const testing_alloc = testing.allocator;

const TestCtx = struct {
    db: sqlite.SqliteBackend,
    threaded: std.Io.Threaded,
    item_id: []const u8,
    page_id: []u8,
    tmpdir_path: []u8,
};

fn teardownResizeCtx(ctx: *TestCtx) void {
    ctx.db.deinit();
    ctx.threaded.deinit();
    testing_alloc.free(ctx.item_id);
    testing_alloc.free(ctx.page_id);
    testing_alloc.free(ctx.tmpdir_path);
}

/// Open a fresh in-memory DB and walk every migration in
/// `src/migrations/migration.zig` so the schema matches production
/// exactly. We then seed one design item + page and return the
/// handles — tests insert their own elements from there.
fn setupResizeCtx() !TestCtx {
    var threaded = std.Io.Threaded.init(testing_alloc, .{});
    errdefer threaded.deinit();
    const io = threaded.io();

    var db: sqlite.SqliteBackend = .{};
    errdefer db.deinit();
    try db.init(io, ":memory:");

    var manager = migration.MigrationManager.init(testing_alloc, &db);
    defer manager.deinit();
    try migration.registerAllMigrations(&manager);
    try manager.runMigrations();

    var tmp = testing.tmpDir(.{});
    var tmpdir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmpdir_len = try tmp.dir.realPath(testing.io, &tmpdir_buf);
    const tmpdir_path = try testing_alloc.dupe(u8, tmpdir_buf[0..tmpdir_len]);
    errdefer testing_alloc.free(tmpdir_path);

    const item_id = try testing_alloc.dupe(u8, "item_resize_test");
    errdefer testing_alloc.free(item_id);
    try db.exec(testing_alloc,
        "INSERT INTO workspace_items (id, workspace_id, item_type, path) " ++
        "VALUES (?, 'ws_test', 'design', ?)",
        &.{ item_id, tmpdir_path });

    const page_id = try design_model.setDesignPage(testing_alloc, &db, .{
        .item_id = item_id,
        .page_name = "Resize Test",
        .width = 1440,
        .height = 1024,
    });
    errdefer testing_alloc.free(page_id);

    return .{
        .db = db,
        .threaded = threaded,
        .item_id = item_id,
        .page_id = page_id,
        .tmpdir_path = tmpdir_path,
    };
}

fn insertResizeElement(
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
        \\    '', '', '', '',
        \\    datetime('now'), datetime('now')
        \\)
    , &.{ id, page_id, name, x_str, y_str, w_str, h_str });

    return id;
}

test "useCase resizes a leaf with width and height" {
    const alloc = testing_alloc;
    var ctx = try setupResizeCtx();
    defer teardownResizeCtx(&ctx);

    const rect = try insertResizeElement(alloc, &ctx.db, ctx.page_id, "r", 0, 0, 100, 100);
    defer alloc.free(rect);

    const output = try http_handlers.designElementsResizeUseCase(alloc, &ctx.db, rect, null, null, 200, 250, null);
    defer design_model.freeElement(alloc, output.element);

    try testing.expectEqual(@as(i64, 200), output.element.width);
    try testing.expectEqual(@as(i64, 250), output.element.height);
    try testing.expectEqual(@as(i64, 0), output.element.x);
    try testing.expectEqual(@as(i64, 0), output.element.y);
}

test "useCase resizes a leaf with x and y" {
    const alloc = testing_alloc;
    var ctx = try setupResizeCtx();
    defer teardownResizeCtx(&ctx);

    const rect = try insertResizeElement(alloc, &ctx.db, ctx.page_id, "r", 0, 0, 100, 100);
    defer alloc.free(rect);

    const output = try http_handlers.designElementsResizeUseCase(alloc, &ctx.db, rect, 50, 75, null, null, null);
    defer design_model.freeElement(alloc, output.element);

    try testing.expectEqual(@as(i64, 50), output.element.x);
    try testing.expectEqual(@as(i64, 75), output.element.y);
    try testing.expectEqual(@as(i64, 100), output.element.width);
    try testing.expectEqual(@as(i64, 100), output.element.height);
}

test "useCase resizes a leaf with rotation" {
    const alloc = testing_alloc;
    var ctx = try setupResizeCtx();
    defer teardownResizeCtx(&ctx);

    const rect = try insertResizeElement(alloc, &ctx.db, ctx.page_id, "r", 0, 0, 100, 100);
    defer alloc.free(rect);

    const output = try http_handlers.designElementsResizeUseCase(alloc, &ctx.db, rect, null, null, null, null, 45.0);
    defer design_model.freeElement(alloc, output.element);

    try testing.expectApproxEqAbs(@as(f64, 45.0), output.element.rotation, 0.0001);
}

test "useCase resizes a GROUP without cascading to children (resize is per-element only)" {
    const alloc = testing_alloc;
    var ctx = try setupResizeCtx();
    defer teardownResizeCtx(&ctx);

    // group at (0, 0) 200x200
    // child1 at (10, 10) 50x50 (parent=group)
    // child2 at (100, 100) 50x50 (parent=group)
    const group = try design_model.addElement(alloc, &ctx.db, ctx.threaded.io(), .{
        .page_id = ctx.page_id,
        .name = "g",
        .elem_type = .group,
        .html = "<div></div>",
        .x = 0, .y = 0, .width = 200, .height = 200,
        .fill = "#000000", .rotation = 0.0, .corner_radius = 0, .opacity = 1.0,
    });
    defer alloc.free(group);

    const c1 = try design_model.addElement(alloc, &ctx.db, ctx.threaded.io(), .{
        .page_id = ctx.page_id,
        .name = "c1",
        .elem_type = .rectangle,
        .html = "<div></div>",
        .x = 10, .y = 10, .width = 50, .height = 50,
        .fill = "#000000", .rotation = 0.0, .corner_radius = 0, .opacity = 1.0,
        .parent_id = group,
    });
    defer alloc.free(c1);

    const output = try http_handlers.designElementsResizeUseCase(alloc, &ctx.db, group, 0, 0, 500, 500, null);
    defer design_model.freeElement(alloc, output.element);

    // Group is now 500x500.
    try testing.expectEqual(@as(i64, 500), output.element.width);
    try testing.expectEqual(@as(i64, 500), output.element.height);

    // CRITICAL: children MUST keep their own positions and sizes
    // (resize never cascades, by Figma convention).
    try testing.expectEqual(@as(i64, 10), try readX(alloc, &ctx.db, c1));
    try testing.expectEqual(@as(i64, 10), try readY(alloc, &ctx.db, c1));
    try testing.expectEqual(@as(i64, 50), try readWidth(alloc, &ctx.db, c1));
    try testing.expectEqual(@as(i64, 50), try readHeight(alloc, &ctx.db, c1));
}

test "useCase returns NoChanges when the body has no fields" {
    const alloc = testing_alloc;
    var ctx = try setupResizeCtx();
    defer teardownResizeCtx(&ctx);

    const rect = try insertResizeElement(alloc, &ctx.db, ctx.page_id, "r", 0, 0, 100, 100);
    defer alloc.free(rect);

    const result = http_handlers.designElementsResizeUseCase(alloc, &ctx.db, rect, null, null, null, null, null);
    try testing.expectError(error.NoChanges, result);
}

test "useCase returns ElementIdRequired for an empty element_id" {
    const alloc = testing_alloc;
    var ctx = try setupResizeCtx();
    defer teardownResizeCtx(&ctx);

    const result = http_handlers.designElementsResizeUseCase(alloc, &ctx.db, "", 0, 0, 100, 100, null);
    try testing.expectError(error.ElementIdRequired, result);
}

test "useCase returns ElementNotFound for an unknown element_id" {
    const alloc = testing_alloc;
    var ctx = try setupResizeCtx();
    defer teardownResizeCtx(&ctx);

    const result = http_handlers.designElementsResizeUseCase(alloc, &ctx.db, "elem_does_not_exist", 0, 0, 100, 100, null);
    try testing.expectError(error.ElementNotFound, result);
}

fn readX(alloc: std.mem.Allocator, db: *sqlite.SqliteBackend, id: []const u8) !i64 {
    return try readInt(alloc, db, id, "x");
}

fn readY(alloc: std.mem.Allocator, db: *sqlite.SqliteBackend, id: []const u8) !i64 {
    return try readInt(alloc, db, id, "y");
}

fn readWidth(alloc: std.mem.Allocator, db: *sqlite.SqliteBackend, id: []const u8) !i64 {
    return try readInt(alloc, db, id, "width");
}

fn readHeight(alloc: std.mem.Allocator, db: *sqlite.SqliteBackend, id: []const u8) !i64 {
    return try readInt(alloc, db, id, "height");
}

fn readInt(alloc: std.mem.Allocator, db: *sqlite.SqliteBackend, id: []const u8, col: []const u8) !i64 {
    const sql = try std.fmt.allocPrint(alloc, "SELECT {s} FROM design_page_elements WHERE id = ?", .{col});
    defer alloc.free(sql);
    var q = try db.query(alloc, sql, &.{id});
    defer q.deinit();
    const row = (try q.next()) orelse unreachable;
    defer row.deinit(alloc);
    return std.fmt.parseInt(i64, row.values[0], 10) catch 0;
}
