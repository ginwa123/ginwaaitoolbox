//! Static regression checks for Migration 055 (add design_pages table).
//!
//! Why this file exists
//! ────────────────────
//! Migration 055 introduces the `design_pages` table that backs the new
//! `item_type='design'` workspace item — a chat-driven HTML canvas where
//! each item hosts N named HTML pages (e.g. "Login", "Dashboard"). The
//! migration must:
//!   1. Create `design_pages` with the 7 expected columns in the expected order
//!      (`id`, `workspace_item_id`, `name`, `html`, `position`,
//!      `created_at`, `updated_at`).
//!   2. Add a UNIQUE index on `(workspace_item_id, name)` so the LLM tool
//!      `set_design_page` is idempotent via `INSERT ... ON CONFLICT`.
//!   3. Add an index on `(workspace_item_id, position)` so the list query
//!      stays fast as items accumulate pages.
//!
//! Plan: docs/superpowers/plans/2026-07-05-design-mode.md (Chunk 1)

const std = @import("std");
const testing = std.testing;
const sqlite = @import("nalarcore").sqlite;

const migration_module = @import("migration.zig");
const Migration055AddDesignPages = migration_module.Migration055AddDesignPages;

test "Migration055 is registered in allMigrations" {
    var found = false;
    for (migration_module.allMigrations) |m| {
        if (m.version == Migration055AddDesignPages.version and
            std.mem.eql(u8, m.name, Migration055AddDesignPages.name))
        {
            found = true;
            break;
        }
    }
    try testing.expect(found);
}

test "Migration055 creates design_pages with the 7 expected columns" {
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
    try Migration055AddDesignPages.up(&db, alloc);

    const expected: [7][]const u8 = .{
        "id", "workspace_item_id", "name", "html", "position",
        "created_at", "updated_at",
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