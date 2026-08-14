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

    // workspace_item_tasks (required by setDesignPage since the FK
    // work — each new page is paired with a chat task row in the
    // same transaction).
    try db.exec(alloc,
        \\CREATE TABLE workspace_item_tasks (
        \\    id TEXT PRIMARY KEY,
        \\    name TEXT NOT NULL,
        \\    workspace_item_id TEXT NOT NULL,
        \\    task_type TEXT NOT NULL DEFAULT 'standard',
        \\    description TEXT NOT NULL DEFAULT '',
        \\    created_at DATETIME,
        \\    updated_at DATETIME)
    , &.{});

    // design_pages (v6 schema + post-Migration-066
    // workspace_item_task_id column).
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
        \\    UNIQUE (workspace_item_task_id),
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

// ─── Test: addElement writes a row + a file ──────────────────────────────

test "addElement creates a row + writes the HTML file" {
    const alloc = testing.allocator;
    var ctx = try setupDbAndItem();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();
    defer alloc.free(ctx.item_id);
    defer alloc.free(ctx.item_path);

    // Create a page first.
    const page_id = try design_model.setDesignPage(alloc, &ctx.db, .{
        .item_id = ctx.item_id,
        .page_name = "Login",
        .width = 1440,
        .height = 1024,
    });
    defer alloc.free(page_id);

    // Add the element.
    const element_id = try design_model.addElement(alloc, &ctx.db, ctx.threaded.io(), .{
        .page_id = page_id,
        .name = "login-card",
        .elem_type = .rectangle,
        .html = "<div>Login</div>",
        .x = 100,
        .y = 200,
        .width = 400,
        .height = 300,
        .fill = "#ffffff",
        .rotation = 0.0,
        .corner_radius = 0,
        .opacity = 1.0,
    });
    defer alloc.free(element_id);

    // Generated id starts with "elem_".
    try testing.expect(element_id.len > 4);
    try testing.expect(std.mem.startsWith(u8, element_id, "elem_"));

    // Verify the HTML file was written to disk.
    const file_path = try std.fs.path.join(alloc, &.{
        ctx.item_path,
        ".nalar/design/Login/login-card.html",
    });
    defer alloc.free(file_path);

    const content = try std.Io.Dir.cwd().readFileAlloc(ctx.threaded.io(), file_path, alloc, .limited(1024));
    defer alloc.free(content);
    try testing.expectEqualStrings("<div>Login</div>", content);
}

// ─── Test: addElement with empty fill succeeds (NOT NULL constraint) ─────
//
// REGRESSION (2026-08-14, "design mode, add element manual not
// working" — second wave). The HTTP handler resolves `fill` to the
// empty string when the user doesn't provide one (see
// design_elements_create.zig:278 `.fill = parsed.fill orelse ""`).
// The project's `sqlite-backend-empty-slice-binds-as-null`
// optimization then binds that empty string as SQL NULL. But the
// `fill` column is `TEXT NOT NULL DEFAULT ''` — the constraint
// rejects the INSERT with `NOT NULL constraint failed:
// design_page_elements.fill`, the handler maps to error.DbError,
// the useCase to 500, the user sees "Failed to create element" and
// the dialog closes without adding anything.
//
// The production INSERT was reachable when the production server
// sent the request through the wire (pre-fix, the entire
// @create-element binding was missing — fixed earlier). The empty
// fill path is now the only reachable bug for the "+ Element → Add"
// flow. The first regression test ensures the fix sticks.
//
// Why no whitespace coercion at the handler: that would mask the
// symptom in one place while other NOT NULL columns (text_content /
// text_style / image_url — all currently passed as literals, but
// `fill` is the first NOT NULL column the bind layer sees) could
// regress the same way. The fix is at the SQL: COALESCE(?, '') on
// the `fill` parameter so a NULL bind lands as the column's own
// default (empty string), which is what the schema author intended.
test "addElement with empty fill succeeds (NOT NULL fill column)" {
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

    // The pre-fix bug: passing fill="" with the empty-slice-binds-
    // as-null optimization makes sqlite3_bind_null fire, which the
    // NOT NULL constraint rejects. The test asserts this path
    // succeeds end-to-end (creates a row, getElement reads it back).
    const element_id = try design_model.addElement(alloc, &ctx.db, ctx.threaded.io(), .{
        .page_id = page_id,
        .name = "kotak",
        .elem_type = .rectangle,
        .html = "<div></div>",
        .x = 0,
        .y = 0,
        .width = 375,
        .height = 667,
        .fill = "", // <- the bug-trigger. Empty slice → bind NULL → NOT NULL fail.
        .rotation = 0.0,
        .corner_radius = 0,
        .opacity = 1.0,
    });
    defer alloc.free(element_id);

    // Read it back and confirm the row is sane.
    const row = try design_model.getElement(alloc, &ctx.db, element_id);
    defer design_model.freeElement(alloc, row);
    try testing.expectEqualStrings("kotak", row.name);
    try testing.expectEqualStrings("rectangle", row.elem_type);
    // The column default is '' — empty string in storage is the
    // schema's intent. The fix normalizes the bind-NULL leak into
    // either '' (already the default) or the user's value.
    try testing.expectEqual(@as(usize, 0), row.fill.len);
}

