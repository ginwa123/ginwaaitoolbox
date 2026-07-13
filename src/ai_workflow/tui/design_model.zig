//! Data layer for the design-mode workspace item (item_type='design').
//!
//! Each design workspace item has N pages (e.g. "Home", "Login",
//! "Dashboard"), and each page has 0..N positioned elements (e.g.
//! "login-card", "hero-image") with their HTML bodies stored on disk
//! under `<workspace_item.path>/.nalar/design/<page_name>/<element_name>.html`.
//!
//! Schema:
//! - `design_pages` — created by Migration 055, upgraded by 056
//! - `design_page_elements` — created by Migration 056, v6 props added
//!   by Migration 057.
//!
//! Row ownership: each `db.query()` row's `values[i]` slices are
//! owned by the `Row` and freed by `row.deinit(allocator)`. To keep a
//! value past the loop iteration, the field is duplicated with
//! `allocator.dupe(u8, row.values[i])`. Strings returned by
//! `listPages` are owned by the caller and must be released with
//! `freePages`.
//!
//! Why this rewrite
//! ────────────────
//! The v5 `design_model.zig` was 5-file overengineered and supported
//! the old panzoom-based canvas. The v6 rewrite focuses on the
//! 3-tool LLM surface (`set_design_page`, `add_element`,
//! `update_element`) and the file-backed HTML invariants (atomic
//! writes, orphan cleanup on delete, path-traversal defense). The
//! v6 surface is small enough to fit in one file (~600 LoC).
//!
//! Plan: docs/superpowers/plans/2026-07-08-design-mode-redesign.md (Chunk 1)

const std = @import("std");
const nalarcore = @import("nalarcore");
const sqlite = nalarcore.sqlite;
const helpers = nalarcore.helpers;
const design_io = @import("design_io.zig");

/// Generate a unique page id of the form `page_<unix_nanoseconds>`.
/// Same approach as `kanban_model.generateColumnId` (a process-global
/// monotonic counter XORed with a stack address) — see that file
/// for the rationale (avoids `std.c.clock_gettime` which doesn't
/// compile on Windows).
fn generatePageId(allocator: std.mem.Allocator) ![]u8 {
    const counter = nextPageIdCounter();
    var entropy: [8]u8 = undefined;
    const stack_addr: u64 = @intCast(@intFromPtr(&entropy));
    const mixed: u64 = counter ^ stack_addr;
    std.mem.writeInt(u64, &entropy, mixed, .little);
    var hex: [16]u8 = undefined;
    const hex_chars = "0123456789abcdef";
    for (entropy, 0..) |b, i| {
        hex[i * 2] = hex_chars[b >> 4];
        hex[i * 2 + 1] = hex_chars[b & 0x0F];
    }
    return std.fmt.allocPrint(allocator, "page_{s}", .{&hex});
}

var page_id_counter: std.atomic.Value(u64) = .init(0);

fn nextPageIdCounter() u64 {
    return page_id_counter.fetchAdd(1, .seq_cst);
}

// ─── DesignPage struct + freePages ────────────────────────────────────────

/// One design-page row, fully duplicated into heap memory.
/// Free with `freePages(allocator, slice)`.
pub const DesignPage = struct {
    id: []u8,
    workspace_item_id: []u8,
    name: []u8,
    width: i64,
    height: i64,
    position: i64,
    created_at: []u8,
    updated_at: []u8,
};

/// Free the per-page strings and the backing slice in one call.
pub fn freePages(allocator: std.mem.Allocator, pages: []DesignPage) void {
    for (pages) |p| {
        allocator.free(p.id);
        allocator.free(p.workspace_item_id);
        allocator.free(p.name);
        allocator.free(p.created_at);
        allocator.free(p.updated_at);
    }
    allocator.free(pages);
}

// ─── setDesignPage ────────────────────────────────────────────────────────

pub const SetDesignPageInput = struct {
    item_id: []const u8,
    page_name: []const u8,
    width: i64,
    height: i64,
};

pub const SetDesignPageError = error{
    ItemPathMissing,
    BadPageName,
    DbError,
    OutOfMemory,
};

