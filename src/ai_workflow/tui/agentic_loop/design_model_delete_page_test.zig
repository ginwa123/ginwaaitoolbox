//! Behavioural tests for `design_model.deletePage`.
//!
//! Why this file exists
//! ────────────────────
//! `deletePage` removes a page's metadata row + cascades to its element
//! rows (FK ON DELETE CASCADE) + cascade-deletes the paired
//! `workspace_item_tasks` row + rmdirs the on-disk page folder.
//!
//! Historically the on-disk folder path was built by JOINing
//! `workspace_items` to read `wi.path` + `dp.name`, then formatting
//! `<path>/.nalar/design/<sanitized_page>`. That required `deletePage`
//! to SELECT from `workspace_items` on every page-delete — and (more
//! importantly) failed when the workspace item row was missing or its
//! `path` column was NULL/empty.
//!
//! The new lookup derives the page folder from `design_page_elements
//! .file_path` via `std.fs.path.dirname(file_path)`. `file_path` is an
//! absolute path that already includes the workspace item's `path` as
//! its prefix — so the directory is recoverable without touching
//! `workspace_items` at all.
//!
//! Plan: 2026-08-06 do-not-delete-from-workspace-items — derived page
//! folder from `design_page_elements.file_path`, not from JOIN.

const std = @import("std");
const testing = std.testing;
const nalarcore = @import("nalarcore");
const sqlite = nalarcore.sqlite;

const design_model = @import("design_model.zig");

const ITEM_ID = "item_design_delete_page_test";

/// Minimal in-memory DB shape (mirrors `design_model_delete_parent_test.zig`).
/// Includes `workspace_items.path` so we can also confirm the new code
/// path works when the item row is deleted FIRST (no path lookup).
fn setupDb() !struct {
    db: sqlite.SqliteBackend,
    threaded: std.Io.Threaded,
    item_path: []u8,
} {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    errdefer threaded.deinit();
    const io = threaded.io();

    var db: sqlite.SqliteBackend = .{};
    errdefer db.deinit();
    try db.init(io, ":memory:");

    // SQLite has FK enforcement OFF by default; the production code's
    // comment on deletePage says it relies on `ON DELETE CASCADE` to
    // remove the element rows, so we enable FK enforcement in this
    // test to match the documented contract.
    try db.exec(alloc, "PRAGMA foreign_keys = ON", &.{});

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

    try db.exec(alloc,
        "INSERT INTO workspace_items (id, workspace_id, item_type, path) " ++
        "VALUES (?, 'ws_test', 'design', ?)",
        &.{ ITEM_ID, tmpdir_path });

    return .{ .db = db, .threaded = threaded, .item_path = tmpdir_path };
}

/// Insert one design_page_elements row whose `file_path` is the full
/// absolute path to its on-disk HTML file. Creates the file + page
/// directory on disk so deletePage's rmdir step has something to
/// remove.
fn insertElementWithDiskFile(
    alloc: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    io: std.Io,
    id: []const u8,
    page_id: []const u8,
    page_dir: []const u8,
    elem_name: []const u8,
) ![]u8 {
    const sanitized_elem = try std.fmt.allocPrint(alloc, "{s}.html", .{elem_name});
    defer alloc.free(sanitized_elem);
    const file_path = try std.fs.path.join(alloc, &.{ page_dir, sanitized_elem });

    // Ensure the page directory exists on disk + write a dummy HTML body.
    std.Io.Dir.cwd().createDirPath(io, page_dir) catch return error.FileWriteFailed;
    const f = std.Io.Dir.cwd().createFile(io, file_path, .{}) catch return error.FileWriteFailed;
    f.close(io);
    const body = "<html><body>hello</body></html>";
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = file_path, .data = body });

    const x_str = try std.fmt.allocPrint(alloc, "{d}", .{0});
    defer alloc.free(x_str);
    const y_str = try std.fmt.allocPrint(alloc, "{d}", .{0});
    defer alloc.free(y_str);
    const w_str = try std.fmt.allocPrint(alloc, "{d}", .{100});
    defer alloc.free(w_str);
    const h_str = try std.fmt.allocPrint(alloc, "{d}", .{100});
    defer alloc.free(h_str);
    try db.exec(alloc,
        \\INSERT INTO design_page_elements
        \\   (id, page_id, name, file_path, x, y, width, height, z_index, position,
        \\    type, rotation, fill, stroke, stroke_width, corner_radius, opacity,
        \\    text_content, text_style, image_url, parent_id,
        \\    created_at, updated_at)
        \\VALUES
        \\   (?, ?, ?, ?, ?, ?, ?, ?, 0, 0,
        \\    'rectangle', 0.0, '#ffffff', '', 0, 0, 1.0,
        \\    '', '', '', '', datetime('now'), datetime('now'))
    , &.{ id, page_id, elem_name, file_path, x_str, y_str, w_str, h_str });

    return file_path;
}

