//! Unit tests for `design_model.zig` — design page + element CRUD
//! data layer (file-backed elements).
//!
//! Setup mirrors `kanban_model_test.zig`: in-memory sqlite with the
//! minimal `workspace_items` + `design_pages` + `design_page_elements`
//! schema, ready for the design_model SQL to run against. Tests that
//! exercise file IO use `std.testing.tmpDir` + `realPath` to get a
//! real on-disk path for the `workspace_item.path` column.
//!
//! Plan: docs/superpowers/plans/2026-07-05-design-mode.md (Chunk 1)

const std = @import("std");
const testing = std.testing;
const builtin = @import("builtin");
const nalarcore = @import("nalarcore");
const sqlite = nalarcore.sqlite;

const design_model = @import("design_model.zig");

/// Open a fresh in-memory sqlite DB with the canonical design schema
/// (mirrors Migration 055). Returns the DB + the Io handle (caller
/// must `deinit` both).
fn setupDb() !struct { db: sqlite.SqliteBackend, threaded: std.Io.Threaded } {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    errdefer threaded.deinit();
    const io = threaded.io();
    var db: sqlite.SqliteBackend = .{};
    errdefer db.deinit();
    try db.init(io, ":memory:");

    // workspace_items with a `path` column (so elements can resolve
    // their file_path to an absolute on-disk location).
    try db.exec(alloc,
        \\CREATE TABLE workspace_items (
        \\    id TEXT PRIMARY KEY,
        \\    workspace_id TEXT NOT NULL,
        \\    item_type TEXT NOT NULL DEFAULT 'folder',
        \\    name TEXT NOT NULL DEFAULT '',
        \\    path TEXT NOT NULL DEFAULT '',
        \\    position INTEGER NOT NULL DEFAULT 0,
        \\    created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
        \\    updated_at DATETIME DEFAULT CURRENT_TIMESTAMP
        \\)
    , &.{});
    // design_pages (10 columns, no html, no file_path).
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
        \\    created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
        \\    updated_at DATETIME DEFAULT CURRENT_TIMESTAMP,
        \\    FOREIGN KEY (workspace_item_id) REFERENCES workspace_items(id) ON DELETE CASCADE
        \\)
    , &.{});
    // design_page_elements (12 columns, no html on the row).
    try db.exec(alloc,
        \\CREATE TABLE design_page_elements (
        \\    id TEXT PRIMARY KEY,
        \\    page_id TEXT NOT NULL,
        \\    name TEXT NOT NULL DEFAULT '',
        \\    file_path TEXT NOT NULL DEFAULT '',
        \\    x INTEGER NOT NULL DEFAULT 0,
        \\    y INTEGER NOT NULL DEFAULT 0,
        \\    width INTEGER NOT NULL DEFAULT 375,
        \\    height INTEGER NOT NULL DEFAULT 667,
        \\    z_index INTEGER NOT NULL DEFAULT 0,
        \\    position INTEGER NOT NULL DEFAULT 0,
        \\    created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
        \\    updated_at DATETIME DEFAULT CURRENT_TIMESTAMP,
        \\    FOREIGN KEY (page_id) REFERENCES design_pages(id) ON DELETE CASCADE
        \\)
    , &.{});
    // Indexes (mirrors Migration055AddDesignPagesAndElements).
    try db.exec(alloc,
        "CREATE UNIQUE INDEX idx_design_pages_item_name " ++
        "ON design_pages(workspace_item_id, name)",
        &.{});
    try db.exec(alloc,
        "CREATE INDEX idx_design_pages_item_position " ++
        "ON design_pages(workspace_item_id, position)",
        &.{});
    try db.exec(alloc,
        "CREATE INDEX idx_design_page_elements_page_z_pos " ++
        "ON design_page_elements(page_id, z_index, position)",
        &.{});
    return .{ .db = db, .threaded = threaded };
}

/// Set up a workspace_item with a real on-disk path. Returns the
/// item_id and the tmpDir handle (caller must `defer tmp.cleanup()`
/// and use the item_id to add pages).
fn setupItemWithPath(
    alloc: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    name: []const u8,
) !struct { item_id: []u8, tmp: std.testing.TmpDir } {
    var tmp = testing.tmpDir(.{});
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_len = try tmp.dir.realPath(testing.io, &dir_buf);
    const tmp_dir_path = dir_buf[0..dir_len];

    const item_id = try std.fmt.allocPrint(alloc, "item_{s}", .{name});
    try db.exec(alloc,
        \\INSERT INTO workspace_items (id, workspace_id, item_type, name, path)
        \\VALUES (?, 'ws_test', 'design', ?, ?)
    , &.{ item_id, name, tmp_dir_path });
    return .{ .item_id = item_id, .tmp = tmp };
}

