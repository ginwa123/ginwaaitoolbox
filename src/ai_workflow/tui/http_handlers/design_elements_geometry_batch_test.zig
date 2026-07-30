//! Behavioural unit tests for the `POST .../elements/geometry-batch`
//! HTTP handler (2026-07-30-design-drag-debounce-batch Chunk 1).
//!
//! Mirrors `design_elements_group_test.zig`'s convention:
//!   - Tests the public `useCase` function directly with crafted
//!     inputs — no HTTP framework mocking.
//!   - All tests are behavioural (real DB calls, real return-value
//!     assertions). NO static-contract / source-grep tests.
//!   - The handler itself (parseFromSliceLeaky, status-code mapping,
//!     route registration in `main.zig`) is covered by the parallel
//!     patterns in `design_elements_geometry_update_test.zig`
//!     (parseFromSliceLeaky) and `mod.zig` / `main.zig` review.
//!
//! Plan: docs/superpowers/plans/2026-07-30-design-drag-debounce-batch.md
//!   (Chunk 1, Task 1.3)

const std = @import("std");
const testing = std.testing;
const design_elements_batch = @import("design_elements_geometry_batch.zig");
const design_model = @import("../design_model.zig");
const nalarcore = @import("nalarcore");
const sqlite = nalarcore.sqlite;

// ─── Test fixtures (mirrors `design_model_set_element_parent_test.zig`) ─

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

    const item_id_const = "item_geometry_batch_handler";
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

// ─── useCase validation: EmptyUpdates (page_id/exists DB lookup) ─────────

test "useCase rejects empty updates with EmptyUpdates (no DB call)" {
    // Empty list is rejected BEFORE the DB lookup, so we pass
    // undefined for the db pointer. If validation regresses and
    // falls through, the undefined deref crashes loudly in debug.
    const result = design_elements_batch.useCase(testing.allocator, undefined, .{
        .page_id = "page_test",
        .updates = &.{},
    });
    try testing.expectError(error.EmptyUpdates, result);
}

// ─── useCase delegation: success path (delegates to design_model) ────────

test "useCase returns updated rows in input order on success" {
    const alloc = testing.allocator;
    var ctx = try setupDbAndItem();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();
    defer alloc.free(ctx.item_id);
    defer alloc.free(ctx.item_path);

    const page_id = try design_model.setDesignPage(alloc, &ctx.db, .{
        .item_id = ctx.item_id,
        .page_name = "Handler Test",
        .width = 1440,
        .height = 1024,
    });
    defer alloc.free(page_id);

    const a = try insertElementRaw(alloc, &ctx.db, page_id, "a", 0, 0, 100, 100);
    defer alloc.free(a);
    const b = try insertElementRaw(alloc, &ctx.db, page_id, "b", 0, 0, 100, 100);
    defer alloc.free(b);

    const output = try design_elements_batch.useCase(alloc, &ctx.db, .{
        .page_id = page_id,
        .updates = &.{
            .{ .element_id = a, .x = 111 },
            .{ .element_id = b, .x = 222 },
        },
    });
    defer {
        design_model.freeElements(alloc, output.updated);
    }

    try testing.expectEqual(@as(usize, 2), output.updated.len);
    try testing.expectEqualStrings(a, output.updated[0].id);
    try testing.expectEqualStrings(b, output.updated[1].id);
    try testing.expectEqual(@as(i64, 111), output.updated[0].x);
    try testing.expectEqual(@as(i64, 222), output.updated[1].x);
}

// ─── useCase error translation: PageNotFound → 404 at handler ─────────────

test "useCase returns PageNotFound when page_id does not exist" {
    const alloc = testing.allocator;
    var ctx = try setupDbAndItem();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();
    defer alloc.free(ctx.item_id);
    defer alloc.free(ctx.item_path);

    // No page seeded. Existing elements don't matter — PageNotFound
    // fires before the element pre-flight.
    const result = design_elements_batch.useCase(alloc, &ctx.db, .{
        .page_id = "page_does_not_exist",
        .updates = &.{.{ .element_id = "elem_anything", .x = 1 }},
    });
    try testing.expectError(error.PageNotFound, result);
}

// ─── useCase error translation: ElementNotFound → 404 at handler ──────────

test "useCase returns ElementNotFound when any element_id is missing (no partial writes)" {
    const alloc = testing.allocator;
    var ctx = try setupDbAndItem();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();
    defer alloc.free(ctx.item_id);
    defer alloc.free(ctx.item_path);

    const page_id = try design_model.setDesignPage(alloc, &ctx.db, .{
        .item_id = ctx.item_id,
        .page_name = "Atomicity Test",
        .width = 1440,
        .height = 1024,
    });
    defer alloc.free(page_id);

    const a = try insertElementRaw(alloc, &ctx.db, page_id, "a", 0, 0, 100, 100);
    defer alloc.free(a);

    // Snapshot pre-call state.
    var pre_a_x: i64 = 0;
    {
        const all = try design_model.listElements(alloc, &ctx.db, page_id);
        defer design_model.freeElements(alloc, all);
        for (all) |el| {
            if (std.mem.eql(u8, el.id, a)) pre_a_x = el.x;
        }
    }

    // a + missing → ElementNotFound. NO writes happen.
    const result = design_elements_batch.useCase(alloc, &ctx.db, .{
        .page_id = page_id,
        .updates = &.{
            .{ .element_id = a, .x = 999 },
            .{ .element_id = "elem_missing", .x = 1 },
        },
    });
    try testing.expectError(error.ElementNotFound, result);

    // Verify `a` is unchanged.
    const post = try design_model.listElements(alloc, &ctx.db, page_id);
    defer design_model.freeElements(alloc, post);
    try testing.expectEqual(@as(usize, 1), post.len);
    try testing.expectEqual(pre_a_x, post[0].x);
}

// ─── useCase accepts a single-element batch (N=1) ────────────────────────

test "useCase accepts a single-element batch (N=1)" {
    const alloc = testing.allocator;
    var ctx = try setupDbAndItem();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();
    defer alloc.free(ctx.item_id);
    defer alloc.free(ctx.item_path);

    const page_id = try design_model.setDesignPage(alloc, &ctx.db, .{
        .item_id = ctx.item_id,
        .page_name = "N=1 Test",
        .width = 1440,
        .height = 1024,
    });
    defer alloc.free(page_id);

    const a = try insertElementRaw(alloc, &ctx.db, page_id, "a", 0, 0, 100, 100);
    defer alloc.free(a);

    const output = try design_elements_batch.useCase(alloc, &ctx.db, .{
        .page_id = page_id,
        .updates = &.{.{ .element_id = a, .x = 777 }},
    });
    defer design_model.freeElements(alloc, output.updated);

    try testing.expectEqual(@as(usize, 1), output.updated.len);
    try testing.expectEqualStrings(a, output.updated[0].id);
    try testing.expectEqual(@as(i64, 777), output.updated[0].x);
}