//! Data layer for the Design Mode workspace item (item_type='design').
//!
//! Each design workspace item hosts N named HTML pages (e.g. "Login",
//! "Dashboard", "Settings") that the LLM tool `set_design_page` populates
//! via an idempotent INSERT ... ON CONFLICT(workspace_item_id, name) DO
//! UPDATE — re-issuing with the same name replaces the row's html in
//! place. The frontend renders one page at a time as a sandboxed iframe,
//! lazy-loading the body via `getPage` on tab activation.
//!
//! Schema: see Migration 055 (`Migration055AddDesignPages` in
//! `src/ai_workflow/tui/migration.zig`).
//!
//! SQL convention: every SELECT aliases its tables (`dp` for
//! `design_pages`) and qualifies every column reference with the alias.
//! See the project memory `nalar-sql-alias-tables.md`.
//!
//! Row ownership: each `db.query()` row's `values[i]` slices are owned
//! by the `Row` and freed by `row.deinit(allocator)`. To keep a value
//! past the loop iteration, the field is duplicated with
//! `allocator.dupe(u8, row.values[i])`. Strings returned by `listPages`
//! are owned by the caller and must be released with `freePageSummaries`;
//! `DesignPageFull` instances are released with `freePageFull`.
//!
//! Plan: docs/superpowers/plans/2026-07-05-design-mode.md (Chunk 1)

const std = @import("std");
const nalarcore = @import("nalarcore");
const sqlite = nalarcore.sqlite;
const helpers = nalarcore.helpers;

/// One page row from `listPages` — excludes `html` by design. The
/// frontend renders a tab strip from this (name + position) and only
/// fetches the html body via `getPage` when the tab is activated.
///
/// `html` is always `null` in the listPages return; it's declared as
/// `?[]u8` so a future caller that wants the body inline (e.g. an
/// export-to-json use case) can populate it without changing the
/// struct shape.
pub const DesignPageSummary = struct {
    id: []u8,
    workspace_item_id: []u8,
    name: []u8,
    /// `null` — listPages excludes html by design (lazy load).
    html: ?[]u8 = null,
    position: i64,
    created_at: []u8,
    updated_at: []u8,
};

/// One page row from `getPage` — includes the full html body.
///
/// `html` is a non-optional `[]u8` (the column is `NOT NULL DEFAULT ''`).
pub const DesignPageFull = struct {
    id: []u8,
    workspace_item_id: []u8,
    name: []u8,
    html: []u8,
    position: i64,
    created_at: []u8,
    updated_at: []u8,
};

/// Free the per-page strings and the backing slice in one call.
pub fn freePageSummaries(allocator: std.mem.Allocator, pages: []DesignPageSummary) void {
    for (pages) |p| {
        allocator.free(p.id);
        allocator.free(p.workspace_item_id);
        allocator.free(p.name);
        if (p.html) |h| allocator.free(h);
        allocator.free(p.created_at);
        allocator.free(p.updated_at);
    }
    allocator.free(pages);
}

/// Free the per-field strings of a `DesignPageFull`. Does NOT free the
/// `DesignPageFull` value itself (it's passed by value, so the storage
/// is on the caller's stack).
pub fn freePageFull(allocator: std.mem.Allocator, page: DesignPageFull) void {
    allocator.free(page.id);
    allocator.free(page.workspace_item_id);
    allocator.free(page.name);
    allocator.free(page.html);
    allocator.free(page.created_at);
    allocator.free(page.updated_at);
}

/// List the pages of a design workspace item, ordered by `position` ASC.
///
/// Returns an owned slice; the caller must release it with
/// `freePageSummaries(allocator, slice)`. If the item has no pages, the
/// slice has length 0 (not an error). The `html` field of every summary
/// is `null` — use `getPage` to fetch a single page's body.
///
/// SQL convention: aliases `design_pages` as `dp` and qualifies every
/// column reference with the alias per `nalar-sql-alias-tables.md`.
pub fn listPages(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    workspace_item_id: []const u8,
) ![]DesignPageSummary {
    var q = try db.query(allocator,
        \\SELECT dp.id, dp.workspace_item_id, dp.name, dp.position, dp.created_at, dp.updated_at
        \\FROM design_pages dp
        \\WHERE dp.workspace_item_id = ?
        \\ORDER BY dp.position ASC
    , &.{workspace_item_id});
    defer q.deinit();

    var rows = std.ArrayList(DesignPageSummary).empty;
    errdefer {
        for (rows.items) |r| {
            allocator.free(r.id);
            allocator.free(r.workspace_item_id);
            allocator.free(r.name);
            if (r.html) |h| allocator.free(h);
            allocator.free(r.created_at);
            allocator.free(r.updated_at);
        }
        rows.deinit(allocator);
    }
    while (try q.next()) |row| {
        defer row.deinit(allocator);
        try rows.append(allocator, .{
            .id = try allocator.dupe(u8, row.values[0]),
            .workspace_item_id = try allocator.dupe(u8, row.values[1]),
            .name = try allocator.dupe(u8, row.values[2]),
            .position = try std.fmt.parseInt(i64, row.values[3], 10),
            .created_at = try allocator.dupe(u8, row.values[4]),
            .updated_at = try allocator.dupe(u8, row.values[5]),
        });
    }
    return rows.toOwnedSlice(allocator);
}

