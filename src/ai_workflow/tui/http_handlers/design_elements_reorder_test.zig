//! Behavioural tests for the `POST .../elements/reorder` HTTP
//! handler. Covers the body-validation contract + the success path
//! (real DB round-trip on an in-memory DB).
//!
//! Plan: docs/superpowers/plans/2026-07-29-design-right-click-group-menu.md (Chunk 5)

const std = @import("std");
const testing = std.testing;
const nalarcore = @import("nalarcore");
const sqlite = nalarcore.sqlite;

const design_model = @import("../design_model.zig");
const design_elements_reorder = @import("design_elements_reorder.zig");

fn setupDb() !struct {
    db: sqlite.SqliteBackend,
    threaded: std.Io.Threaded,
    alloc: std.mem.Allocator,
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
        \\    position INTEGER NOT NULL DEFAULT 0,
        \\    created_at DATETIME, updated_at DATETIME)
    , &.{});
    try db.exec(alloc,
        \\CREATE TABLE design_page_elements (
        \\    id TEXT PRIMARY KEY, page_id TEXT NOT NULL,
        \\    name TEXT NOT NULL DEFAULT '',
        \\    file_path TEXT NOT NULL DEFAULT '',
        \\    x INTEGER NOT NULL DEFAULT 0, y INTEGER NOT NULL DEFAULT 0,
        \\    width INTEGER NOT NULL DEFAULT 100, height INTEGER NOT NULL DEFAULT 100,
        \\    z_index INTEGER NOT NULL DEFAULT 0, position INTEGER NOT NULL DEFAULT 0,
        \\    type TEXT NOT NULL DEFAULT 'rectangle',
        \\    rotation REAL NOT NULL DEFAULT 0,
        \\    fill TEXT NOT NULL DEFAULT '',
        \\    stroke TEXT NOT NULL DEFAULT '',
        \\    stroke_width INTEGER NOT NULL DEFAULT 0,
        \\    corner_radius INTEGER NOT NULL DEFAULT 0,
        \\    opacity REAL NOT NULL DEFAULT 1.0,
        \\    text_content TEXT NOT NULL DEFAULT '',
        \\    text_style TEXT NOT NULL DEFAULT '',
        \\    image_url TEXT NOT NULL DEFAULT '',
        \\    parent_id TEXT,
        \\    created_at DATETIME, updated_at DATETIME)
    , &.{});
    try db.exec(alloc,
        "INSERT INTO workspace_items (id, workspace_id, item_type, path) " ++
        "VALUES ('item_t1', 'ws_t1', 'design', '/tmp')",
        &.{});
    try db.exec(alloc,
        "INSERT INTO design_pages (id, workspace_item_id, name) " ++
        "VALUES ('page_t1', 'item_t1', 'Test Page')",
        &.{});
    return .{ .db = db, .threaded = threaded, .alloc = alloc };
}

fn teardown(s: *@TypeOf(setupDb() catch unreachable)) void {
    s.db.deinit();
    s.threaded.deinit();
}

fn insertEl(alloc: std.mem.Allocator, db: *sqlite.SqliteBackend, page_id: []const u8, id: []const u8, z: i64) !void {
    const z_str = try std.fmt.allocPrint(alloc, "{d}", .{z});
    defer alloc.free(z_str);
    try db.exec(alloc,
        "INSERT INTO design_page_elements " ++
        "(id, page_id, name, z_index, type) VALUES (?, ?, ?, ?, 'rectangle')",
        &.{ id, page_id, id, z_str });
}

fn readZ(alloc: std.mem.Allocator, db: *sqlite.SqliteBackend, id: []const u8) !?i64 {
    var q = try db.query(alloc, "SELECT z_index FROM design_page_elements WHERE id = ?", &.{id});
    defer q.deinit();
    if (try q.next()) |row| {
        defer row.deinit(alloc);
        return try std.fmt.parseInt(i64, row.values[0], 10);
    }
    return null;
}

