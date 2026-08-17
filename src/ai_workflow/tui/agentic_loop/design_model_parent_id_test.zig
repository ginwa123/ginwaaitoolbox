//! Static-contract + behavioural tests for `parent_id` round-trip
//! through the `DesignElement` struct + `getElement` / `listElements`
//! SELECT statements + `DesignElementResponse` wire mapper.
//!
//! These are the foundational changes for Grouped Layers (frame /
//! group nesting) — every other chunk depends on `parent_id` being
//! readable on every element. The tests:
//!   1. Verify the struct field exists + is freed.
//!   2. Verify the SELECT in `getElement` reads `parent_id`.
//!   3. Verify the SELECT in `listElements` reads `parent_id`.
//!   4. Verify the wire mapper (`http_response.makeDesignElementResponse`)
//!      copies `parent_id`.
//!
//! Plan: docs/superpowers/plans/2026-07-28-grouped-layers.md (Chunk 1)

const std = @import("std");
const testing = std.testing;
const nalarcore = @import("nalarcore");
const sqlite = nalarcore.sqlite;

const design_model = @import("design_model.zig");

// ─── Test helpers ─────────────────────────────────────────────────────────

const DESIGN_MODEL_PATH = "src/ai_workflow/tui/agentic_loop/design_model.zig";
const HTTP_RESPONSE_PATH = "src/ai_workflow/tui/http_handlers/http_response.zig";

fn readSource(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        path,
        allocator,
        .limited(256 * 1024),
    );
}

/// Open a fresh in-memory sqlite DB with the minimum tables needed
/// for the design SQL. Mirrors `design_model_test.zig::setupDbAndItem`
/// (kept inline here so this file is self-contained for the static
/// checks).
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

    const item_id_const = "item_design_parent_id";
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

// ─── Contract 1: struct has parent_id field ──────────────────────────────

test "DesignElement struct declares parent_id field" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, DESIGN_MODEL_PATH);
    defer allocator.free(source);

    // Field declaration with `[]u8` type, near the image_url field.
    if (std.mem.indexOf(u8, source, "parent_id: []u8") == null) {
        std.debug.print(
            "\n!! {s} DesignElement struct is missing parent_id field !!\n" ++
                "   Add `parent_id: []u8` (after image_url) to expose\n" ++
                "   the Migration 057 parent column through the read-back path.\n",
            .{DESIGN_MODEL_PATH},
        );
        return error.ParentIdFieldMissing;
    }
}

test "freeElement frees parent_id slice" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, DESIGN_MODEL_PATH);
    defer allocator.free(source);

    if (std.mem.indexOf(u8, source, "allocator.free(e.parent_id)") == null) {
        std.debug.print(
            "\n!! {s} freeElement does not free parent_id !!\n" ++
                "   Add `allocator.free(e.parent_id);` inside freeElement.\n",
            .{DESIGN_MODEL_PATH},
        );
        return error.ParentIdFreeMissing;
    }
}

test "freeElements loop frees parent_id slice" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, DESIGN_MODEL_PATH);
    defer allocator.free(source);

    // The freeElements loop iterates over a slice and calls freeElement
    // per element. The static contract is "freeElement calls
    // allocator.free(e.parent_id)" (the loop inherits this from the
    // helper). This test pins that the helper has the line.
    if (std.mem.indexOf(u8, source, "allocator.free(e.parent_id)") == null) {
        std.debug.print(
            "\n!! {s} freeElement does not free parent_id !!\n" ++
                "   The freeElements loop delegates to freeElement — fix freeElement.\n",
            .{DESIGN_MODEL_PATH},
        );
        return error.ParentIdLoopFreeMissing;
    }
}

// ─── Contract 2: getElement SELECT includes parent_id ───────────────────

test "getElement SELECT reads parent_id column" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, DESIGN_MODEL_PATH);
    defer allocator.free(source);

    // The getElement SELECT must include "parent_id" so the column
    // is read into row.values[N]. The exact position in the SELECT
    // is unimportant — what matters is that the column appears.
    // Locate the getElement function (anchored to its SELECT) and
    // assert parent_id appears in that vicinity.
    const get_elem_idx = std.mem.indexOf(u8, source, "pub fn getElement") orelse {
        std.debug.print("\n!! getElement function not found in {s} !!\n", .{DESIGN_MODEL_PATH});
        return error.GetElementMissing;
    };
    const after_get_elem = source[get_elem_idx..];
    const slice_end = @min(after_get_elem.len, 3000);
    const get_elem_window = after_get_elem[0..slice_end];
    if (std.mem.indexOf(u8, get_elem_window, "parent_id") == null) {
        std.debug.print(
            "\n!! getElement in {s} does not SELECT parent_id !!\n" ++
                "   Add parent_id to the SELECT column list and to the\n" ++
                "   returned DesignElement initializer (allocator.dupe the value).\n",
            .{DESIGN_MODEL_PATH},
        );
        return error.GetElementParentIdMissing;
    }
}

