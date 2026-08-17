//! Behavioural tests for the `POST .../translate` handler.
//!
//! Plan: docs/superpowers/plans/2026-08-06-split-move-resize.md
//!   (Task 1.1: split /geometry into /translate + /resize)

const std = @import("std");
const nalarcore = @import("nalarcore");
const sqlite = nalarcore.sqlite;
const design_model = @import("../agentic_loop/design_model.zig");
const http_handlers = @import("../http_handlers/mod.zig");
const migration = @import("../../../migrations/migration.zig");

const testing = std.testing;
const testing_alloc = testing.allocator;

const TranslateError = http_handlers.designElementsTranslateError;

const TestCtx = struct {
    db: sqlite.SqliteBackend,
    threaded: std.Io.Threaded,
    item_id: []const u8,
    page_id: []u8,
    tmpdir_path: []u8,
};

fn teardownTranslateCtx(ctx: *TestCtx) void {
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
fn setupTranslateCtx() !TestCtx {
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

    const item_id = try testing_alloc.dupe(u8, "item_translate_test");
    errdefer testing_alloc.free(item_id);
    try db.exec(testing_alloc,
        "INSERT INTO workspace_items (id, workspace_id, item_type, path) " ++
        "VALUES (?, 'ws_test', 'design', ?)",
        &.{ item_id, tmpdir_path });

    const page_id = try design_model.setDesignPage(testing_alloc, &db, .{
        .item_id = item_id,
        .page_name = "Translate Test",
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

fn insertTranslateElement(
    alloc: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    page_id: []const u8,
    name: []const u8,
    elem_type: []const u8,
    x: i64,
    y: i64,
    width: i64,
    height: i64,
    parent_id: []const u8,
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
    const parent_to_bind: []const u8 = if (parent_id.len == 0) "" else parent_id;

    try db.exec(alloc,
        \\INSERT INTO design_page_elements (
        \\    id, page_id, name, file_path, x, y, width, height,
        \\    z_index, position, type, rotation,
        \\    fill, stroke, stroke_width, corner_radius, opacity,
        \\    text_content, text_style, image_url, parent_id,
        \\    created_at, updated_at
        \\) VALUES (
        \\    ?, ?, ?, '', ?, ?, ?, ?,
        \\    0, 0, ?, 0,
        \\    '', '', 0, 0, 1.0,
        \\    '', '', '', ?,
        \\    datetime('now'), datetime('now')
        \\)
    , &.{ id, page_id, name, x_str, y_str, w_str, h_str, elem_type, parent_to_bind });

    return id;
}

test "useCase translates a leaf rectangle by (dx, dy) and returns 1 element" {
    const alloc = testing_alloc;
    var ctx = try setupTranslateCtx();
    defer teardownTranslateCtx(&ctx);

    const rect = try insertTranslateElement(alloc, &ctx.db, ctx.page_id, "r", "rectangle", 100, 200, 50, 50, "");
    defer alloc.free(rect);

    const output = try http_handlers.designElementsTranslateUseCase(alloc, &ctx.db, ctx.page_id, rect, 30, -10);
    defer design_model.freeElements(alloc, output.updated);

    try testing.expectEqual(@as(usize, 1), output.updated.len);
    try testing.expectEqual(@as(i64, 130), output.updated[0].x);
    try testing.expectEqual(@as(i64, 190), output.updated[0].y);
    try testing.expect(output.updated[0].id.len > 0);
}

test "useCase translates a group and CASCADES the delta to its descendants (the user's bug-fix requirement)" {
    const alloc = testing_alloc;
    var ctx = try setupTranslateCtx();
    defer teardownTranslateCtx(&ctx);

    // Layout:
    //   group G (x=50, y=100) — type='group'
    //     child1 c1 (x=60, y=110, parent=G) — type='rectangle'
    //     child2 c2 (x=200, y=200, parent=G) — type='rectangle'
    const group = try insertTranslateElement(alloc, &ctx.db, ctx.page_id, "g", "group", 50, 100, 200, 200, "");
    defer alloc.free(group);
    const child1 = try insertTranslateElement(alloc, &ctx.db, ctx.page_id, "c1", "rectangle", 60, 110, 30, 30, group);
    defer alloc.free(child1);
    const child2 = try insertTranslateElement(alloc, &ctx.db, ctx.page_id, "c2", "rectangle", 200, 200, 30, 30, group);
    defer alloc.free(child2);

    const output = try http_handlers.designElementsTranslateUseCase(alloc, &ctx.db, ctx.page_id, group, 100, 50);
    defer design_model.freeElements(alloc, output.updated);

    // Should return group + 2 children = 3 elements.
    try testing.expectEqual(@as(usize, 3), output.updated.len);

    // Build a map of id → updated row for stable assertions.
    var found_g: bool = false;
    var found_c1: bool = false;
    var found_c2: bool = false;
    for (output.updated) |el| {
        if (std.mem.eql(u8, el.id, group)) {
            try testing.expectEqual(@as(i64, 150), el.x);
            try testing.expectEqual(@as(i64, 150), el.y);
            found_g = true;
        } else if (std.mem.eql(u8, el.id, child1)) {
            try testing.expectEqual(@as(i64, 160), el.x);
            try testing.expectEqual(@as(i64, 160), el.y);
            found_c1 = true;
        } else if (std.mem.eql(u8, el.id, child2)) {
            try testing.expectEqual(@as(i64, 300), el.x);
            try testing.expectEqual(@as(i64, 250), el.y);
            found_c2 = true;
        }
    }
    try testing.expect(found_g);
    try testing.expect(found_c1);
    try testing.expect(found_c2);

    // DB-level confirmation: every cascaded row moved by the delta.
    try testing.expectEqual(@as(i64, 150), try readX(alloc, &ctx.db, group));
    try testing.expectEqual(@as(i64, 160), try readX(alloc, &ctx.db, child1));
    try testing.expectEqual(@as(i64, 300), try readX(alloc, &ctx.db, child2));
}

test "useCase cascades to grandchildren (depth 2)" {
    const alloc = testing_alloc;
    var ctx = try setupTranslateCtx();
    defer teardownTranslateCtx(&ctx);

    const outer = try insertTranslateElement(alloc, &ctx.db, ctx.page_id, "outer", "group", 0, 0, 200, 200, "");
    defer alloc.free(outer);
    const inner = try insertTranslateElement(alloc, &ctx.db, ctx.page_id, "inner", "group", 50, 50, 100, 100, outer);
    defer alloc.free(inner);
    const leaf = try insertTranslateElement(alloc, &ctx.db, ctx.page_id, "leaf", "rectangle", 70, 70, 30, 30, inner);
    defer alloc.free(leaf);

    const output = try http_handlers.designElementsTranslateUseCase(alloc, &ctx.db, ctx.page_id, outer, 5, 7);
    defer design_model.freeElements(alloc, output.updated);

    try testing.expectEqual(@as(usize, 3), output.updated.len);

    try testing.expectEqual(@as(i64, 5), try readX(alloc, &ctx.db, outer));
    try testing.expectEqual(@as(i64, 55), try readX(alloc, &ctx.db, inner));
    try testing.expectEqual(@as(i64, 75), try readX(alloc, &ctx.db, leaf));
}

test "useCase returns ElementNotFound for an unknown element_id" {
    const alloc = testing_alloc;
    var ctx = try setupTranslateCtx();
    defer teardownTranslateCtx(&ctx);

    const result = http_handlers.designElementsTranslateUseCase(alloc, &ctx.db, ctx.page_id, "elem_does_not_exist", 0, 0);
    try testing.expectError(error.ElementNotFound, result);
}

test "useCase returns ElementIdRequired for an empty element_id" {
    const alloc = testing_alloc;
    var ctx = try setupTranslateCtx();
    defer teardownTranslateCtx(&ctx);

    const result = http_handlers.designElementsTranslateUseCase(alloc, &ctx.db, ctx.page_id, "", 0, 0);
    try testing.expectError(error.ElementIdRequired, result);
}

fn readX(alloc: std.mem.Allocator, db: *sqlite.SqliteBackend, id: []const u8) !i64 {
    var q = try db.query(alloc, "SELECT x FROM design_page_elements WHERE id = ?", &.{id});
    defer q.deinit();
    const row = (try q.next()) orelse unreachable;
    defer row.deinit(alloc);
    return std.fmt.parseInt(i64, row.values[0], 10) catch 0;
}
