//! Unit tests for `design_model.zig` (page + element CRUD data
//! layer).
//!
//! Setup mirrors `kanban_model_test.zig`: in-memory sqlite with a
//! minimal `workspace_items` + `design_pages` + `design_page_elements`
//! schema, ready for the design SQL to run against.
//!
//! The design_page_elements table declared below already includes
//! the 11 v6 columns (Migration 057) — the tests don't exercise
//! migration logic here (that lives in migration_057_test.zig).
//! We CREATE the v6-ready schema directly so each test runs against
//! a known schema without running the full migration cascade.
//!
//! Plan: docs/superpowers/plans/2026-07-08-design-mode-redesign.md (Chunk 1)

const std = @import("std");
const testing = std.testing;
const nalarcore = @import("nalarcore");
const sqlite = nalarcore.sqlite;

const design_model = @import("design_model.zig");

// ─── Test helpers ─────────────────────────────────────────────────────────

/// Open a fresh in-memory sqlite DB with the minimum tables
/// `design_model` functions need: `workspace_items` + `design_pages`
/// + `design_page_elements`. The v6 schema is used here (no migration
/// cascade).
///
/// Returns the DB handle, the threaded Io, the inserted workspace
/// item id + path. The test must `defer ctx.threaded.deinit()` and
/// `defer ctx.db.deinit()`.
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

    // workspace_items. `path` is required by setDesignPage (returns
    // ItemPathMissing if NULL/empty).
    try db.exec(alloc,
        \\CREATE TABLE workspace_items (
        \\    id TEXT PRIMARY KEY, workspace_id TEXT NOT NULL,
        \\    item_type TEXT NOT NULL, name TEXT, path TEXT,
        \\    position INTEGER NOT NULL DEFAULT 0,
        \\    created_at DATETIME, updated_at DATETIME)
    , &.{});

    // design_pages (v6 schema).
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

    // design_page_elements (v6 schema — includes the 11 Migration 057
    // columns, but the tests in this file don't exercise them).
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

    // Create a temp directory for the design item's on-disk
    // storage. The tests in this file don't write to disk yet
    // (addElement writes are exercised by Task 1.4), but setDesignPage
    // requires a non-empty `path` on the workspace_item row, so
    // we point at a real tempdir path.
    var tmp = testing.tmpDir(.{});
    var tmpdir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmpdir_len = try tmp.dir.realPath(testing.io, &tmpdir_buf);
    const tmpdir_path = try testing.allocator.dupe(u8, tmpdir_buf[0..tmpdir_len]);
    // `tmp` is intentionally not cleaned up at this scope — the
    // directory persists until the OS reclaims the test process's
    // tmp dir. This is acceptable for test-suite use but should be
    // tidied up if reused in production code paths.

    // Insert the workspace item row (item_type='design' with a real path).
    const item_id_const = "item_design_1";
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

// ─── Test: listPages on empty item returns empty slice ──────────────────

test "listPages returns empty slice for an item with no pages" {
    const alloc = testing.allocator;
    var ctx = try setupDbAndItem();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();
    defer alloc.free(ctx.item_id);
    defer alloc.free(ctx.item_path);

    const pages = try design_model.listPages(alloc, &ctx.db, ctx.item_id);
    defer design_model.freePages(alloc, pages);
    try testing.expectEqual(@as(usize, 0), pages.len);
}

// ─── Test: setDesignPage creates a page on first call ───────────────────

test "setDesignPage creates a new page on first call" {
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

    // Generated id starts with "page_".
    try testing.expect(page_id.len > 4);
    try testing.expect(std.mem.startsWith(u8, page_id, "page_"));
}

// ─── Test: setDesignPage is idempotent (same name updates width/height) ─

test "setDesignPage is idempotent (same name updates width/height)" {
    const alloc = testing.allocator;
    var ctx = try setupDbAndItem();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();
    defer alloc.free(ctx.item_id);
    defer alloc.free(ctx.item_path);

    const id1 = try design_model.setDesignPage(alloc, &ctx.db, .{
        .item_id = ctx.item_id,
        .page_name = "Login",
        .width = 1440,
        .height = 1024,
    });
    defer alloc.free(id1);

    const id2 = try design_model.setDesignPage(alloc, &ctx.db, .{
        .item_id = ctx.item_id,
        .page_name = "Login",
        .width = 800,
        .height = 600,
    });
    defer alloc.free(id2);

    // Same row → same id.
    try testing.expectEqualStrings(id1, id2);

    // The row should reflect the latest width/height.
    const pages = try design_model.listPages(alloc, &ctx.db, ctx.item_id);
    defer design_model.freePages(alloc, pages);
    try testing.expectEqual(@as(usize, 1), pages.len);
    try testing.expectEqual(@as(i64, 800), pages[0].width);
    try testing.expectEqual(@as(i64, 600), pages[0].height);
}

// ─── Test: setDesignPage returns ItemPathMissing when path is empty ────

test "setDesignPage returns ItemPathMissing when workspace_item.path is empty" {
    const alloc = testing.allocator;
    var ctx = try setupDbAndItem();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();
    defer alloc.free(ctx.item_id);
    defer alloc.free(ctx.item_path);

    // Insert a separate item with path=NULL.
    const no_path_item = try alloc.dupe(u8, "item_no_path");
    defer alloc.free(no_path_item);
    try ctx.db.exec(alloc,
        "INSERT INTO workspace_items (id, workspace_id, item_type, path) " ++
        "VALUES (?, 'ws_test', 'design', NULL)",
        &.{no_path_item});

    const result = design_model.setDesignPage(alloc, &ctx.db, .{
        .item_id = no_path_item,
        .page_name = "Login",
        .width = 1440,
        .height = 1024,
    });
    try testing.expectError(error.ItemPathMissing, result);
}

// ─── Test: setDesignPage returns BadPageName for empty page_name ───────

test "setDesignPage rejects empty page_name" {
    const alloc = testing.allocator;
    var ctx = try setupDbAndItem();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();
    defer alloc.free(ctx.item_id);
    defer alloc.free(ctx.item_path);

    const result = design_model.setDesignPage(alloc, &ctx.db, .{
        .item_id = ctx.item_id,
        .page_name = "",
        .width = 1440,
        .height = 1024,
    });
    try testing.expectError(error.BadPageName, result);
}