// ─── Contract 3: listElements SELECT includes parent_id ──────────────────

test "listElements SELECT reads parent_id column" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, DESIGN_MODEL_PATH);
    defer allocator.free(source);

    const list_elem_idx = std.mem.indexOf(u8, source, "pub fn listElements") orelse {
        std.debug.print("\n!! listElements function not found in {s} !!\n", .{DESIGN_MODEL_PATH});
        return error.ListElementsMissing;
    };
    const after_list_elem = source[list_elem_idx..];
    const slice_end = @min(after_list_elem.len, 3500);
    const list_elem_window = after_list_elem[0..slice_end];
    if (std.mem.indexOf(u8, list_elem_window, "parent_id") == null) {
        std.debug.print(
            "\n!! listElements in {s} does not SELECT parent_id !!\n" ++
                "   Add parent_id to the SELECT column list and to the\n" ++
                "   returned DesignElement initializer.\n",
            .{DESIGN_MODEL_PATH},
        );
        return error.ListElementsParentIdMissing;
    }
}

// ─── Contract 4: DesignElementResponse carries parent_id ────────────────

test "DesignElementResponse struct has parent_id field" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HTTP_RESPONSE_PATH);
    defer allocator.free(source);

    if (std.mem.indexOf(u8, source, "parent_id: []const u8") == null) {
        std.debug.print(
            "\n!! {s} DesignElementResponse is missing parent_id !!\n" ++
                "   Add `parent_id: []const u8` to DesignElementResponse\n" ++
                "   (after image_url) and copy elem.parent_id in\n" ++
                "   makeDesignElementResponse.\n",
            .{HTTP_RESPONSE_PATH},
        );
        return error.ResponseParentIdMissing;
    }
}

test "makeDesignElementResponse mapper copies parent_id from elem.parent_id" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HTTP_RESPONSE_PATH);
    defer allocator.free(source);

    // The mapper must reference elem.parent_id. Search inside the
    // makeDesignElementResponse function body.
    const mapper_idx = std.mem.indexOf(u8, source, "pub fn makeDesignElementResponse") orelse {
        std.debug.print("\n!! makeDesignElementResponse not found in {s} !!\n", .{HTTP_RESPONSE_PATH});
        return error.MapperMissing;
    };
    const after_mapper = source[mapper_idx..];
    const slice_end = @min(after_mapper.len, 2500);
    const mapper_window = after_mapper[0..slice_end];
    if (std.mem.indexOf(u8, mapper_window, "parent_id") == null) {
        std.debug.print(
            "\n!! makeDesignElementResponse in {s} does not copy parent_id !!\n" ++
                "   Add `.parent_id = elem.parent_id,` to the returned struct.\n",
            .{HTTP_RESPONSE_PATH},
        );
        return error.MapperParentIdCopyMissing;
    }
}

// ─── Behavioural: getElement returns parent_id (NULL → empty string) ────

test "getElement returns empty string for NULL parent_id" {
    const alloc = testing.allocator;
    var ctx = try setupDbAndItem();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();
    defer alloc.free(ctx.item_id);
    defer alloc.free(ctx.item_path);

    const page_id = try design_model.setDesignPage(alloc, &ctx.db, .{
        .item_id = ctx.item_id,
        .page_name = "Login",
        .width = 1440,
        .height = 1024,
    });
    defer alloc.free(page_id);

    const element_id = try design_model.addElement(alloc, &ctx.db, ctx.threaded.io(), .{
        .page_id = page_id,
        .name = "login-card",
        .elem_type = .rectangle,
        .html = "<div>Login</div>",
        .x = 100, .y = 200, .width = 400, .height = 300,
        .fill = "#ffffff", .rotation = 0.0, .corner_radius = 0, .opacity = 1.0,
    });
    defer alloc.free(element_id);

    const got = try design_model.getElement(alloc, &ctx.db, element_id);
    defer design_model.freeElement(alloc, got);

    // NULL parent_id → empty string (the SELECT COALESCE pattern is
    // not used here; the column reads "" via the empty-slice-binds-as-null
    // pattern. Both are acceptable per the project memory
    // `zig-sqlite-patterns.md` §"empty slice as NULL").
    try testing.expectEqual(@as(usize, 0), got.parent_id.len);
}

