//! Behavioural unit tests for the `POST .../elements/group` HTTP
//! handler (2026-07-28-grouped-layers Chunk 3).
//!
//! Per PR #136 review feedback, ALL previous static-contract grep tests
//! in this file were deleted. The static-grep pattern (read the source
//! from disk, grep for a substring, assert the substring exists) is
//! brittle and tests implementation details rather than behaviour — a
//! test that grepped for `"child_ids.len < 2"` passed even when the
//! validation was removed because the variable name still appeared in
//! a comment somewhere in the file.
//!
//! Replacement strategy:
//!   - For each contract that's exercised via `useCase`, write a
//!     behavioural test that calls `useCase` with crafted inputs and
//!     asserts on the return value.
//!   - For contracts that live ONLY in the handler (parseFromSliceLeaky,
//!     defaults for name/type, status code mapping) or in module
//!     wiring (route registration in `main.zig`, `mod.zig` re-export),
//!     there's no behavioural path without HTTP framework mocking —
//!     so the test was deleted (not converted).
//!
//! Plan: docs/superpowers/plans/2026-07-28-grouped-layers.md (Chunk 3)

const std = @import("std");
const testing = std.testing;
const design_elements_group = @import("design_elements_group.zig");
const design_model = @import("../agentic_loop/design_model.zig");
const nalarcore = @import("nalarcore");
const sqlite = nalarcore.sqlite;

// ─── Test fixtures (mirrors `design_model_group_test.zig`) ─────────────────

/// Open a fresh in-memory sqlite DB with the minimum tables needed for
/// the design SQL, plus a workspace_item with a tmpdir-backed path so
/// `design_model.groupElements` can write the new group's HTML file.
const TestCtx = struct {
    db: sqlite.SqliteBackend,
    threaded: std.Io.Threaded,
    item_id: []const u8,
    item_path: []u8,
};

fn setupDbAndItem() !TestCtx {
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

    const item_id_const = "item_test";
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

/// Insert one design element with explicit (x, y, width, height).
/// Returns the generated id (heap-owned; caller frees).
fn insertChild(
    alloc: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    page_id: []const u8,
    name: []const u8,
    x: i64,
    y: i64,
    w: i64,
    h: i64,
) ![]u8 {
    // db.exec binds only TEXT — stringify the integer columns.
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
        \\    '', '', '', NULL, datetime('now'), datetime('now'))
    , &.{ name, page_id, name, x_str, y_str, w_str, h_str });
    return alloc.dupe(u8, name);
}

// ─── useCase validation: child_ids.length >= 2 ────────────────────────────

test "useCase rejects empty child_ids with TooFewChildren" {
    // The validation runs BEFORE any DB access, so we pass
    // `undefined` for the db pointer. If the validation regresses
    // and falls through to design_model.groupElements, the
    // undefined pointer deref crashes loudly in debug builds —
    // pointing directly at the regression site.
    const result = design_elements_group.useCase(testing.allocator, undefined, .{
        .page_id = "page_test",
        .workspace_id = "ws_test",
        .child_ids = &.{},
        .name = "My Group",
        .elem_type = .group,
    });
    try testing.expectError(error.TooFewChildren, result);
}

test "useCase rejects single-element child_ids with TooFewChildren" {
    const result = design_elements_group.useCase(testing.allocator, undefined, .{
        .page_id = "page_test",
        .workspace_id = "ws_test",
        .child_ids = &.{"elem_1"},
        .name = "My Group",
        .elem_type = .group,
    });
    try testing.expectError(error.TooFewChildren, result);
}

// ─── useCase delegation: success path (delegates to design_model) ──────────