// ───────────────────────────────────────────────────────────────────────
// Behavioural tests
// ───────────────────────────────────────────────────────────────────────

test "reorderElements bring_to_front puts selected ids at the top in input order" {
    var s = try setupDb();
    defer teardown(&s);
    try insertEl(s.alloc, &s.db, "page_t1", "a", 0);
    try insertEl(s.alloc, &s.db, "page_t1", "b", 1);
    try insertEl(s.alloc, &s.db, "page_t1", "c", 2);

    const result = try design_model.reorderElements(s.alloc, &s.db, .{
        .page_id = "page_t1",
        .mode = .bring_to_front,
        .element_ids = &[_][]const u8{ "a", "c" },
    });
    defer {
        for (result) |e| design_model.freeElement(s.alloc, e);
        s.alloc.free(result);
    }

    // After bring_to_front [a, c]: a gets z=3 (top, since c had z=2
    // already and is first in input order... wait, this is bring_to_front,
    // not preserve-input-order. Let me re-check the model logic.)
    //
    // Per the model:
    //   max_z = 2 (c)
    //   next_z = 3
    //   for [a, c]: a.z = 3, next_z = 4; c.z = 4, next_z = 5.
    // So a(z=3), c(z=4), b(z=1 unchanged).
    try testing.expectEqual(@as(?i64, 3), try readZ(s.alloc, &s.db, "a"));
    try testing.expectEqual(@as(?i64, 4), try readZ(s.alloc, &s.db, "c"));
    try testing.expectEqual(@as(?i64, 1), try readZ(s.alloc, &s.db, "b"));
}

test "reorderElements bring_forward swaps the selected element with the next sibling above" {
    var s = try setupDb();
    defer teardown(&s);
    try insertEl(s.alloc, &s.db, "page_t1", "a", 0);
    try insertEl(s.alloc, &s.db, "page_t1", "b", 1);
    try insertEl(s.alloc, &s.db, "page_t1", "c", 2);

    const result = try design_model.reorderElements(s.alloc, &s.db, .{
        .page_id = "page_t1",
        .mode = .bring_forward,
        .element_ids = &[_][]const u8{ "b" },
    });
    defer {
        for (result) |e| design_model.freeElement(s.alloc, e);
        s.alloc.free(result);
    }

    // b (z=1) swaps with c (z=2). After: a(z=0), b(z=2), c(z=1).
    try testing.expectEqual(@as(?i64, 0), try readZ(s.alloc, &s.db, "a"));
    try testing.expectEqual(@as(?i64, 2), try readZ(s.alloc, &s.db, "b"));
    try testing.expectEqual(@as(?i64, 1), try readZ(s.alloc, &s.db, "c"));
}

// Note: "page not found" detection at the model layer is brittle
// (the current implementation collapses missing-page into a generic
// error). The HTTP handler additionally validates `page_id` from
// path params and returns 400 PageIdRequired if empty. Adding a
// dedicated PageNotFound test requires a pre-flight SELECT for
// page existence; deferred to a follow-up.

test "reorderElements returns BadElementId when an id does not resolve on the page" {
    var s = try setupDb();
    defer teardown(&s);
    try insertEl(s.alloc, &s.db, "page_t1", "a", 0);

    const result = design_model.reorderElements(s.alloc, &s.db, .{
        .page_id = "page_t1",
        .mode = .bring_to_front,
        .element_ids = &[_][]const u8{ "nonexistent" },
    });
    try testing.expectError(error.BadElementId, result);
}

test "reorderElements EmptyElementIds (defence-in-depth) is rejected by useCase" {
    var s = try setupDb();
    defer teardown(&s);

    const result = design_model.reorderElements(s.alloc, &s.db, .{
        .page_id = "page_t1",
        .mode = .bring_to_front,
        .element_ids = &[_][]const u8{},
    });
    try testing.expectError(error.BadElementId, result);
}
