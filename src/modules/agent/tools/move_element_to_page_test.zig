//! Behavioural tests for the `move_element_to_page` LLM tool.
//!
//! Plan: docs/superpowers/plans/2026-08-06-move-element-to-page.md (Chunk 3)
//!
//! 4 wiring tests: tool definition shape + happy-path DB execution +
//! error envelope on missing field + shape rejection of bad prefixes.
//! Follows the `move_design_element_test.zig` pattern (uses
//! `design_model.setDesignPage` + `addElement` to set up fixtures).

const std = @import("std");
const nalarcore = @import("nalarcore");
const sqlite = nalarcore.sqlite;
const design_model = nalarcore.ai_mod.design_model;
const move_element_to_page = @import("move_element_to_page.zig");
const testing = std.testing;

// =====================================================================
// Test fixtures
// =====================================================================

const TestCtx = struct {
    db: sqlite.SqliteBackend,
    threaded: std.Io.Threaded,
    item_id: []const u8,
    item_path: []u8,
};

fn setupDb() !TestCtx {
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
    const tmpdir_path = try alloc.dupe(u8, tmpdir_buf[0..tmpdir_len]);
    defer alloc.free(tmpdir_path);

    const item_id_const = "item_move_to_page_tool";
    try db.exec(alloc,
        "INSERT INTO workspace_items (id, workspace_id, item_type, path) " ++
        "VALUES (?, 'ws_test', 'design', ?)",
        &.{ item_id_const, tmpdir_path });

    const item_id_slice = try alloc.dupe(u8, item_id_const);
    return .{
        .db = db,
        .threaded = threaded,
        .item_id = item_id_slice,
        .item_path = try alloc.dupe(u8, tmpdir_path),
    };
}

fn teardownDb(ctx: *TestCtx) void {
    ctx.db.deinit();
    ctx.threaded.deinit();
    testing.allocator.free(ctx.item_id);
    testing.allocator.free(ctx.item_path);
}

// =====================================================================
// Tests
// =====================================================================

test "move_element_to_page_tool has the expected LLM-facing schema (name, required fields)" {
    const tool = move_element_to_page.move_element_to_page_tool;

    try testing.expectEqualStrings("function", tool.type);
    try testing.expectEqualStrings("move_element_to_page", tool.function.name);

    // element_id + new_page_id are required.
    try testing.expectEqual(@as(usize, 2), tool.function.parameters.required.len);
    var saw_element_id = false;
    var saw_new_page_id = false;
    for (tool.function.parameters.required) |r| {
        if (std.mem.eql(u8, r, "element_id")) saw_element_id = true;
        if (std.mem.eql(u8, r, "new_page_id")) saw_new_page_id = true;
    }
    try testing.expect(saw_element_id);
    try testing.expect(saw_new_page_id);

    // All three declared properties exist.
    var saw_apply_to_children = false;
    for (tool.function.parameters.properties) |p| {
        if (std.mem.eql(u8, p.name, "apply_to_children")) saw_apply_to_children = true;
    }
    try testing.expect(saw_apply_to_children);
}

test "executeMoveElementToPageToString returns a structured success XML on happy path" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer teardownDb(&ctx);

    // Use the production helpers (matches `move_design_element_test.zig`).
    const source_page_id = try design_model.setDesignPage(alloc, &ctx.db, .{
        .item_id = ctx.item_id,
        .page_name = "source",
        .width = 1440,
        .height = 1024,
    });
    defer alloc.free(source_page_id);
    const target_page_id = try design_model.setDesignPage(alloc, &ctx.db, .{
        .item_id = ctx.item_id,
        .page_name = "target",
        .width = 1440,
        .height = 1024,
    });
    defer alloc.free(target_page_id);

    const elem_id = try design_model.addElement(alloc, &ctx.db, ctx.threaded.io(), .{
        .page_id = source_page_id,
        .name = "leaf",
        .elem_type = .rectangle,
        .html = "<div></div>",
        .x = 10, .y = 20, .width = 50, .height = 50,
        .fill = "#000000", .rotation = 0.0, .corner_radius = 0, .opacity = 1.0,
    });
    defer alloc.free(elem_id);

    const xml = try move_element_to_page.executeMoveElementToPageToString(
        alloc, &ctx.db, source_page_id,
        .{ .element_id = elem_id, .new_page_id = target_page_id, .apply_to_children = true },
    );
    defer alloc.free(xml);

    // Response shape: <move_element_to_page><moved>...<element/>...</moved>...</move_element_to_page>.
    try testing.expect(std.mem.indexOf(u8, xml, "<move_element_to_page>") != null);
    try testing.expect(std.mem.indexOf(u8, xml, "</move_element_to_page>") != null);
    try testing.expect(std.mem.indexOf(u8, xml, "<moved>") != null);
    try testing.expect(std.mem.indexOf(u8, xml, "</moved>") != null);
    try testing.expect(std.mem.indexOf(u8, xml, elem_id) != null);
    try testing.expect(std.mem.indexOf(u8, xml, target_page_id) != null);
}

test "executeMoveElementToPageToString wraps the error in <move_element_to_page><error> on missing element_id" {
    const alloc = testing.allocator;
    const xml = try move_element_to_page.executeMoveElementToPageToString(
        alloc, undefined, // DB never reached (input validation fails first)
        "page_unused",
        .{ .element_id = "", .new_page_id = "page_target", .apply_to_children = true },
    );
    defer alloc.free(xml);

    try testing.expect(std.mem.indexOf(u8, xml, "<move_element_to_page><error>") != null);
    try testing.expect(std.mem.indexOf(u8, xml, "element_id is required") != null);
}

test "executeMoveElementToPageToString rejects bad prefixes via error XML" {
    const alloc = testing.allocator;
    const xml = try move_element_to_page.executeMoveElementToPageToString(
        alloc, undefined,
        "page_unused",
        .{ .element_id = "page_wrong_shape", .new_page_id = "page_target", .apply_to_children = true },
    );
    defer alloc.free(xml);

    try testing.expect(std.mem.indexOf(u8, xml, "<error>") != null);
    try testing.expect(std.mem.indexOf(u8, xml, "PAGE id") != null);
}