// ─── sanitizeFilename ────────────────────────────────────────────────────

test "sanitizeFilename: lowercase ASCII" {
    const s = try design_model.sanitizeFilename(testing.allocator, "HeroSection");
    defer testing.allocator.free(s);
    try testing.expectEqualStrings("herosection", s);
}

test "sanitizeFilename: collapse whitespace runs to single dash" {
    const s = try design_model.sanitizeFilename(testing.allocator, "  Login   Form  ");
    defer testing.allocator.free(s);
    // Leading/trailing whitespace stripped; internal runs collapsed.
    try testing.expectEqualStrings("login-form", s);
}

test "sanitizeFilename: replace path separators with underscore" {
    const s = try design_model.sanitizeFilename(testing.allocator, "a/b\\c");
    defer testing.allocator.free(s);
    try testing.expectEqualStrings("a_b_c", s);
}

test "sanitizeFilename: strip leading dot" {
    const s = try design_model.sanitizeFilename(testing.allocator, ".hidden");
    defer testing.allocator.free(s);
    try testing.expectEqualStrings("hidden", s);
}

test "sanitizeFilename: keep dots in middle" {
    const s = try design_model.sanitizeFilename(testing.allocator, "v1.2.3");
    defer testing.allocator.free(s);
    try testing.expectEqualStrings("v1.2.3", s);
}

test "sanitizeFilename: empty input returns error.InvalidFilename" {
    const result = design_model.sanitizeFilename(testing.allocator, "");
    try testing.expectError(error.InvalidFilename, result);
}

test "sanitizeFilename: all-whitespace returns error.InvalidFilename" {
    const result = design_model.sanitizeFilename(testing.allocator, "   \t\n");
    try testing.expectError(error.InvalidFilename, result);
}

test "sanitizeFilename: collapses mixed separator+whitespace runs" {
    // The first separator wins for the BETWEEN-content separator
    // (whitespace → '-', path separator → '_'). Subsequent
    // separators in the same run are absorbed by `just_emitted_sep`
    // (so we don't get `a___b` or `a--b`). The first separator
    // happens to be a space here.
    const s = try design_model.sanitizeFilename(testing.allocator, "a / b \\ c");
    defer testing.allocator.free(s);
    try testing.expectEqualStrings("a-b-c", s);
}

// ─── addPage ─────────────────────────────────────────────────────────────

test "addPage creates a metadata-only row, no file IO" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    const id = try design_model.addPage(
        alloc,
        &ctx.db,
        "item_test",
        "Login",
        1440,
        1024,
        0,
        0,
    );
    defer alloc.free(id);
    try testing.expect(std.mem.startsWith(u8, id, "page_"));
}

test "addPage is idempotent on (item_id, name) — updates geometry" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    const id1 = try design_model.addPage(alloc, &ctx.db, "item_test", "Login", 1440, 1024, 0, 0);
    defer alloc.free(id1);
    const id2 = try design_model.addPage(alloc, &ctx.db, "item_test", "Login", 1920, 1080, 100, 50);
    defer alloc.free(id2);

    // The second call updates width/height/x/y of the existing row
    // (id1 still points to it). The returned id2 is freshly allocated
    // and may differ from id1 — that's fine, the DB row's id is id1.
    var q = try ctx.db.query(alloc,
        "SELECT width, height, x, y FROM design_pages WHERE id = ?", &.{id1});
    defer q.deinit();
    const row = (try q.next()) orelse return error.NoRow;
    defer row.deinit(alloc);
    try testing.expectEqual(@as(i64, 1920), try std.fmt.parseInt(i64, row.values[0], 10));
    try testing.expectEqual(@as(i64, 1080), try std.fmt.parseInt(i64, row.values[1], 10));
    try testing.expectEqual(@as(i64, 100), try std.fmt.parseInt(i64, row.values[2], 10));
    try testing.expectEqual(@as(i64, 50), try std.fmt.parseInt(i64, row.values[3], 10));
}