// ─── Test: loadElementHtml round-trips the original HTML ─────────────────

test "loadElementHtml returns the original HTML body" {
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

    const element_id = try design_model.addElement(alloc, &ctx.db, ctx.threaded.io(), .{
        .page_id = page_id,
        .name = "hero",
        .elem_type = .rectangle,
        .html = "<h1>Welcome</h1>",
        .x = 0,
        .y = 0,
        .width = 200,
        .height = 100,
        .fill = "#22c55e",
        .rotation = 0.0,
        .corner_radius = 0,
        .opacity = 1.0,
    });
    defer alloc.free(element_id);

    const html = try design_model.loadElementHtml(alloc, ctx.threaded.io(), &ctx.db, element_id);
    defer alloc.free(html);
    try testing.expectEqualStrings("<h1>Welcome</h1>", html);
}

// ─── Test: deleteElement removes the row and the file ───────────────────

test "deleteElement removes the row and unlinks the file" {
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

    const element_id = try design_model.addElement(alloc, &ctx.db, ctx.threaded.io(), .{
        .page_id = page_id,
        .name = "card",
        .elem_type = .rectangle,
        .html = "<div>card</div>",
        .x = 0,
        .y = 0,
        .width = 100,
        .height = 100,
        .fill = "#ffffff",  // `db.exec` binds `""` as NULL which would
                            //  violate the NOT NULL constraint on fill.
        .rotation = 0.0,
        .corner_radius = 0,
        .opacity = 1.0,
    });
    defer alloc.free(element_id);

    const file_path = try std.fs.path.join(alloc, &.{
        ctx.item_path,
        ".nalar/design/Home/card.html",
    });
    defer alloc.free(file_path);

    // Sanity: file exists before delete.
    {
        const stat_before = try std.Io.Dir.cwd().statFile(ctx.threaded.io(), file_path, .{});
        try testing.expect(stat_before.kind == .file);
    }

    // Delete.
    const was_deleted = try design_model.deleteElement(alloc, &ctx.db, element_id);
    try testing.expect(was_deleted);

    // File is gone.
    const stat_after_result = std.Io.Dir.cwd().statFile(ctx.threaded.io(), file_path, .{});
    try testing.expectError(error.FileNotFound, stat_after_result);

    // deleteElement on a missing id returns false.
    const was_deleted2 = try design_model.deleteElement(alloc, &ctx.db, element_id);
    try testing.expect(!was_deleted2);
}

// ─── Test: getPageWithElements returns page + elements (no HTML bodies) ──