test "getElement returns parent_id value when set" {
    const alloc = testing.allocator;
    var ctx = try setupDbAndItem();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();
    defer alloc.free(ctx.item_id);
    defer alloc.free(ctx.item_path);

    const page_id = try design_model.setDesignPage(alloc, &ctx.db, .{
        .item_id = ctx.item_id,
        .page_name = "Login",
        .width = 1440,
        .height = 1024,
    });
    defer alloc.free(page_id);

    // Manually INSERT a parent + child with parent_id set, bypassing
    // addElement (which always sets parent_id = NULL via INSERT).
    try ctx.db.exec(alloc,
        \\INSERT INTO design_page_elements
        \\   (id, page_id, name, file_path, x, y, width, height, z_index, position,
        \\    type, rotation, fill, stroke, stroke_width, corner_radius, opacity,
        \\    text_content, text_style, image_url, parent_id,
        \\    created_at, updated_at)
        \\VALUES
        \\   ('elem_parent_1', ?, 'parent', '', 0, 0, 100, 100, 0, 0,
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
        \\   ('elem_child_1', ?, 'child', '', 10, 10, 20, 20, 0, 1,
        \\    'rectangle', 0.0, '', '', 0, 0, 1.0,
        \\    '', '', '', 'elem_parent_1', datetime('now'), datetime('now'))
    , &.{page_id});

    const child = try design_model.getElement(alloc, &ctx.db, "elem_child_1");
    defer design_model.freeElement(alloc, child);

    try testing.expectEqualStrings("elem_parent_1", child.parent_id);
}

test "listElements returns parent_id for every element" {
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

    // Same manual-INSERT pattern as the previous test. Each row is
    // INSERTed in its own statement so the `?` placeholder count
    // matches the args count (SQLite positions `?` per-statement).
    try ctx.db.exec(alloc,
        \\INSERT INTO design_page_elements
        \\   (id, page_id, name, file_path, x, y, width, height, z_index, position,
        \\    type, rotation, fill, stroke, stroke_width, corner_radius, opacity,
        \\    text_content, text_style, image_url, parent_id,
        \\    created_at, updated_at)
        \\VALUES
        \\   ('elem_top', ?, 'top', '', 0, 0, 100, 100, 0, 0,
        \\    'rectangle', 0.0, '', '', 0, 0, 1.0,
        \\    '', '', '', NULL, datetime('now'), datetime('now'))
    , &.{page_id});

    try ctx.db.exec(alloc,
        \\INSERT INTO design_page_elements
        \\   (id, page_id, name, file_path, x, y, width, height, z_index, position,
        \\    type, rotation, fill, stroke, stroke_width, corner_radius, opacity,
        \\    text_content, text_style, image_url, parent_id,
        \\    created_at, updated_at)
        \\VALUES
        \\   ('elem_parent', ?, 'parent', '', 0, 0, 200, 200, 0, 1,
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
        \\   ('elem_child', ?, 'child', '', 10, 10, 50, 50, 0, 2,
        \\    'rectangle', 0.0, '', '', 0, 0, 1.0,
        \\    '', '', '', 'elem_parent', datetime('now'), datetime('now'))
    , &.{page_id});

    const elements = try design_model.listElements(alloc, &ctx.db, page_id);
    defer design_model.freeElements(alloc, elements);

    try testing.expectEqual(@as(usize, 3), elements.len);

    // Order by (z_index ASC, position ASC). The top-level "top" is at
    // position 0 (z 0); "parent" at position 1 (z 0); "child" at
    // position 2 (z 0).
    try testing.expectEqualStrings("top", elements[0].name);
    try testing.expectEqualStrings("parent", elements[1].name);
    try testing.expectEqualStrings("child", elements[2].name);

    try testing.expectEqual(@as(usize, 0), elements[0].parent_id.len);
    try testing.expectEqual(@as(usize, 0), elements[1].parent_id.len);
    try testing.expectEqualStrings("elem_parent", elements[2].parent_id);
}