/// Fetch a single page by id, including the full html body.
///
/// Returns `error.PageNotFound` if no row matches. The returned
/// `DesignPageFull` is owned by the caller — release with `freePageFull`.
pub fn getPage(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    page_id: []const u8,
) !DesignPageFull {
    var q = try db.query(allocator,
        \\SELECT dp.id, dp.workspace_item_id, dp.name, dp.html, dp.position, dp.created_at, dp.updated_at
        \\FROM design_pages dp WHERE dp.id = ?
    , &.{page_id});
    defer q.deinit();
    const row = (try q.next()) orelse return error.PageNotFound;
    defer row.deinit(allocator);
    return DesignPageFull{
        .id = try allocator.dupe(u8, row.values[0]),
        .workspace_item_id = try allocator.dupe(u8, row.values[1]),
        .name = try allocator.dupe(u8, row.values[2]),
        .html = try allocator.dupe(u8, row.values[3]),
        .position = try std.fmt.parseInt(i64, row.values[4], 10),
        .created_at = try allocator.dupe(u8, row.values[5]),
        .updated_at = try allocator.dupe(u8, row.values[6]),
    };
}

/// Append-or-replace a page to a design item.
///
/// **Idempotent on `(workspace_item_id, name)`**: re-issuing with the
/// same name updates the existing row's `html` and `updated_at` in
/// place (does NOT create a duplicate). The row's `id` is preserved
/// across re-issues, so the caller can use the returned id as a stable
/// handle for the page's lifetime.
///
/// New pages get `position = COALESCE(MAX(position), -1) + 1` so the
/// first page in an empty item is at position 0 and subsequent pages
/// append at the end. Replacement (existing-name) calls do NOT change
/// the position (the ON CONFLICT only updates html + updated_at).
///
/// Returns a freshly-allocated id of the form `page_<unix_nanoseconds>`.
/// Caller owns the returned slice.
pub fn addPage(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    workspace_item_id: []const u8,
    name: []const u8,
    html: []const u8,
) ![]u8 {
    const id = try std.fmt.allocPrint(allocator, "page_{d}", .{helpers.unixTimestampNanos()});
    errdefer allocator.free(id);

    // Idempotent on (workspace_item_id, name) — re-calling with the
    // same name replaces the existing row's html in place. The
    // UNIQUE index `idx_design_pages_item_name` is what makes
    // ON CONFLICT(workspace_item_id, name) valid (Migration 055).
    //
    // SqliteBackend.exec binds `arg.len == 0` as SQL NULL (see
    // `src/modules/databases/sqlite/Sqlite.zig:73-74`). The
    // `html` column is `NOT NULL DEFAULT ''`, so binding an empty
    // slice as NULL would violate the constraint. Mirrors the
    // split-INSERT pattern in `kanban_model.addColumn`: when html
    // is empty, bind the empty literal directly in SQL (and omit
    // the column from the new-row INSERT so the DEFAULT '' applies).
    if (html.len == 0) {
        try db.exec(allocator,
            \\INSERT INTO design_pages (id, workspace_item_id, name, position)
            \\VALUES (?, ?, ?, COALESCE((SELECT MAX(position) FROM design_pages WHERE workspace_item_id = ?), -1) + 1)
            \\ON CONFLICT(workspace_item_id, name) DO UPDATE SET html = '', updated_at = datetime('now')
        , &.{ id, workspace_item_id, name, workspace_item_id });
    } else {
        try db.exec(allocator,
            \\INSERT INTO design_pages (id, workspace_item_id, name, html, position)
            \\VALUES (?, ?, ?, ?, COALESCE((SELECT MAX(position) FROM design_pages WHERE workspace_item_id = ?), -1) + 1)
            \\ON CONFLICT(workspace_item_id, name) DO UPDATE SET html = excluded.html, updated_at = datetime('now')
        , &.{ id, workspace_item_id, name, html, workspace_item_id });
    }
    return id;
}

/// Delete a page by id. Idempotent: returns `true` if a row was
/// deleted, `false` if no such id exists (no error). Callers use the
/// bool to decide whether to emit an SSE event — `false` is the
/// "delete was a no-op" case (e.g. a duplicate DELETE request).
pub fn deletePage(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    page_id: []const u8,
) !bool {
    var q = try db.query(allocator,
        "SELECT id FROM design_pages WHERE id = ?", &.{page_id});
    defer q.deinit();
    const row = try q.next();
    if (row == null) return false;
    if (row) |r| r.deinit(allocator);
    try db.exec(allocator, "DELETE FROM design_pages WHERE id = ?", &.{page_id});
    return true;
}

/// Replace a page's html body. Idempotent: returns `true` on a
/// successful UPDATE, `false` if no such id exists. Touches
/// `updated_at = datetime('now')` so the frontend can re-sort tabs
/// by recency if desired.
pub fn updatePageHtml(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    page_id: []const u8,
    html: []const u8,
) !bool {
    var q = try db.query(allocator,
        "SELECT id FROM design_pages WHERE id = ?", &.{page_id});
    defer q.deinit();
    const row = try q.next();
    if (row == null) return false;
    if (row) |r| r.deinit(allocator);
    try db.exec(allocator,
        "UPDATE design_pages SET html = ?, updated_at = datetime('now') WHERE id = ?",
        &.{ html, page_id });
    return true;
}