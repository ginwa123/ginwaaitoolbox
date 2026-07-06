//! Static regression checks for Migration 055
//! (add design_pages + design_page_elements tables).
//!
//! Why this file exists
//! ────────────────────
//! Migration 055 (now renamed to Migration055AddDesignPagesAndElements)
//! introduces two tables that back the new `item_type='design'`
//! workspace item:
//!
//!   1. `design_pages` — pure metadata (no html, no file_path). Each
//!      row represents a tab in the design canvas (e.g. "Login",
//!      "Dashboard"). The page has a canvas size (`width`/`height`)
//!      and an offset (`x`/`y`).
//!
//!   2. `design_page_elements` — positioned HTML snippets that
//!      compose a page. Each element stores its HTML body on disk
//!      at `<workspace_item.path>/.nalar/design/<page_name>/<name>.html`;
//!      the DB row holds only the metadata (position, size, z_index,
//!      file_path).
//!
//! The migration must:
//!   1. Create `design_pages` with the 10 expected columns in the
//!      expected order (`id`, `workspace_item_id`, `name`, `width`,
//!      `height`, `x`, `y`, `position`, `created_at`, `updated_at`).
//!   2. Add a UNIQUE index on `(workspace_item_id, name)` so the
//!      `addPage` use case is idempotent via INSERT ... ON CONFLICT.
//!   3. Add an index on `(workspace_item_id, position)` so the list
//!      query stays fast as items accumulate pages.
//!   4. Create `design_page_elements` with the 12 expected columns.
//!   5. Add an index on `(page_id, z_index, position)` for the
//!      elements list query.
//!
//! Plan: docs/superpowers/plans/2026-07-05-design-mode.md (Chunk 1)

const std = @import("std");
const testing = std.testing;
const sqlite = @import("nalarcore").sqlite;

const migration_module = @import("migration.zig");
const Migration055AddDesignPagesAndElements = migration_module.Migration055AddDesignPagesAndElements;

test "Migration055 is registered in allMigrations" {
    var found = false;
    for (migration_module.allMigrations) |m| {
        if (m.version == Migration055AddDesignPagesAndElements.version and
            std.mem.eql(u8, m.name, Migration055AddDesignPagesAndElements.name))
        {
            found = true;
            break;
        }
    }
    try testing.expect(found);
}

test "Migration055 creates design_pages with the 10 expected columns" {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var db: sqlite.SqliteBackend = .{};
    defer db.deinit();
    try db.init(io, ":memory:");

    // Migration055's FOREIGN KEY references workspace_items(id). The
    // production migrator walks 001..054 before 055 — so by the time 055
    // runs, workspace_items exists. For unit-test scope we copy the
    // CREATE TABLE manually as a shortcut (full migration runner would
    // touch many other tables we don't need here).
    try db.exec(alloc,
        "CREATE TABLE workspace_items (id TEXT PRIMARY KEY, workspace_id TEXT NOT NULL, item_type TEXT NOT NULL DEFAULT 'folder')",
        &.{});
    try Migration055AddDesignPagesAndElements.up(&db, alloc);

    const expected: [10][]const u8 = .{
        "id", "workspace_item_id", "name", "width", "height", "x", "y",
        "position", "created_at", "updated_at",
    };
    var q = try db.query(alloc,
        "SELECT name FROM pragma_table_info('design_pages') ORDER BY cid",
        &.{});
    defer q.deinit();
    var idx: usize = 0;
    while (try q.next()) |row| {
        defer row.deinit(alloc);
        try testing.expect(idx < expected.len);
        try testing.expectEqualStrings(expected[idx], row.values[0]);
        idx += 1;
    }
    try testing.expectEqual(@as(usize, expected.len), idx);
}

test "Migration055 creates design_page_elements with the 12 expected columns" {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var db: sqlite.SqliteBackend = .{};
    defer db.deinit();
    try db.init(io, ":memory:");

    try db.exec(alloc,
        "CREATE TABLE workspace_items (id TEXT PRIMARY KEY, workspace_id TEXT NOT NULL, item_type TEXT NOT NULL DEFAULT 'folder')",
        &.{});
    try Migration055AddDesignPagesAndElements.up(&db, alloc);

    const expected: [12][]const u8 = .{
        "id", "page_id", "name", "file_path", "x", "y", "width",
        "height", "z_index", "position", "created_at", "updated_at",
    };
    var q = try db.query(alloc,
        "SELECT name FROM pragma_table_info('design_page_elements') ORDER BY cid",
        &.{});
    defer q.deinit();
    var idx: usize = 0;
    while (try q.next()) |row| {
        defer row.deinit(alloc);
        try testing.expect(idx < expected.len);
        try testing.expectEqualStrings(expected[idx], row.values[0]);
        idx += 1;
    }
    try testing.expectEqual(@as(usize, expected.len), idx);
}

test "Migration055 drops the legacy html and file_path columns on design_pages" {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var db: sqlite.SqliteBackend = .{};
    defer db.deinit();
    try db.init(io, ":memory:");

    try db.exec(alloc,
        "CREATE TABLE workspace_items (id TEXT PRIMARY KEY, workspace_id TEXT NOT NULL, item_type TEXT NOT NULL DEFAULT 'folder')",
        &.{});
    // Simulate the v1 legacy schema (with html + file_path columns).
    try db.exec(alloc,
        \\CREATE TABLE design_pages (
        \\    id TEXT PRIMARY KEY,
        \\    workspace_item_id TEXT NOT NULL,
        \\    name TEXT NOT NULL DEFAULT '',
        \\    html TEXT NOT NULL DEFAULT '',
        \\    file_path TEXT NOT NULL DEFAULT '',
        \\    position INTEGER NOT NULL DEFAULT 0,
        \\    created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
        \\    updated_at DATETIME DEFAULT CURRENT_TIMESTAMP,
        \\    FOREIGN KEY (workspace_item_id) REFERENCES workspace_items(id) ON DELETE CASCADE
        \\)
    , &.{});
    try Migration055AddDesignPagesAndElements.up(&db, alloc);

    // Both legacy columns must be gone.
    var q = try db.query(alloc,
        "SELECT name FROM pragma_table_info('design_pages') WHERE name IN ('html', 'file_path')",
        &.{});
    defer q.deinit();
    try testing.expect((try q.next()) == null);
}