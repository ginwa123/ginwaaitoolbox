//! Unit tests for `design_model.zig` (design page CRUD data layer).
//!
//! Setup mirrors `kanban_model_test.zig`: in-memory sqlite with a minimal
//! `workspace_items` + `design_pages` schema, ready for the design_model
//! SQL to run against.
//!
//! Plan: docs/superpowers/plans/2026-07-05-design-mode.md (Chunk 1, Task 1.2)

const std = @import("std");
const testing = std.testing;
const nalarcore = @import("nalarcore");
const sqlite = nalarcore.sqlite;

const design_model = @import("design_model.zig");

/// Open a fresh in-memory sqlite DB with the bare minimum tables the
/// design_model functions need: `workspace_items` (FK target) and
/// `design_pages` (the table being queried). Mirrors the spec's
/// recommended setupDb helper.
fn setupDb() !struct { db: sqlite.SqliteBackend, threaded: std.Io.Threaded } {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    errdefer threaded.deinit();
    const io = threaded.io();
    var db: sqlite.SqliteBackend = .{};
    errdefer db.deinit();
    try db.init(io, ":memory:");
    try db.exec(alloc,
        "CREATE TABLE workspace_items (id TEXT PRIMARY KEY, workspace_id TEXT NOT NULL, item_type TEXT NOT NULL DEFAULT 'folder')",
        &.{});
    try db.exec(alloc,
        \\CREATE TABLE design_pages (
        \\    id TEXT PRIMARY KEY,
        \\    workspace_item_id TEXT NOT NULL,
        \\    name TEXT NOT NULL DEFAULT '',
        \\    html TEXT NOT NULL DEFAULT '',
        \\    position INTEGER NOT NULL DEFAULT 0,
        \\    created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
        \\    updated_at DATETIME DEFAULT CURRENT_TIMESTAMP,
        \\    FOREIGN KEY (workspace_item_id) REFERENCES workspace_items(id) ON DELETE CASCADE
        \\)
    , &.{});
    // The UNIQUE index on (workspace_item_id, name) is what makes
    // `addPage`'s `INSERT ... ON CONFLICT(workspace_item_id, name) DO UPDATE`
    // valid (added by Migration 055). The production migrator applies
    // this index as part of the same migration; the in-memory test DB
    // needs the same index for `addPage`'s upsert to compile.
    try db.exec(alloc,
        "CREATE UNIQUE INDEX idx_design_pages_item_name " ++
        "ON design_pages(workspace_item_id, name)",
        &.{});
    try db.exec(alloc,
        "INSERT INTO workspace_items (id, workspace_id) VALUES ('item_test', 'ws_test')",
        &.{});
    return .{ .db = db, .threaded = threaded };
}

// ─── addPage ─────────────────────────────────────────────────────────────

test "addPage creates a new page and returns its id" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    const id = try design_model.addPage(alloc, &ctx.db, "item_test", "Login", "<h1>Hi</h1>");
    defer alloc.free(id);
    try testing.expect(std.mem.startsWith(u8, id, "page_"));
}

test "addPage is idempotent on (item_id, name) — second call updates html" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    // First insert creates a new row.
    const id1 = try design_model.addPage(alloc, &ctx.db, "item_test", "Login", "<h1>v1</h1>");
    defer alloc.free(id1);

    // Second insert with the same (item_id, name) updates the EXISTING
    // row's html (ON CONFLICT DO UPDATE) and returns a FRESH id (the
    // implementation always allocates a new id — the row keeps its
    // original id). Verify the existing row was updated by reading
    // back the html via the first id.
    const id2 = try design_model.addPage(alloc, &ctx.db, "item_test", "Login", "<h1>v2</h1>");
    defer alloc.free(id2);

    // The returned ids may differ (newly allocated each call) — but the
    // row's id must be the FIRST one (the original create), and the
    // html must be the latest write.
    var q = try ctx.db.query(alloc,
        "SELECT html FROM design_pages WHERE id = ?", &.{id1});
    defer q.deinit();
    const row = (try q.next()) orelse return error.NoRow;
    defer row.deinit(alloc);
    try testing.expectEqualStrings("<h1>v2</h1>", row.values[0]);

    // Only one row exists for (item_id, name).
    var q2 = try ctx.db.query(alloc,
        "SELECT COUNT(*) FROM design_pages WHERE workspace_item_id = ? AND name = ?",
        &.{ "item_test", "Login" });
    defer q2.deinit();
    const r2 = (try q2.next()) orelse return error.NoRow;
    defer r2.deinit(alloc);
    try testing.expectEqual(@as(usize, 1), try std.fmt.parseInt(usize, r2.values[0], 10));
}