fn pageIdExists(alloc: std.mem.Allocator, db: *sqlite.SqliteBackend, page_id: []const u8) !bool {
    var q = try db.query(alloc,
        "SELECT 1 FROM design_pages WHERE id = ?",
        &.{page_id});
    defer q.deinit();
    const row = try q.next();
    if (row) |r| {
        defer r.deinit(alloc);
        return true;
    }
    return false;
}

fn elementIdExists(alloc: std.mem.Allocator, db: *sqlite.SqliteBackend, id: []const u8) !bool {
    var q = try db.query(alloc,
        "SELECT 1 FROM design_page_elements WHERE id = ?",
        &.{id});
    defer q.deinit();
    const row = try q.next();
    if (row) |r| {
        defer r.deinit(alloc);
        return true;
    }
    return false;
}

fn dirExists(io: std.Io, path: []const u8) bool {
    var dir = std.Io.Dir.openDirAbsolute(io, path, .{}) catch return false;
    dir.close(io);
    return true;
}

fn fileExists(io: std.Io, path: []const u8) bool {
    var f = std.Io.Dir.cwd().openFile(io, path, .{}) catch return false;
    f.close(io);
    return true;
}

// ─── Behavioural tests ───────────────────────────────────────────────────

test "deletePage returns false when page_id does not exist" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();
    defer alloc.free(ctx.item_path);

    const was_deleted = try design_model.deletePage(alloc, ctx.threaded.io(), &ctx.db, "page_does_not_exist");
    try testing.expect(!was_deleted);
}

test "deletePage removes the design_pages row + cascade-deletes elements" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();
    defer alloc.free(ctx.item_path);

    const page_id = try design_model.setDesignPage(alloc, &ctx.db, .{
        .item_id = ITEM_ID,
        .page_name = "Home",
        .width = 1440, .height = 1024,
    });
    defer alloc.free(page_id);

    // Insert an element via setDesignPage's pairing — but we don't
    // need the workspace_item_task_id here. Just need the row.
    const page_dir = try std.fs.path.join(alloc, &.{ ctx.item_path, ".nalar/design/Home" });
    defer alloc.free(page_dir);
    const elem_path = try insertElementWithDiskFile(
        alloc, &ctx.db, ctx.threaded.io(),
        "elem_home_a", page_id, page_dir, "elem-home-a",
    );
    defer alloc.free(elem_path);

    try testing.expect(try pageIdExists(alloc, &ctx.db, page_id));
    try testing.expect(try elementIdExists(alloc, &ctx.db, "elem_home_a"));

    const was_deleted = try design_model.deletePage(alloc, ctx.threaded.io(), &ctx.db, page_id);
    try testing.expect(was_deleted);

    try testing.expect(!try pageIdExists(alloc, &ctx.db, page_id));
    // FK ON DELETE CASCADE removes the element row.
    try testing.expect(!try elementIdExists(alloc, &ctx.db, "elem_home_a"));
}