test "getPageWithElements returns page + its elements" {
    const alloc = testing.allocator;
    var ctx = try setupDbAndItem();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();
    defer alloc.free(ctx.item_id);
    defer alloc.free(ctx.item_path);

    // Create a page, then add 2 elements to it.
    const page_id = try design_model.setDesignPage(alloc, &ctx.db, .{
        .item_id = ctx.item_id,
        .page_name = "Home",
        .width = 1440,
        .height = 1024,
    });
    defer alloc.free(page_id);

    const e1_id = try design_model.addElement(alloc, &ctx.db, ctx.threaded.io(), .{
        .page_id = page_id,
        .name = "hero",
        .elem_type = .rectangle,
        .html = "<div>hero</div>",
        .x = 10,
        .y = 20,
        .width = 100,
        .height = 50,
        .fill = "#22c55e",
        .rotation = 0.0,
        .corner_radius = 0,
        .opacity = 1.0,
    });
    defer alloc.free(e1_id);

    const e2_id = try design_model.addElement(alloc, &ctx.db, ctx.threaded.io(), .{
        .page_id = page_id,
        .name = "card",
        .elem_type = .text,
        .html = "<p>hi</p>",
        .x = 30,
        .y = 40,
        .width = 200,
        .height = 80,
        .fill = "#ffffff",
        .rotation = 0.0,
        .corner_radius = 0,
        .opacity = 1.0,
        .text_content = "hello world",
    });
    defer alloc.free(e2_id);

    const bundle = try design_model.getPageWithElements(alloc, &ctx.db, page_id);
    defer bundle.deinit(alloc);

    // Page fields populated correctly.
    try testing.expectEqualStrings(page_id, bundle.page.id);
    try testing.expectEqualStrings("Home", bundle.page.name);
    try testing.expectEqual(@as(i64, 1440), bundle.page.width);
    try testing.expectEqual(@as(i64, 1024), bundle.page.height);

    // Two elements returned in (z_index, position) order.
    try testing.expectEqual(@as(usize, 2), bundle.elements.len);
    try testing.expectEqualStrings("hero", bundle.elements[0].name);
    try testing.expectEqualStrings("card", bundle.elements[1].name);
    try testing.expectEqualStrings(e1_id, bundle.elements[0].id);
    try testing.expectEqualStrings(e2_id, bundle.elements[1].id);

    // Element fields populated (file_path included, but no html body
    // — loadElementHtml must be called separately to fetch it).
    try testing.expect(bundle.elements[0].file_path.len > 0);
    try testing.expectEqualStrings("rectangle", bundle.elements[0].elem_type);
    try testing.expectEqualStrings("text", bundle.elements[1].elem_type);
    try testing.expectEqual(@as(i64, 10), bundle.elements[0].x);
    try testing.expectEqual(@as(i64, 20), bundle.elements[0].y);
    try testing.expectEqual(@as(i64, 100), bundle.elements[0].width);
    try testing.expectEqual(@as(i64, 50), bundle.elements[0].height);
    try testing.expectEqualStrings("#22c55e", bundle.elements[0].fill);
}

test "getPageWithElements returns PageNotFound for missing page_id" {
    const alloc = testing.allocator;
    var ctx = try setupDbAndItem();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();
    defer alloc.free(ctx.item_id);
    defer alloc.free(ctx.item_path);

    const result = design_model.getPageWithElements(alloc, &ctx.db, "page_does_not_exist");
    try testing.expectError(error.PageNotFound, result);
}

test "getPageWithElements on page with zero elements returns empty slice" {
    const alloc = testing.allocator;
    var ctx = try setupDbAndItem();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();
    defer alloc.free(ctx.item_id);
    defer alloc.free(ctx.item_path);

    const page_id = try design_model.setDesignPage(alloc, &ctx.db, .{
        .item_id = ctx.item_id,
        .page_name = "Empty",
        .width = 1440,
        .height = 1024,
    });
    defer alloc.free(page_id);

    const bundle = try design_model.getPageWithElements(alloc, &ctx.db, page_id);
    defer bundle.deinit(alloc);

    try testing.expectEqual(@as(usize, 0), bundle.elements.len);
    try testing.expectEqualStrings("Empty", bundle.page.name);
}

// ─── Test: listPagesWithElements returns all pages with their elements ──