test "addPage on empty item gets position 0" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    const id = try design_model.addPage(alloc, &ctx.db, "item_test", "First", "");
    defer alloc.free(id);

    var q = try ctx.db.query(alloc, "SELECT position FROM design_pages WHERE id = ?", &.{id});
    defer q.deinit();
    const row = (try q.next()) orelse return error.NoRow;
    defer row.deinit(alloc);
    try testing.expectEqual(@as(i64, 0), try std.fmt.parseInt(i64, row.values[0], 10));
}

test "addPage assigns incrementing position" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    const a = try design_model.addPage(alloc, &ctx.db, "item_test", "A", "");
    defer alloc.free(a);
    const b = try design_model.addPage(alloc, &ctx.db, "item_test", "B", "");
    defer alloc.free(b);
    const c = try design_model.addPage(alloc, &ctx.db, "item_test", "C", "");
    defer alloc.free(c);

    var q = try ctx.db.query(alloc,
        "SELECT position FROM design_pages WHERE workspace_item_id = ? ORDER BY position ASC",
        &.{"item_test"});
    defer q.deinit();
    var positions: [3]i64 = .{ 0, 0, 0 };
    var i: usize = 0;
    while (try q.next()) |row| {
        defer row.deinit(alloc);
        positions[i] = try std.fmt.parseInt(i64, row.values[0], 10);
        i += 1;
    }
    try testing.expectEqual(@as(usize, 3), i);
    try testing.expect(positions[0] < positions[1]);
    try testing.expect(positions[1] < positions[2]);
}

// ─── listPages ───────────────────────────────────────────────────────────

test "listPages returns rows ordered by position, excludes html" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    const a = try design_model.addPage(alloc, &ctx.db, "item_test", "First", "<h1>1</h1>");
    defer alloc.free(a);
    const b = try design_model.addPage(alloc, &ctx.db, "item_test", "Second", "<h1>2</h1>");
    defer alloc.free(b);

    const summaries = try design_model.listPages(alloc, &ctx.db, "item_test");
    defer design_model.freePageSummaries(alloc, summaries);

    try testing.expectEqual(@as(usize, 2), summaries.len);
    try testing.expectEqualStrings("First", summaries[0].name);
    try testing.expectEqualStrings("Second", summaries[1].name);
    try testing.expect(summaries[0].position < summaries[1].position);
    // html is intentionally excluded from listPages — frontend lazy-loads
    // the body via getPage on tab activation.
    try testing.expect(summaries[0].html == null);
}

// ─── getPage ─────────────────────────────────────────────────────────────

test "getPage returns full row including html" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    const id = try design_model.addPage(alloc, &ctx.db, "item_test", "Foo", "<p>bar</p>");
    defer alloc.free(id);

    const page = try design_model.getPage(alloc, &ctx.db, id);
    defer design_model.freePageFull(alloc, page);
    try testing.expectEqualStrings("Foo", page.name);
    try testing.expectEqualStrings("<p>bar</p>", page.html);
}

test "getPage on missing id returns error.PageNotFound" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    const result = design_model.getPage(alloc, &ctx.db, "page_does_not_exist");
    try testing.expectError(error.PageNotFound, result);
}

// ─── deletePage ──────────────────────────────────────────────────────────

test "deletePage removes the row and returns true" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    const id = try design_model.addPage(alloc, &ctx.db, "item_test", "Foo", "");
    defer alloc.free(id);

    const deleted = try design_model.deletePage(alloc, &ctx.db, id);
    try testing.expect(deleted);

    const result = design_model.getPage(alloc, &ctx.db, id);
    try testing.expectError(error.PageNotFound, result);
}

test "deletePage on missing id returns false (idempotent)" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    const deleted = try design_model.deletePage(alloc, &ctx.db, "page_does_not_exist");
    try testing.expect(!deleted);
}

// ─── updatePageHtml ──────────────────────────────────────────────────────

test "updatePageHtml replaces html and returns true" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    const id = try design_model.addPage(alloc, &ctx.db, "item_test", "Foo", "<p>v1</p>");
    defer alloc.free(id);

    const ok = try design_model.updatePageHtml(alloc, &ctx.db, id, "<p>v2</p>");
    try testing.expect(ok);

    const page = try design_model.getPage(alloc, &ctx.db, id);
    defer design_model.freePageFull(alloc, page);
    try testing.expectEqualStrings("<p>v2</p>", page.html);
}