test "deletePage unlinks each element's HTML file individually (per-file, NOT recursive directory delete)" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();
    defer alloc.free(ctx.item_path);

    const page_id = try design_model.setDesignPage(alloc, &ctx.db, .{
        .item_id = ITEM_ID,
        .page_name = "Login",
        .width = 1440, .height = 1024,
    });
    defer alloc.free(page_id);

    // Sanitized dir = "<item_path>/.nalar/design/Login".
    const page_dir = try std.fs.path.join(alloc, &.{ ctx.item_path, ".nalar/design/Login" });
    defer alloc.free(page_dir);
    const login_btn_path = try insertElementWithDiskFile(
        alloc, &ctx.db, ctx.threaded.io(),
        "elem_login_button", page_id, page_dir, "login-button",
    );
    defer alloc.free(login_btn_path);
    const forgot_link_path = try insertElementWithDiskFile(
        alloc, &ctx.db, ctx.threaded.io(),
        "elem_forgot_link", page_id, page_dir, "forgot-link",
    );
    defer alloc.free(forgot_link_path);

    // A non-DB-tracked file the user dropped into the page directory
    // manually (e.g. a stray `README.md` or `.DS_Store`). Per-file
    // deletion must NOT touch this — only the files tracked in
    // `design_page_elements.file_path` should be removed. This
    // is the regression guard against the pre-fix code that
    // recursively deleted the whole folder.
    const stray_file_path = try std.fs.path.join(alloc, &.{ page_dir, "user-note.txt" });
    defer alloc.free(stray_file_path);
    {
        const f = try std.Io.Dir.cwd().createFile(ctx.threaded.io(), stray_file_path, .{});
        f.close(ctx.threaded.io());
        try std.Io.Dir.cwd().writeFile(ctx.threaded.io(), .{ .sub_path = stray_file_path, .data = "user-added note" });
    }

    // Sanity: all three files exist before delete.
    try testing.expect(fileExists(ctx.threaded.io(), login_btn_path));
    try testing.expect(fileExists(ctx.threaded.io(), forgot_link_path));
    try testing.expect(fileExists(ctx.threaded.io(), stray_file_path));

    const was_deleted = try design_model.deletePage(alloc, ctx.threaded.io(), &ctx.db, page_id);
    try testing.expect(was_deleted);

    // Each DB-tracked file is gone after delete (per-file deletion,
    // mirrors deleteElement's pattern).
    try testing.expect(!fileExists(ctx.threaded.io(), login_btn_path));
    try testing.expect(!fileExists(ctx.threaded.io(), forgot_link_path));

    // The non-DB-tracked file MUST still exist — per-file deletion
    // does NOT recursively walk the folder. This is the regression
    // guard for the 2026-08-06 review (user said: "should delete on
    // file not file inside folder recursivly").
    try testing.expect(fileExists(ctx.threaded.io(), stray_file_path));
}

test "deletePage succeeds (no-op on disk) when page has no elements yet" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();
    defer alloc.free(ctx.item_path);

    const page_id = try design_model.setDesignPage(alloc, &ctx.db, .{
        .item_id = ITEM_ID,
        .page_name = "Empty",
        .width = 1440, .height = 1024,
    });
    defer alloc.free(page_id);

    // No elements, no on-disk directory → deletePage should still
    // succeed and remove the SQL row (the new lookup returns null
    // because there are no file_paths to derive from).
    const was_deleted = try design_model.deletePage(alloc, ctx.threaded.io(), &ctx.db, page_id);
    try testing.expect(was_deleted);
    try testing.expect(!try pageIdExists(alloc, &ctx.db, page_id));
}

test "deletePage cascade-deletes the paired workspace_item_tasks row" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();
    defer alloc.free(ctx.item_path);

    const page_id = try design_model.setDesignPage(alloc, &ctx.db, .{
        .item_id = ITEM_ID,
        .page_name = "Chat",
        .width = 1440, .height = 1024,
    });
    defer alloc.free(page_id);

    // The paired task id is stored on design_pages.workspace_item_task_id.
    // Read it back.
    var q = try ctx.db.query(alloc,
        "SELECT COALESCE(workspace_item_task_id, '') FROM design_pages WHERE id = ?",
        &.{page_id});
    defer q.deinit();
    const row = (try q.next()) orelse return error.NoPageRow;
    defer row.deinit(alloc);
    const task_id = try alloc.dupe(u8, row.values[0]);
    defer alloc.free(task_id);
    try testing.expect(task_id.len > 0);

    const was_deleted = try design_model.deletePage(alloc, ctx.threaded.io(), &ctx.db, page_id);
    try testing.expect(was_deleted);

    // The paired workspace_item_tasks row must be gone.
    var q2 = try ctx.db.query(alloc,
        "SELECT 1 FROM workspace_item_tasks WHERE id = ?",
        &.{task_id});
    defer q2.deinit();
    const task_row = try q2.next();
    try testing.expect(task_row == null);
}