test "addPage assigns incrementing position" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    const a = try design_model.addPage(alloc, &ctx.db, "item_test", "A", 100, 100, 0, 0);
    defer alloc.free(a);
    const b = try design_model.addPage(alloc, &ctx.db, "item_test", "B", 100, 100, 0, 0);
    defer alloc.free(b);
    const c = try design_model.addPage(alloc, &ctx.db, "item_test", "C", 100, 100, 0, 0);
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

// ─── listPages / getPage ─────────────────────────────────────────────────

test "listPages returns rows ordered by position, no html field" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    {
        const id1 = try design_model.addPage(alloc, &ctx.db, "item_test", "First", 1440, 1024, 0, 0);
        defer alloc.free(id1);
        const id2 = try design_model.addPage(alloc, &ctx.db, "item_test", "Second", 1440, 1024, 0, 0);
        defer alloc.free(id2);
    }

    const summaries = try design_model.listPages(alloc, &ctx.db, "item_test");
    defer design_model.freePageSummaries(alloc, summaries);

    try testing.expectEqual(@as(usize, 2), summaries.len);
    try testing.expectEqualStrings("First", summaries[0].name);
    try testing.expectEqualStrings("Second", summaries[1].name);
    try testing.expectEqual(@as(i64, 1440), summaries[0].width);
    try testing.expectEqual(@as(i64, 1024), summaries[0].height);
    // The struct MUST NOT have an `html` field (compile-time check):
    // this test would fail to compile if `html` was added back.
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

    const id = try design_model.addPage(alloc, &ctx.db, "item_test", "Foo", 100, 100, 0, 0);
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

// ─── updatePageGeometry ──────────────────────────────────────────────────

test "updatePageGeometry replaces width/height/x/y and returns true" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    const id = try design_model.addPage(alloc, &ctx.db, "item_test", "Foo", 100, 100, 0, 0);
    defer alloc.free(id);

    const ok = try design_model.updatePageGeometry(alloc, &ctx.db, id, 800, 600, 10, 20);
    try testing.expect(ok);

    const page = try design_model.getPage(alloc, &ctx.db, id);
    defer design_model.freePageFull(alloc, page);
    try testing.expectEqual(@as(i64, 800), page.width);
    try testing.expectEqual(@as(i64, 600), page.height);
    try testing.expectEqual(@as(i64, 10), page.x);
    try testing.expectEqual(@as(i64, 20), page.y);
}

test "updatePageGeometry on missing id returns false" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    const ok = try design_model.updatePageGeometry(alloc, &ctx.db, "page_missing", 100, 100, 0, 0);
    try testing.expect(!ok);
}

// ─── addElement ──────────────────────────────────────────────────────────

test "addElement writes the html to disk + INSERTs the metadata row" {
    if (builtin.os.tag == .windows) return; // skip on Windows CI cell
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    var item_setup = try setupItemWithPath(alloc, &ctx.db, "DesignProj");
    defer item_setup.tmp.cleanup();
    defer alloc.free(item_setup.item_id);

    const page_id = try design_model.addPage(alloc, &ctx.db, item_setup.item_id, "Login", 1440, 1024, 0, 0);
    defer alloc.free(page_id);

    const elem_id = try design_model.addElement(
        alloc,
        ctx.threaded.io(),
        &ctx.db,
        page_id,
        "HeroBanner",
        "<h1>Welcome</h1>",
        100,
        50,
        800,
        200,
        0,
    );
    defer alloc.free(elem_id);
    try testing.expect(std.mem.startsWith(u8, elem_id, "elem_"));

    // The file should exist at
    // <tmp>/.nalar/design/Login/herobanner.html
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_len = try item_setup.tmp.dir.realPath(testing.io, &dir_buf);
    const tmp_dir_path = dir_buf[0..dir_len];
    const file_path = try std.fs.path.join(alloc, &.{
        tmp_dir_path, ".nalar", "design", "Login", "herobanner.html",
    });
    defer alloc.free(file_path);

    // Verify the file exists + content matches via helpers.readFile.
    const content = try nalarcore.helpers.readFile(alloc, file_path);
    defer alloc.free(content);
    try testing.expectEqualStrings("<h1>Welcome</h1>", content);

    // Verify the DB row has the expected file_path.
    var q = try ctx.db.query(alloc,
        "SELECT dpe.file_path FROM design_page_elements dpe WHERE dpe.id = ?",
        &.{elem_id});
    defer q.deinit();
    const row = (try q.next()) orelse return error.NoRow;
    defer row.deinit(alloc);
    try testing.expectEqualStrings(".nalar/design/Login/herobanner.html", row.values[0]);
}