test "listPagesWithElements returns all pages with their elements" {
    const alloc = testing.allocator;
    var ctx = try setupDbAndItem();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();
    defer alloc.free(ctx.item_id);
    defer alloc.free(ctx.item_path);

    // Create 2 pages with elements on each.
    const page1_id = try design_model.setDesignPage(alloc, &ctx.db, .{
        .item_id = ctx.item_id,
        .page_name = "Home",
        .width = 1440,
        .height = 1024,
    });
    defer alloc.free(page1_id);

    const page2_id = try design_model.setDesignPage(alloc, &ctx.db, .{
        .item_id = ctx.item_id,
        .page_name = "Login",
        .width = 800,
        .height = 600,
    });
    defer alloc.free(page2_id);

    // 2 elements on page1, 1 element on page2.
    const p1e1 = try design_model.addElement(alloc, &ctx.db, ctx.threaded.io(), .{
        .page_id = page1_id, .name = "hero", .elem_type = .rectangle,
        .html = "<div>hero</div>", .x = 0, .y = 0, .width = 100, .height = 50,
        .fill = "#22c55e", .rotation = 0.0, .corner_radius = 0, .opacity = 1.0,
    });
    defer alloc.free(p1e1);
    const p1e2 = try design_model.addElement(alloc, &ctx.db, ctx.threaded.io(), .{
        .page_id = page1_id, .name = "footer", .elem_type = .rectangle,
        .html = "<footer/>", .x = 0, .y = 1000, .width = 1440, .height = 24,
        .fill = "#000", .rotation = 0.0, .corner_radius = 0, .opacity = 1.0,
    });
    defer alloc.free(p1e2);
    const p2e1 = try design_model.addElement(alloc, &ctx.db, ctx.threaded.io(), .{
        .page_id = page2_id, .name = "submit", .elem_type = .rectangle,
        .html = "<button/>", .x = 100, .y = 200, .width = 200, .height = 40,
        .fill = "#3b82f6", .rotation = 0.0, .corner_radius = 4, .opacity = 1.0,
    });
    defer alloc.free(p2e1);

    const results = try design_model.listPagesWithElements(alloc, &ctx.db, ctx.item_id);
    defer design_model.freePagesWithElements(alloc, results);

    // 2 pages returned, in (position ASC) order.
    try testing.expectEqual(@as(usize, 2), results.len);
    try testing.expectEqualStrings("Home", results[0].page.name);
    try testing.expectEqualStrings("Login", results[1].page.name);

    // Page 1 has 2 elements.
    try testing.expectEqual(@as(usize, 2), results[0].elements.len);
    try testing.expectEqualStrings("hero", results[0].elements[0].name);
    try testing.expectEqualStrings("footer", results[0].elements[1].name);

    // Page 2 has 1 element.
    try testing.expectEqual(@as(usize, 1), results[1].elements.len);
    try testing.expectEqualStrings("submit", results[1].elements[0].name);
    try testing.expectEqual(@as(i64, 4), results[1].elements[0].corner_radius);
}

test "listPagesWithElements returns empty slice for an item with no pages" {
    const alloc = testing.allocator;
    var ctx = try setupDbAndItem();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();
    defer alloc.free(ctx.item_id);
    defer alloc.free(ctx.item_path);

    const results = try design_model.listPagesWithElements(alloc, &ctx.db, ctx.item_id);
    defer design_model.freePagesWithElements(alloc, results);
    try testing.expectEqual(@as(usize, 0), results.len);
}

test "listPagesWithElements on item where one page has zero elements" {
    const alloc = testing.allocator;
    var ctx = try setupDbAndItem();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();
    defer alloc.free(ctx.item_id);
    defer alloc.free(ctx.item_path);

    // Page A has 1 element, Page B has 0 elements.
    const pageA = try design_model.setDesignPage(alloc, &ctx.db, .{
        .item_id = ctx.item_id,
        .page_name = "A",
        .width = 100, .height = 100,
    });
    defer alloc.free(pageA);

    const pageB = try design_model.setDesignPage(alloc, &ctx.db, .{
        .item_id = ctx.item_id,
        .page_name = "B",
        .width = 200, .height = 200,
    });
    defer alloc.free(pageB);

    const a_e1 = try design_model.addElement(alloc, &ctx.db, ctx.threaded.io(), .{
        .page_id = pageA, .name = "thing", .elem_type = .rectangle,
        .html = "<x/>", .x = 0, .y = 0, .width = 10, .height = 10,
        .fill = "#fff", .rotation = 0.0, .corner_radius = 0, .opacity = 1.0,
    });
    defer alloc.free(a_e1);

    const results = try design_model.listPagesWithElements(alloc, &ctx.db, ctx.item_id);
    defer design_model.freePagesWithElements(alloc, results);

    try testing.expectEqual(@as(usize, 2), results.len);
    try testing.expectEqualStrings("A", results[0].page.name);
    try testing.expectEqual(@as(usize, 1), results[0].elements.len);
    try testing.expectEqualStrings("B", results[1].page.name);
    try testing.expectEqual(@as(usize, 0), results[1].elements.len);
}