test "deletePage rmdirs the empty page directory (cleans up after per-file unlink)" {
    // Why this test exists
    // ─────────────────────
    // The per-file unlink step (`deleteFileIfExists`) leaves an empty
    // `<page>/` directory behind — which was the root cause of the
    // 2026-08-13 functional-test regression (every DELETE /pages/:pid
    // left a stale empty folder, so `test_delete_page_removes_entire_directory`
    // failed because the dir still existed). This test pins the
    // post-fix contract: `deletePage` MUST rmdir the page folder after
    // unlinking its tracked HTML files, so the directory disappears
    // when nothing user-dropped remains inside.
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();
    defer alloc.free(ctx.item_path);

    const page_id = try design_model.setDesignPage(alloc, &ctx.db, .{
        .item_id = ITEM_ID,
        .page_name = "Clean",
        .width = 1440, .height = 1024,
    });
    defer alloc.free(page_id);

    const page_dir = try std.fs.path.join(alloc, &.{ ctx.item_path, ".nalar/design/Clean" });
    defer alloc.free(page_dir);
    const elem_path = try insertElementWithDiskFile(
        alloc, &ctx.db, ctx.threaded.io(),
        "elem_clean_a", page_id, page_dir, "elem-clean-a",
    );
    defer alloc.free(elem_path);

    // Sanity: page directory exists.
    try testing.expect(dirExists(ctx.threaded.io(), page_dir));

    const was_deleted = try design_model.deletePage(alloc, ctx.threaded.io(), &ctx.db, page_id);
    try testing.expect(was_deleted);

    // After delete: the page directory itself is gone (rmdir succeeded
    // because no user-dropped files remain inside).
    try testing.expect(!dirExists(ctx.threaded.io(), page_dir));
}

test "deletePage preserves a user-dropped file inside the page directory" {
    // The companion to the rmdir-cleanup test: when the user has
    // dropped a file (`.DS_Store`, `README.md`, screenshot, etc.)
    // into the page folder, deletePage MUST keep it. The
    // `deleteDirectoryIfEmpty` step refuses to rmdir non-empty
    // directories — the user file survives, the page DB rows still
    // get deleted.
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();
    defer alloc.free(ctx.item_path);

    const page_id = try design_model.setDesignPage(alloc, &ctx.db, .{
        .item_id = ITEM_ID,
        .page_name = "Mixed",
        .width = 1440, .height = 1024,
    });
    defer alloc.free(page_id);

    const page_dir = try std.fs.path.join(alloc, &.{ ctx.item_path, ".nalar/design/Mixed" });
    defer alloc.free(page_dir);
    const elem_path = try insertElementWithDiskFile(
        alloc, &ctx.db, ctx.threaded.io(),
        "elem_mixed_a", page_id, page_dir, "elem-mixed-a",
    );
    defer alloc.free(elem_path);

    // User drops a README.md into the page folder (not tracked in DB).
    const stray_path = try std.fs.path.join(alloc, &.{ page_dir, "user-note.txt" });
    defer alloc.free(stray_path);
    {
        const f = try std.Io.Dir.cwd().createFile(ctx.threaded.io(), stray_path, .{});
        f.close(ctx.threaded.io());
        try std.Io.Dir.cwd().writeFile(
            ctx.threaded.io(),
            .{ .sub_path = stray_path, .data = "user-added note" },
        );
    }

    const was_deleted = try design_model.deletePage(alloc, ctx.threaded.io(), &ctx.db, page_id);
    try testing.expect(was_deleted);

    // DB-tracked file is gone.
    try testing.expect(!fileExists(ctx.threaded.io(), elem_path));
    // User's file is still there (preserves user-dropped files).
    try testing.expect(fileExists(ctx.threaded.io(), stray_path));
    // Page directory still exists (we couldn't rmdir a non-empty dir).
    try testing.expect(dirExists(ctx.threaded.io(), page_dir));
}