test "addElement rejects InvalidFilename when name sanitizes to empty" {
    if (builtin.os.tag == .windows) return;
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    var item_setup = try setupItemWithPath(alloc, &ctx.db, "DesignProj");
    defer item_setup.tmp.cleanup();
    defer alloc.free(item_setup.item_id);

    const page_id = try design_model.addPage(alloc, &ctx.db, item_setup.item_id, "Login", 1440, 1024, 0, 0);
    defer alloc.free(page_id);

    // Name "..." → sanitized "" → InvalidFilename.
    const result = design_model.addElement(
        alloc,
        ctx.threaded.io(),
        &ctx.db,
        page_id,
        "...",
        "<h1>x</h1>",
        0,
        0,
        100,
        100,
        0,
    );
    try testing.expectError(error.InvalidFilename, result);
}

// ─── getElement ──────────────────────────────────────────────────────────

test "getElement reads the html from disk into DesignPageElementFull" {
    if (builtin.os.tag == .windows) return;
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    var item_setup = try setupItemWithPath(alloc, &ctx.db, "DesignProj");
    defer item_setup.tmp.cleanup();
    defer alloc.free(item_setup.item_id);

    const page_id = try design_model.addPage(alloc, &ctx.db, item_setup.item_id, "Login", 1440, 1024, 0, 0);
    defer alloc.free(page_id);

    const elem_id = try design_model.addElement(
        alloc,
        ctx.threaded.io(),
        &ctx.db,
        page_id,
        "LoginButton",
        "<button>Go</button>",
        50,
        50,
        120,
        40,
        1,
    );
    defer alloc.free(elem_id);

    const el = try design_model.getElement(alloc, ctx.threaded.io(), &ctx.db, elem_id);
    defer design_model.freeElementFull(alloc, el);

    try testing.expectEqualStrings(elem_id, el.id);
    try testing.expectEqualStrings(page_id, el.page_id);
    try testing.expectEqualStrings("LoginButton", el.name);
    try testing.expectEqualStrings("<button>Go</button>", el.html);
    try testing.expectEqualStrings(".nalar/design/Login/loginbutton.html", el.file_path);
    try testing.expectEqual(@as(i64, 50), el.x);
    try testing.expectEqual(@as(i64, 50), el.y);
    try testing.expectEqual(@as(i64, 120), el.width);
    try testing.expectEqual(@as(i64, 40), el.height);
    try testing.expectEqual(@as(i64, 1), el.z_index);
}

test "getElement on missing id returns error.ElementNotFound" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    const result = design_model.getElement(
        alloc,
        ctx.threaded.io(),
        &ctx.db,
        "elem_does_not_exist",
    );
    try testing.expectError(error.ElementNotFound, result);
}

// ─── listElements ────────────────────────────────────────────────────────

test "listElements returns metadata only, ordered by z_index,position" {
    if (builtin.os.tag == .windows) return;
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    var item_setup = try setupItemWithPath(alloc, &ctx.db, "DesignProj");
    defer item_setup.tmp.cleanup();
    defer alloc.free(item_setup.item_id);

    const page_id = try design_model.addPage(alloc, &ctx.db, item_setup.item_id, "Login", 1440, 1024, 0, 0);
    defer alloc.free(page_id);

    // Add 3 elements with mixed z_index. Order in list should be:
    // z=0 first (both), then z=2. Within z=0, position=0 before
    // position=1.
    const a = try design_model.addElement(alloc, ctx.threaded.io(), &ctx.db, page_id, "a", "<a/>", 0, 0, 100, 100, 0);
    defer alloc.free(a);
    const b = try design_model.addElement(alloc, ctx.threaded.io(), &ctx.db, page_id, "b", "<b/>", 0, 0, 100, 100, 2);
    defer alloc.free(b);
    const c = try design_model.addElement(alloc, ctx.threaded.io(), &ctx.db, page_id, "c", "<c/>", 0, 0, 100, 100, 0);
    defer alloc.free(c);

    const elements = try design_model.listElements(alloc, &ctx.db, page_id);
    defer design_model.freeElements(alloc, elements);

    try testing.expectEqual(@as(usize, 3), elements.len);
    try testing.expectEqualStrings("a", elements[0].name);
    try testing.expectEqual(@as(i64, 0), elements[0].z_index);
    try testing.expectEqualStrings("c", elements[1].name);
    try testing.expectEqual(@as(i64, 0), elements[1].z_index);
    try testing.expectEqualStrings("b", elements[2].name);
    try testing.expectEqual(@as(i64, 2), elements[2].z_index);
}