test "useCase delegates to design_model.groupElements and returns parent + children" {
    const alloc = testing.allocator;
    var ctx = try setupDbAndItem();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();
    defer alloc.free(ctx.item_id);
    defer alloc.free(ctx.item_path);

    const page_id = try design_model.setDesignPage(alloc, &ctx.db, .{
        .item_id = ctx.item_id,
        .page_name = "Home",
        .width = 1440,
        .height = 1024,
    });
    defer alloc.free(page_id);

    const child_a = try insertChild(alloc, &ctx.db, page_id, "elem_a", 0, 0, 100, 50);
    defer alloc.free(child_a);
    const child_b = try insertChild(alloc, &ctx.db, page_id, "elem_b", 50, 100, 100, 50);
    defer alloc.free(child_b);

    const output = try design_elements_group.useCase(alloc, &ctx.db, .{
        .page_id = page_id,
        .workspace_id = "ws_test",
        .child_ids = &.{ child_a, child_b },
        .name = "My Group",
        .elem_type = .group,
    });
    defer {
        design_model.freeElement(alloc, output.parent);
        for (output.children) |c| design_model.freeElement(alloc, c);
        alloc.free(output.children);
    }

    // The parent is the new top-level group at the union bbox.
    try testing.expectEqualStrings("My Group", output.parent.name);
    try testing.expectEqualStrings("group", output.parent.elem_type);
    try testing.expectEqualStrings("", output.parent.parent_id); // top-level

    // Children are returned with parent_id set to the new parent's id.
    try testing.expectEqual(@as(usize, 2), output.children.len);
    for (output.children) |c| {
        try testing.expectEqualStrings(output.parent.id, c.parent_id);
    }
}

// ─── useCase error translation: PageNotFound → 404 at handler ─────────────

test "useCase returns PageNotFound when page_id does not exist" {
    const alloc = testing.allocator;
    var ctx = try setupDbAndItem();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();
    defer alloc.free(ctx.item_id);
    defer alloc.free(ctx.item_path);

    // No page seeded — the page_id is unknown.
    const result = design_elements_group.useCase(alloc, &ctx.db, .{
        .page_id = "page_does_not_exist",
        .workspace_id = "ws_test",
        .child_ids = &.{ "elem_a", "elem_b" },
        .name = "My Group",
        .elem_type = .group,
    });
    try testing.expectError(error.PageNotFound, result);
}

// ─── useCase error translation: BadChildId → 400 at handler ───────────────

test "useCase returns BadChildId when a child_id does not exist" {
    const alloc = testing.allocator;
    var ctx = try setupDbAndItem();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();
    defer alloc.free(ctx.item_id);
    defer alloc.free(ctx.item_path);

    const page_id = try design_model.setDesignPage(alloc, &ctx.db, .{
        .item_id = ctx.item_id,
        .page_name = "Home",
        .width = 1440,
        .height = 1024,
    });
    defer alloc.free(page_id);

    const child_a = try insertChild(alloc, &ctx.db, page_id, "elem_a", 0, 0, 100, 50);
    defer alloc.free(child_a);

    // elem_b does not exist; the model's SELECT returns 1 row but
    // input.child_ids.len == 2, triggering BadChildId.
    const result = design_elements_group.useCase(alloc, &ctx.db, .{
        .page_id = page_id,
        .workspace_id = "ws_test",
        .child_ids = &.{ child_a, "elem_b_does_not_exist" },
        .name = "My Group",
        .elem_type = .group,
    });
    try testing.expectError(error.BadChildId, result);
}

// ─── useCase error translation: ChildAlreadyParented → 409 at handler ──────

test "useCase returns ChildAlreadyParented when children already have a parent" {
    const alloc = testing.allocator;
    var ctx = try setupDbAndItem();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();
    defer alloc.free(ctx.item_id);
    defer alloc.free(ctx.item_path);

    const page_id = try design_model.setDesignPage(alloc, &ctx.db, .{
        .item_id = ctx.item_id,
        .page_name = "Home",
        .width = 1440,
        .height = 1024,
    });
    defer alloc.free(page_id);

    const child_a = try insertChild(alloc, &ctx.db, page_id, "elem_a", 0, 0, 100, 50);
    defer alloc.free(child_a);
    const child_b = try insertChild(alloc, &ctx.db, page_id, "elem_b", 50, 100, 100, 50);
    defer alloc.free(child_b);

    // First call: succeeds and reparents child_a + child_b.
    {
        const output = try design_elements_group.useCase(alloc, &ctx.db, .{
            .page_id = page_id,
            .workspace_id = "ws_test",
            .child_ids = &.{ child_a, child_b },
            .name = "First Group",
            .elem_type = .group,
        });
        design_model.freeElement(alloc, output.parent);
        for (output.children) |c| design_model.freeElement(alloc, c);
        alloc.free(output.children);
    }

    // Second call with the same children: model rejects because
    // both children already have a parent_id != NULL.
    const result = design_elements_group.useCase(alloc, &ctx.db, .{
        .page_id = page_id,
        .workspace_id = "ws_test",
        .child_ids = &.{ child_a, child_b },
        .name = "Second Group",
        .elem_type = .group,
    });
    try testing.expectError(error.ChildAlreadyParented, result);
}