/// Create or update a page for a design item. Idempotent: if a page
/// with the same (workspace_item_id, name) exists, its width/height
/// are updated; otherwise a new row is inserted.
///
/// Returns the page_id of the existing-or-newly-created page.
/// Caller owns the returned slice.
///
/// Prerequisite: `workspace_items.path` is non-empty (otherwise
/// returns `ItemPathMissing`).
pub fn setDesignPage(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    input: SetDesignPageInput,
) anyerror![]u8 {
    if (input.page_name.len == 0) return error.BadPageName;

    // 1. Look up the design item's `path`. Returns ItemPathMissing
    //    if NULL/empty.
    const path_opt: ?[]u8 = blk: {
        var q = try db.query(allocator,
            "SELECT wi.path FROM workspace_items wi " ++
            "WHERE wi.id = ? AND wi.item_type = 'design'",
            &.{input.item_id});
        defer q.deinit();
        if (try q.next()) |row| {
            defer row.deinit(allocator);
            if (row.values[0].len == 0) break :blk null;
            break :blk try allocator.dupe(u8, row.values[0]);
        }
        break :blk null;
    };
    defer if (path_opt) |p| allocator.free(p);
    if (path_opt == null) return error.ItemPathMissing;

    // 2. Check whether a row with the same (item_id, name) already
    //    exists. If yes, just update its width/height/updated_at
    //    and return the existing id. This is true idempotency —
    //    every call returns the same id for the same (item, name).
    if (try findPageIdByName(allocator, db, input.item_id, input.page_name)) |existing_id| {
        // Existing row → update width/height/updated_at and return.
        defer allocator.free(existing_id);

        // SQLite's argv takes `[]const []const u8`, so stringify the
        // integer columns. `db.exec` binds empty slices as SQL NULL
        // (see project memory `sqlite-backend-empty-slice-binds-as-null`),
        // so the strings must be non-empty even for the "zero" case.
        const width_str = try std.fmt.allocPrint(allocator, "{d}", .{input.width});
        defer allocator.free(width_str);
        const height_str = try std.fmt.allocPrint(allocator, "{d}", .{input.height});
        defer allocator.free(height_str);

        try db.exec(allocator,
            "UPDATE design_pages SET width = ?, height = ?, " ++
            "updated_at = datetime('now') WHERE id = ?",
            &.{ width_str, height_str, existing_id });
        return allocator.dupe(u8, existing_id);
    }

    // 3. New row → generate a fresh id and INSERT.
    const id = try generatePageId(allocator);
    defer allocator.free(id);

    // SQLite's argv takes `[]const []const u8`, so we have to
    // stringify the integer columns. `db.exec` binds empty slices
    // as SQL NULL (see project memory
    // `sqlite-backend-empty-slice-binds-as-null`), so the strings
    // we build here must be non-empty even for the "zero" case.
    const width_str = try std.fmt.allocPrint(allocator, "{d}", .{input.width});
    defer allocator.free(width_str);
    const height_str = try std.fmt.allocPrint(allocator, "{d}", .{input.height});
    defer allocator.free(height_str);

    try db.exec(allocator,
        \\INSERT INTO design_pages (
        \\    id, workspace_item_id, name, width, height, position,
        \\    created_at, updated_at
        \\) VALUES (
        \\    ?, ?, ?, ?, ?,
        \\    COALESCE((SELECT MAX(dp.position) FROM design_pages dp
        \\        WHERE dp.workspace_item_id = ?), -1) + 1,
        \\    datetime('now'), datetime('now')
        \\)
    , &.{ id, input.item_id, input.page_name, width_str, height_str, input.item_id });

    return allocator.dupe(u8, id);
}

/// Look up the page id for the given (item_id, page_name). Returns
/// the owned id slice on hit, or `null` when no such page exists.
fn findPageIdByName(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    item_id: []const u8,
    page_name: []const u8,
) !?[]u8 {
    var q = try db.query(allocator,
        "SELECT dp.id FROM design_pages dp " ++
        "WHERE dp.workspace_item_id = ? AND dp.name = ?",
        &.{ item_id, page_name });
    defer q.deinit();
    if (try q.next()) |row| {
        defer row.deinit(allocator);
        return try allocator.dupe(u8, row.values[0]);
    }
    return null;
}

// ─── listPages ────────────────────────────────────────────────────────────

/// List the pages of a design workspace item in `position` order.
///
/// Returns an owned slice; caller MUST release with
/// `freePages(allocator, slice)`. If the item has no pages, the slice
/// has length 0 (not an error).
pub fn listPages(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    item_id: []const u8,
) (sqlite.Error || std.mem.Allocator.Error)![]DesignPage {
    var q = try db.query(allocator,
        \\SELECT dp.id, dp.workspace_item_id, dp.name, dp.width, dp.height,
        \\       dp.position, COALESCE(dp.created_at, ''), COALESCE(dp.updated_at, '')
        \\FROM design_pages dp
        \\WHERE dp.workspace_item_id = ?
        \\ORDER BY dp.position ASC
    , &.{item_id});
    defer q.deinit();

    var rows = std.ArrayList(DesignPage).empty;
    errdefer {
        for (rows.items) |p| {
            allocator.free(p.id);
            allocator.free(p.workspace_item_id);
            allocator.free(p.name);
            allocator.free(p.created_at);
            allocator.free(p.updated_at);
        }
        rows.deinit(allocator);
    }
    while (try q.next()) |row| {
        defer row.deinit(allocator);
        try rows.append(allocator, .{
            .id = try allocator.dupe(u8, row.values[0]),
            .workspace_item_id = try allocator.dupe(u8, row.values[1]),
            .name = try allocator.dupe(u8, row.values[2]),
            .width = std.fmt.parseInt(i64, row.values[3], 10) catch 0,
            .height = std.fmt.parseInt(i64, row.values[4], 10) catch 0,
            .position = std.fmt.parseInt(i64, row.values[5], 10) catch 0,
            .created_at = try allocator.dupe(u8, row.values[6]),
            .updated_at = try allocator.dupe(u8, row.values[7]),
        });
    }
    return rows.toOwnedSlice(allocator);
}