// ─── moveElement / resizeElement ─────────────────────────────────────────

test "moveElement updates x/y only, file untouched" {
    if (builtin.os.tag == .windows) return;
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    var item_setup = try setupItemWithPath(alloc, &ctx.db, "DesignProj");
    defer item_setup.tmp.cleanup();
    defer alloc.free(item_setup.item_id);

    const page_id = try design_model.addPage(alloc, &ctx.db, item_setup.item_id, "Login", 1440, 1024, 0, 0);
    defer alloc.free(page_id);
    const elem_id = try design_model.addElement(alloc, ctx.threaded.io(), &ctx.db, page_id, "x", "<x/>", 0, 0, 100, 100, 0);
    defer alloc.free(elem_id);

    try design_model.moveElement(alloc, &ctx.db, elem_id, 250, 350);

    const el = try design_model.getElement(alloc, ctx.threaded.io(), &ctx.db, elem_id);
    defer design_model.freeElementFull(alloc, el);
    try testing.expectEqual(@as(i64, 250), el.x);
    try testing.expectEqual(@as(i64, 350), el.y);
    // Width/height/z_index unchanged.
    try testing.expectEqual(@as(i64, 100), el.width);
    try testing.expectEqual(@as(i64, 100), el.height);
    try testing.expectEqual(@as(i64, 0), el.z_index);
    // File content unchanged.
    try testing.expectEqualStrings("<x/>", el.html);
}

test "resizeElement updates width/height only" {
    if (builtin.os.tag == .windows) return;
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    var item_setup = try setupItemWithPath(alloc, &ctx.db, "DesignProj");
    defer item_setup.tmp.cleanup();
    defer alloc.free(item_setup.item_id);

    const page_id = try design_model.addPage(alloc, &ctx.db, item_setup.item_id, "Login", 1440, 1024, 0, 0);
    defer alloc.free(page_id);
    const elem_id = try design_model.addElement(alloc, ctx.threaded.io(), &ctx.db, page_id, "x", "<x/>", 0, 0, 100, 100, 0);
    defer alloc.free(elem_id);

    try design_model.resizeElement(alloc, &ctx.db, elem_id, 800, 600);

    const el = try design_model.getElement(alloc, ctx.threaded.io(), &ctx.db, elem_id);
    defer design_model.freeElementFull(alloc, el);
    try testing.expectEqual(@as(i64, 800), el.width);
    try testing.expectEqual(@as(i64, 600), el.height);
    try testing.expectEqual(@as(i64, 0), el.x);
    try testing.expectEqual(@as(i64, 0), el.y);
}

// ─── deleteElement ───────────────────────────────────────────────────────

test "deleteElement removes the row AND the file" {
    if (builtin.os.tag == .windows) return;
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    var item_setup = try setupItemWithPath(alloc, &ctx.db, "DesignProj");
    defer item_setup.tmp.cleanup();
    defer alloc.free(item_setup.item_id);

    const page_id = try design_model.addPage(alloc, &ctx.db, item_setup.item_id, "Login", 1440, 1024, 0, 0);
    defer alloc.free(page_id);
    const elem_id = try design_model.addElement(alloc, ctx.threaded.io(), &ctx.db, page_id, "doomed", "<d/>", 0, 0, 50, 50, 0);
    defer alloc.free(elem_id);

    // File exists.
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_len = try item_setup.tmp.dir.realPath(testing.io, &dir_buf);
    const tmp_dir_path = dir_buf[0..dir_len];
    const file_path = try std.fs.path.join(alloc, &.{
        tmp_dir_path, ".nalar", "design", "Login", "doomed.html",
    });
    defer alloc.free(file_path);
    try testing.expect(nalarcore.helpers.fileExists(file_path));

    const deleted = try design_model.deleteElement(alloc, &ctx.db, elem_id);
    try testing.expect(deleted);

    // File gone.
    try testing.expect(!nalarcore.helpers.fileExists(file_path));
    // Row gone.
    const result = design_model.getElement(alloc, ctx.threaded.io(), &ctx.db, elem_id);
    try testing.expectError(error.ElementNotFound, result);
}

test "deleteElement on missing id returns false (idempotent)" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    const deleted = try design_model.deleteElement(alloc, &ctx.db, "elem_missing");
    try testing.expect(!deleted);
}

// ─── updateElement (partial update) ──────────────────────────────────────

test "updateElement with html writes the new file, no metadata change" {
    if (builtin.os.tag == .windows) return;
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    var item_setup = try setupItemWithPath(alloc, &ctx.db, "DesignProj");
    defer item_setup.tmp.cleanup();
    defer alloc.free(item_setup.item_id);

    const page_id = try design_model.addPage(alloc, &ctx.db, item_setup.item_id, "Login", 1440, 1024, 0, 0);
    defer alloc.free(page_id);
    const elem_id = try design_model.addElement(alloc, ctx.threaded.io(), &ctx.db, page_id, "v1", "<old/>", 0, 0, 100, 100, 0);
    defer alloc.free(elem_id);

    try design_model.updateElement(alloc, ctx.threaded.io(), &ctx.db, elem_id, .{
        .html = "<new/>",
        .x = null,
        .y = null,
        .width = null,
        .height = null,
        .z_index = null,
        .name = null,
    });

    const el = try design_model.getElement(alloc, ctx.threaded.io(), &ctx.db, elem_id);
    defer design_model.freeElementFull(alloc, el);
    try testing.expectEqualStrings("<new/>", el.html);
    try testing.expectEqualStrings("v1", el.name);
    try testing.expectEqualStrings(".nalar/design/Login/v1.html", el.file_path);
}

test "updateElement with new name moves the file to the new path" {
    if (builtin.os.tag == .windows) return;
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    var item_setup = try setupItemWithPath(alloc, &ctx.db, "DesignProj");
    defer item_setup.tmp.cleanup();
    defer alloc.free(item_setup.item_id);

    const page_id = try design_model.addPage(alloc, &ctx.db, item_setup.item_id, "Login", 1440, 1024, 0, 0);
    defer alloc.free(page_id);
    const elem_id = try design_model.addElement(alloc, ctx.threaded.io(), &ctx.db, page_id, "OldName", "<o/>", 0, 0, 100, 100, 0);
    defer alloc.free(elem_id);

    try design_model.updateElement(alloc, ctx.threaded.io(), &ctx.db, elem_id, .{
        .html = null,
        .x = null,
        .y = null,
        .width = null,
        .height = null,
        .z_index = null,
        .name = "NewName",
    });

    const el = try design_model.getElement(alloc, ctx.threaded.io(), &ctx.db, elem_id);
    defer design_model.freeElementFull(alloc, el);
    try testing.expectEqualStrings("NewName", el.name);
    try testing.expectEqualStrings(".nalar/design/Login/newname.html", el.file_path);
    try testing.expectEqualStrings("<o/>", el.html);

    // The new file exists; the old one is gone.
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_len = try item_setup.tmp.dir.realPath(testing.io, &dir_buf);
    const tmp_dir_path = dir_buf[0..dir_len];
    const old_path = try std.fs.path.join(alloc, &.{
        tmp_dir_path, ".nalar", "design", "Login", "oldname.html",
    });
    defer alloc.free(old_path);
    const new_path = try std.fs.path.join(alloc, &.{
        tmp_dir_path, ".nalar", "design", "Login", "newname.html",
    });
    defer alloc.free(new_path);
    try testing.expect(!nalarcore.helpers.fileExists(old_path));
    try testing.expect(nalarcore.helpers.fileExists(new_path));
}

test "updateElement with all-null params is a no-op (bump updated_at)" {
    if (builtin.os.tag == .windows) return;
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    var item_setup = try setupItemWithPath(alloc, &ctx.db, "DesignProj");
    defer item_setup.tmp.cleanup();
    defer alloc.free(item_setup.item_id);

    const page_id = try design_model.addPage(alloc, &ctx.db, item_setup.item_id, "Login", 1440, 1024, 0, 0);
    defer alloc.free(page_id);
    const elem_id = try design_model.addElement(alloc, ctx.threaded.io(), &ctx.db, page_id, "x", "<x/>", 0, 0, 100, 100, 0);
    defer alloc.free(elem_id);

    // All null → just bumps updated_at. Should not fail.
    try design_model.updateElement(alloc, ctx.threaded.io(), &ctx.db, elem_id, .{
        .html = null,
        .x = null,
        .y = null,
        .width = null,
        .height = null,
        .z_index = null,
        .name = null,
    });

    const el = try design_model.getElement(alloc, ctx.threaded.io(), &ctx.db, elem_id);
    defer design_model.freeElementFull(alloc, el);
    try testing.expectEqualStrings("<x/>", el.html);
}