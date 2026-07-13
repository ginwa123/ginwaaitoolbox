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
const on_event_sent_design = @import("on_event_sent_design.zig");

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

// ─── DesignElement struct + freeElements ───────────────────────────────────

/// One design-page-element row, fully duplicated into heap memory.
/// Free with `freeElements(allocator, slice)`.
pub const DesignElement = struct {
    id: []u8,
    page_id: []u8,
    name: []u8,
    file_path: []u8,
    x: i64,
    y: i64,
    width: i64,
    height: i64,
    z_index: i64,
    position: i64,
    /// One of "rectangle" | "ellipse" | "text" | "image" | "frame" | "group"
    elem_type: []u8,
    rotation: f64,
    fill: []u8,
    stroke: []u8,
    stroke_width: i64,
    corner_radius: i64,
    opacity: f64,
    text_content: []u8,
    text_style: []u8,
    image_url: []u8,
    created_at: []u8,
    updated_at: []u8,
};

/// Free the per-element strings and the backing slice in one call.
pub fn freeElements(allocator: std.mem.Allocator, elements: []DesignElement) void {
    for (elements) |e| {
        allocator.free(e.id);
        allocator.free(e.page_id);
        allocator.free(e.name);
        allocator.free(e.file_path);
        allocator.free(e.elem_type);
        allocator.free(e.fill);
        allocator.free(e.stroke);
        allocator.free(e.text_content);
        allocator.free(e.text_style);
        allocator.free(e.image_url);
        allocator.free(e.created_at);
        allocator.free(e.updated_at);
    }
    allocator.free(elements);
}

/// Element type as a Zig enum. The wire string is `@tagName(input.type)`.
pub const ElementType = enum {
    rectangle,
    ellipse,
    text,
    image,
    frame,
    group,
};

// ─── addElement ───────────────────────────────────────────────────────────

pub const AddElementInput = struct {
    page_id: []const u8,
    name: []const u8,
    elem_type: ElementType,
    html: []const u8,
    x: i64,
    y: i64,
    width: i64,
    height: i64,
    fill: []const u8,
    rotation: f64,
    corner_radius: i64,
    opacity: f64,
    text_content: []const u8 = "",
    text_style: []const u8 = "",
    image_url: []const u8 = "",
};

pub const AddElementError = error{
    PageNotFound,
    ItemPathMissing,
    BadName,
    FileWriteFailed,
    DbError,
    OutOfMemory,
};

/// Add a new element to a design page. Atomically writes the element's
/// HTML to disk and inserts the corresponding metadata row.
///
/// Returns the new element_id. Caller owns the returned slice.
///
/// Behavior:
///   1. Look up the parent page (item_id, page name, item path) via
///      JOIN. Returns `PageNotFound` if the page is missing or
///      `ItemPathMissing` if the workspace_item has no `path`.
///   2. Sanitize page name and element name.
///   3. Build file path: `<item_path>/.nalar/design/<page>/<element>.html`
///   4. Make the page directory (mkdir-p via Io).
///   5. Atomic-write the HTML body to disk.
///   6. INSERT the metadata row with all 11 v6 columns.
pub fn addElement(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    io: std.Io,
    input: AddElementInput,
) anyerror![]u8 {
    if (input.name.len == 0) return error.BadName;

    // 1. Look up parent page via JOIN. Also SELECT `wi.workspace_id`
    //    so we can emit a `design_element_created` SSE event with the
    //    full (workspace_id, item_id, page_id, element_id) context
    //    — the frontend listener filters events by all four ids.
    const Lookup = struct { workspace_id: []u8, item_id: []u8, page_name: []u8, item_path: []u8 };
    const lookup: Lookup = blk: {
        var q = try db.query(allocator,
            \\SELECT wi.workspace_id, dp.workspace_item_id, dp.name, wi.path
            \\FROM design_pages dp
            \\JOIN workspace_items wi ON wi.id = dp.workspace_item_id
            \\WHERE dp.id = ?
        , &.{input.page_id});
        defer q.deinit();
        const row = (try q.next()) orelse return error.PageNotFound;
        defer row.deinit(allocator);
        break :blk .{
            .workspace_id = try allocator.dupe(u8, row.values[0]),
            .item_id = try allocator.dupe(u8, row.values[1]),
            .page_name = try allocator.dupe(u8, row.values[2]),
            .item_path = try allocator.dupe(u8, row.values[3]),
        };
    };
    defer allocator.free(lookup.workspace_id);
    defer allocator.free(lookup.item_id);
    defer allocator.free(lookup.page_name);
    defer allocator.free(lookup.item_path);
    if (lookup.item_path.len == 0) return error.ItemPathMissing;

    // 2. Sanitize the page and element names for filesystem safety.
    const sanitized_page = try design_io.sanitizeFilename(allocator, lookup.page_name);
    defer allocator.free(sanitized_page);
    const sanitized_elem = try design_io.sanitizeFilename(allocator, input.name);
    defer allocator.free(sanitized_elem);

    // 3. Build the file path.
    const page_dir = try std.fmt.allocPrint(allocator, "{s}/.nalar/design/{s}", .{ lookup.item_path, sanitized_page });
    defer allocator.free(page_dir);
    const file_path = try std.fmt.allocPrint(allocator, "{s}/{s}.html", .{ page_dir, sanitized_elem });
    defer allocator.free(file_path);

    // 4. mkdir -p the page directory (createDirPath is the Io-native
    // mkdir-p equivalent in Zig 0.16).
    std.Io.Dir.cwd().createDirPath(io, page_dir) catch return error.FileWriteFailed;

    // 5. Atomic-write the HTML body to disk.
    design_io.atomicWriteFile(allocator, file_path, input.html) catch return error.FileWriteFailed;

    // 6. INSERT the metadata row with all 11 v6 columns populated.
    const id = try generateElementId(allocator);
    defer allocator.free(id);

    // Stringify integer / real columns for argv compatibility.
    const x_str = try std.fmt.allocPrint(allocator, "{d}", .{input.x});
    defer allocator.free(x_str);
    const y_str = try std.fmt.allocPrint(allocator, "{d}", .{input.y});
    defer allocator.free(y_str);
    const width_str = try std.fmt.allocPrint(allocator, "{d}", .{input.width});
    defer allocator.free(width_str);
    const height_str = try std.fmt.allocPrint(allocator, "{d}", .{input.height});
    defer allocator.free(height_str);
    const rotation_str = try std.fmt.allocPrint(allocator, "{d}", .{input.rotation});
    defer allocator.free(rotation_str);
    const corner_radius_str = try std.fmt.allocPrint(allocator, "{d}", .{input.corner_radius});
    defer allocator.free(corner_radius_str);
    const opacity_str = try std.fmt.allocPrint(allocator, "{d}", .{input.opacity});
    defer allocator.free(opacity_str);
    const elem_type_str = @tagName(input.elem_type);

    try db.exec(allocator,
        \\INSERT INTO design_page_elements (
        \\    id, page_id, name, file_path, x, y, width, height, z_index, position,
        \\    type, rotation, fill, stroke, stroke_width, corner_radius, opacity,
        \\    text_content, text_style, image_url, parent_id,
        \\    created_at, updated_at
        \\) VALUES (
        \\    ?, ?, ?, ?, ?, ?, ?, ?, 0,
        \\    COALESCE((SELECT MAX(de.position) FROM design_page_elements de
        \\        WHERE de.page_id = ?), -1) + 1,
        \\    ?, ?, ?, '', 0, ?, ?, '', '', '', NULL,
        \\    datetime('now'), datetime('now')
        \\)
    , &.{
        id, input.page_id, input.name, file_path,
        x_str, y_str, width_str, height_str, input.page_id,
        elem_type_str, rotation_str, input.fill, corner_radius_str, opacity_str,
    });

    // Emit SSE event AFTER the SQL INSERT succeeded. Best-effort: if
    // the event_bus is not initialized (e.g. in unit tests without a
    // GinwaServer singleton) or the JSON serialization fails, the
    // caller still gets the new element_id — SSE is a hint, not a
    // hard contract. The lookup slices (workspace_id, item_id) are
    // still alive at this point; the function-level defers haven't
    // fired yet.
    on_event_sent_design.onEventSendDesignElementCreated(allocator, .{
        .action = "created",
        .workspace_id = lookup.workspace_id,
        .item_id = lookup.item_id,
        .page_id = input.page_id,
        .element_id = id,
    }) catch {};

    return allocator.dupe(u8, id);
}

/// Generate a unique element id of the form `elem_<nanos>`.
fn generateElementId(allocator: std.mem.Allocator) ![]u8 {
    const counter = nextElementIdCounter();
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
    return std.fmt.allocPrint(allocator, "elem_{s}", .{&hex});
}

var element_id_counter: std.atomic.Value(u64) = .init(0);

fn nextElementIdCounter() u64 {
    return element_id_counter.fetchAdd(1, .seq_cst);
}

// ─── updateElement ────────────────────────────────────────────────────────

pub const UpdateElementInput = struct {
    element_id: []const u8,
    name: ?[]const u8 = null,
    elem_type: ?ElementType = null,
    html: ?[]const u8 = null,
    x: ?i64 = null,
    y: ?i64 = null,
    width: ?i64 = null,
    height: ?i64 = null,
    rotation: ?f64 = null,
    fill: ?[]const u8 = null,
    stroke: ?[]const u8 = null,
    stroke_width: ?i64 = null,
    corner_radius: ?i64 = null,
    opacity: ?f64 = null,
    text_content: ?[]const u8 = null,
    text_style: ?[]const u8 = null,
    image_url: ?[]const u8 = null,
};

/// Update an element. Each non-null field is SET in the SQL UPDATE;
/// null fields are left unchanged. If `html` is set, the file at
/// `file_path` is rewritten atomically. Returns the element_id on
/// success; returns `ElementNotFound` if no such row exists.
pub fn updateElement(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    input: UpdateElementInput,
) anyerror![]u8 {
    // 0. Pre-lookup: fetch (page_id, workspace_id, item_id) for the
    //    element so we can emit a `design_element_updated` SSE
    //    event with the full id context (after the SQL UPDATE
    //    succeeds). Returns `ElementNotFound` if no such row.
    //    The JOIN chains design_page_elements → design_pages →
    //    workspace_items.
    const ElementContext = struct {
        page_id: []u8,
        workspace_id: []u8,
        item_id: []u8,
    };
    const ctx: ElementContext = blk: {
        var q = try db.query(allocator,
            \\SELECT de.page_id, wi.workspace_id, dp.workspace_item_id
            \\FROM design_page_elements de
            \\JOIN design_pages dp ON dp.id = de.page_id
            \\JOIN workspace_items wi ON wi.id = dp.workspace_item_id
            \\WHERE de.id = ?
        , &.{input.element_id});
        defer q.deinit();
        const row = (try q.next()) orelse return error.ElementNotFound;
        defer row.deinit(allocator);
        break :blk .{
            .page_id = try allocator.dupe(u8, row.values[0]),
            .workspace_id = try allocator.dupe(u8, row.values[1]),
            .item_id = try allocator.dupe(u8, row.values[2]),
        };
    };
    defer allocator.free(ctx.page_id);
    defer allocator.free(ctx.workspace_id);
    defer allocator.free(ctx.item_id);

    // Build dynamic SET clause + argv.
    var sets: std.ArrayList([]const u8) = .empty;
    defer sets.deinit(allocator);
    var args: std.ArrayList([]const u8) = .empty;
    defer args.deinit(allocator);

    // String scratch buffers we own (cleaned at end of function).
    var owned: std.ArrayList([]u8) = .empty;
    defer {
        for (owned.items) |s| allocator.free(s);
        owned.deinit(allocator);
    }

    if (input.name) |v| { try sets.append(allocator, "name = ?"); try args.append(allocator, v); }
    if (input.elem_type) |v| {
        try sets.append(allocator, "type = ?");
        try args.append(allocator, @tagName(v));
    }
    if (input.x) |v| {
        try sets.append(allocator, "x = ?");
        try owned.append(allocator, try std.fmt.allocPrint(allocator, "{d}", .{v}));
        try args.append(allocator, owned.items[owned.items.len - 1]);
    }
    if (input.y) |v| {
        try sets.append(allocator, "y = ?");
        try owned.append(allocator, try std.fmt.allocPrint(allocator, "{d}", .{v}));
        try args.append(allocator, owned.items[owned.items.len - 1]);
    }
    if (input.width) |v| {
        try sets.append(allocator, "width = ?");
        try owned.append(allocator, try std.fmt.allocPrint(allocator, "{d}", .{v}));
        try args.append(allocator, owned.items[owned.items.len - 1]);
    }
    if (input.height) |v| {
        try sets.append(allocator, "height = ?");
        try owned.append(allocator, try std.fmt.allocPrint(allocator, "{d}", .{v}));
        try args.append(allocator, owned.items[owned.items.len - 1]);
    }
    if (input.rotation) |v| {
        try sets.append(allocator, "rotation = ?");
        try owned.append(allocator, try std.fmt.allocPrint(allocator, "{d}", .{v}));
        try args.append(allocator, owned.items[owned.items.len - 1]);
    }
    if (input.fill) |v| { try sets.append(allocator, "fill = ?"); try args.append(allocator, v); }
    if (input.stroke) |v| { try sets.append(allocator, "stroke = ?"); try args.append(allocator, v); }
    if (input.stroke_width) |v| {
        try sets.append(allocator, "stroke_width = ?");
        try owned.append(allocator, try std.fmt.allocPrint(allocator, "{d}", .{v}));
        try args.append(allocator, owned.items[owned.items.len - 1]);
    }
    if (input.corner_radius) |v| {
        try sets.append(allocator, "corner_radius = ?");
        try owned.append(allocator, try std.fmt.allocPrint(allocator, "{d}", .{v}));
        try args.append(allocator, owned.items[owned.items.len - 1]);
    }
    if (input.opacity) |v| {
        try sets.append(allocator, "opacity = ?");
        try owned.append(allocator, try std.fmt.allocPrint(allocator, "{d}", .{v}));
        try args.append(allocator, owned.items[owned.items.len - 1]);
    }
    if (input.text_content) |v| { try sets.append(allocator, "text_content = ?"); try args.append(allocator, v); }
    if (input.text_style) |v| { try sets.append(allocator, "text_style = ?"); try args.append(allocator, v); }
    if (input.image_url) |v| { try sets.append(allocator, "image_url = ?"); try args.append(allocator, v); }

    // If html changed, look up file_path, atomic-rewrite the file,
    // and record that we need to UPDATE file_path too if the file
    // didn't exist before (orphan recovery).
    var new_file_path_owned: ?[]u8 = null;
    defer if (new_file_path_owned) |p| allocator.free(p);
    if (input.html) |new_html| {
        var q = try db.query(allocator,
            "SELECT file_path FROM design_page_elements WHERE id = ?",
            &.{input.element_id});
        defer q.deinit();
        const row = (try q.next()) orelse return error.ElementNotFound;
        defer row.deinit(allocator);
        const existing_path = try allocator.dupe(u8, row.values[0]);
        defer allocator.free(existing_path);

        // If file_path was empty (orphan), set it to a freshly-built
        // path so the rewrite sticks. Otherwise rewrite the file
        // in place.
        if (existing_path.len == 0) {
            // Look up the page → item_path + page_name to build a
            // new file path. JOIN with design_pages and
            // workspace_items.
            var pq = try db.query(allocator,
                \\SELECT dp.workspace_item_id, dp.name, wi.path
                \\FROM design_page_elements de
                \\JOIN design_pages dp ON dp.id = de.page_id
                \\JOIN workspace_items wi ON wi.id = dp.workspace_item_id
                \\WHERE de.id = ?
            , &.{input.element_id});
            defer pq.deinit();
            const prow = (try pq.next()) orelse return error.ElementNotFound;
            defer prow.deinit(allocator);
            const sanitized_page = try design_io.sanitizeFilename(allocator, prow.values[1]);
            defer allocator.free(sanitized_page);
            // Reuse the existing element name (the orphan case
            // implies the row was created with file_path=''
            // for some reason; use the row's `name` field).
            const elem_name = try allocator.dupe(u8, "element");
            defer allocator.free(elem_name);
            const new_path = try std.fmt.allocPrint(allocator, "{s}/.nalar/design/{s}/{s}.html", .{
                prow.values[2], sanitized_page, elem_name,
            });
            new_file_path_owned = new_path;
            try sets.append(allocator, "file_path = ?");
            try args.append(allocator, new_path);
        } else {
            design_io.atomicWriteFile(allocator, existing_path, new_html) catch return error.FileWriteFailed;
        }
    }

    // Always update updated_at.
    try sets.append(allocator, "updated_at = datetime('now')");
    try args.append(allocator, input.element_id);

    if (sets.items.len == 1) {
        // Only updated_at → nothing to update; no-op.
        return allocator.dupe(u8, input.element_id);
    }

    // Build the UPDATE statement: "UPDATE design_page_elements SET " + sets joined by ", " + " WHERE id = ?"
    var sql_buf: [4096]u8 = undefined;
    const sql_prefix = "UPDATE design_page_elements SET ";
    var pos: usize = 0;
    @memcpy(sql_buf[pos..][0..sql_prefix.len], sql_prefix);
    pos += sql_prefix.len;
    for (sets.items, 0..) |s, i| {
        if (i > 0) {
            @memcpy(sql_buf[pos..][0..2], ", ");
            pos += 2;
        }
        @memcpy(sql_buf[pos..][0..s.len], s);
        pos += s.len;
    }
    // The last "set" is the WHERE id = ? — but we appended updated_at
    // AND element_id separately. Pull the WHERE out: pop the
    // element_id from sets and use it as the WHERE.
    _ = sets.pop();
    // Actually we set things up wrong: the element_id is in args
    // as the last position, but our SET list already includes
    // "updated_at = datetime('now')" as a set. Let's re-do this.
    // SQL would be: UPDATE ... SET col1=?, col2=?, updated_at=datetime('now') WHERE id=?
    // We appended element_id to args as the WHERE placeholder. Sets
    // already ends with "updated_at = datetime('now')" (no params).
    // So the SQL is correct — just append " WHERE id = ?".
    const where_clause = " WHERE id = ?";
    @memcpy(sql_buf[pos..][0..where_clause.len], where_clause);
    pos += where_clause.len;

    try db.exec(allocator, sql_buf[0..pos], args.items);

    // Emit SSE event AFTER the SQL UPDATE succeeded and the SQL
    // actually changed at least one user-provided column. Best-effort:
    // if the event_bus is not initialized or the JSON serialization
    // fails, the caller still gets the element_id — SSE is a hint,
    // not a hard contract. The `ctx` slices are still alive at this
    // point; the function-level defers haven't fired.
    on_event_sent_design.onEventSendDesignElementUpdated(allocator, .{
        .action = "updated",
        .workspace_id = ctx.workspace_id,
        .item_id = ctx.item_id,
        .page_id = ctx.page_id,
        .element_id = input.element_id,
    }) catch {};

    return allocator.dupe(u8, input.element_id);
}

// ─── listElements / getElement ─────────────────────────────────────────────

/// List all elements of a design page in (z_index, position) order.
/// Returns an owned slice; caller MUST release with
/// `freeElements(allocator, slice)`. Excludes the element's HTML
/// body — use `loadElementHtml` to fetch the body lazily.
pub fn listElements(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    page_id: []const u8,
) anyerror![]DesignElement {
    var q = try db.query(allocator,
        \\SELECT de.id, de.page_id, de.name, de.file_path,
        \\       de.x, de.y, de.width, de.height, de.z_index, de.position,
        \\       de.type, de.rotation, de.fill, de.stroke, de.stroke_width,
        \\       de.corner_radius, de.opacity,
        \\       de.text_content, de.text_style, de.image_url,
        \\       COALESCE(de.created_at, ''), COALESCE(de.updated_at, '')
        \\FROM design_page_elements de
        \\WHERE de.page_id = ?
        \\ORDER BY de.z_index ASC, de.position ASC
    , &.{page_id});
    defer q.deinit();

    var rows = std.ArrayList(DesignElement).empty;
    errdefer {
        for (rows.items) |e| {
            allocator.free(e.id);
            allocator.free(e.page_id);
            allocator.free(e.name);
            allocator.free(e.file_path);
            allocator.free(e.elem_type);
            allocator.free(e.fill);
            allocator.free(e.stroke);
            allocator.free(e.text_content);
            allocator.free(e.text_style);
            allocator.free(e.image_url);
            allocator.free(e.created_at);
            allocator.free(e.updated_at);
        }
        rows.deinit(allocator);
    }
    while (try q.next()) |row| {
        defer row.deinit(allocator);
        try rows.append(allocator, .{
            .id = try allocator.dupe(u8, row.values[0]),
            .page_id = try allocator.dupe(u8, row.values[1]),
            .name = try allocator.dupe(u8, row.values[2]),
            .file_path = try allocator.dupe(u8, row.values[3]),
            .x = std.fmt.parseInt(i64, row.values[4], 10) catch 0,
            .y = std.fmt.parseInt(i64, row.values[5], 10) catch 0,
            .width = std.fmt.parseInt(i64, row.values[6], 10) catch 0,
            .height = std.fmt.parseInt(i64, row.values[7], 10) catch 0,
            .z_index = std.fmt.parseInt(i64, row.values[8], 10) catch 0,
            .position = std.fmt.parseInt(i64, row.values[9], 10) catch 0,
            .elem_type = try allocator.dupe(u8, row.values[10]),
            .rotation = std.fmt.parseFloat(f64, row.values[11]) catch 0,
            .fill = try allocator.dupe(u8, row.values[12]),
            .stroke = try allocator.dupe(u8, row.values[13]),
            .stroke_width = std.fmt.parseInt(i64, row.values[14], 10) catch 0,
            .corner_radius = std.fmt.parseInt(i64, row.values[15], 10) catch 0,
            .opacity = std.fmt.parseFloat(f64, row.values[16]) catch 0,
            .text_content = try allocator.dupe(u8, row.values[17]),
            .text_style = try allocator.dupe(u8, row.values[18]),
            .image_url = try allocator.dupe(u8, row.values[19]),
            .created_at = try allocator.dupe(u8, row.values[20]),
            .updated_at = try allocator.dupe(u8, row.values[21]),
        });
    }
    return rows.toOwnedSlice(allocator);
}

/// Get a single element by id (excluding HTML body). Returns
/// `ElementNotFound` if no such row exists.
pub fn getElement(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    element_id: []const u8,
) anyerror!DesignElement {
    var q = try db.query(allocator,
        \\SELECT de.id, de.page_id, de.name, de.file_path,
        \\       de.x, de.y, de.width, de.height, de.z_index, de.position,
        \\       de.type, de.rotation, de.fill, de.stroke, de.stroke_width,
        \\       de.corner_radius, de.opacity,
        \\       de.text_content, de.text_style, de.image_url,
        \\       COALESCE(de.created_at, ''), COALESCE(de.updated_at, '')
        \\FROM design_page_elements de
        \\WHERE de.id = ?
    , &.{element_id});
    defer q.deinit();
    const row = (try q.next()) orelse return error.ElementNotFound;
    defer row.deinit(allocator);
    return .{
        .id = try allocator.dupe(u8, row.values[0]),
        .page_id = try allocator.dupe(u8, row.values[1]),
        .name = try allocator.dupe(u8, row.values[2]),
        .file_path = try allocator.dupe(u8, row.values[3]),
        .x = std.fmt.parseInt(i64, row.values[4], 10) catch 0,
        .y = std.fmt.parseInt(i64, row.values[5], 10) catch 0,
        .width = std.fmt.parseInt(i64, row.values[6], 10) catch 0,
        .height = std.fmt.parseInt(i64, row.values[7], 10) catch 0,
        .z_index = std.fmt.parseInt(i64, row.values[8], 10) catch 0,
        .position = std.fmt.parseInt(i64, row.values[9], 10) catch 0,
        .elem_type = try allocator.dupe(u8, row.values[10]),
        .rotation = std.fmt.parseFloat(f64, row.values[11]) catch 0,
        .fill = try allocator.dupe(u8, row.values[12]),
        .stroke = try allocator.dupe(u8, row.values[13]),
        .stroke_width = std.fmt.parseInt(i64, row.values[14], 10) catch 0,
        .corner_radius = std.fmt.parseInt(i64, row.values[15], 10) catch 0,
        .opacity = std.fmt.parseFloat(f64, row.values[16]) catch 0,
        .text_content = try allocator.dupe(u8, row.values[17]),
        .text_style = try allocator.dupe(u8, row.values[18]),
        .image_url = try allocator.dupe(u8, row.values[19]),
        .created_at = try allocator.dupe(u8, row.values[20]),
        .updated_at = try allocator.dupe(u8, row.values[21]),
    };
}

/// Free a single DesignElement (no backing slice).
pub fn freeElement(allocator: std.mem.Allocator, e: DesignElement) void {
    allocator.free(e.id);
    allocator.free(e.page_id);
    allocator.free(e.name);
    allocator.free(e.file_path);
    allocator.free(e.elem_type);
    allocator.free(e.fill);
    allocator.free(e.stroke);
    allocator.free(e.text_content);
    allocator.free(e.text_style);
    allocator.free(e.image_url);
    allocator.free(e.created_at);
    allocator.free(e.updated_at);
}

// ─── PageWithElements (page + elements bundle for REST GET endpoints) ─────

/// One page plus all its elements (no HTML bodies — lazy-loaded via
/// `loadElementHtml`). Free with `self.deinit(allocator)`.
pub const PageWithElements = struct {
    page: DesignPage,
    elements: []DesignElement,

    /// Release the page fields, every element's fields, and the
    /// elements slice in one call. Mirrors the lifecycle of `listPages`
    /// + `listElements` but bundled.
    pub fn deinit(self: PageWithElements, allocator: std.mem.Allocator) void {
        allocator.free(self.page.id);
        allocator.free(self.page.workspace_item_id);
        allocator.free(self.page.name);
        allocator.free(self.page.created_at);
        allocator.free(self.page.updated_at);
        freeElements(allocator, self.elements);
    }
};

/// Get ONE design page with all of its elements (no HTML bodies).
/// Returns `PageNotFound` if no page with that id exists. The
/// returned bundle owns all heap allocations — caller MUST call
/// `result.deinit(allocator)`.
///
/// Lazy-loading: element HTML bodies are NOT included; use
/// `loadElementHtml(element_id)` to fetch them individually.
pub fn getPageWithElements(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    page_id: []const u8,
) anyerror!PageWithElements {
    // 1. Fetch the page row.
    var q = try db.query(allocator,
        \\SELECT dp.id, dp.workspace_item_id, dp.name, dp.width, dp.height,
        \\       dp.position, COALESCE(dp.created_at, ''), COALESCE(dp.updated_at, '')
        \\FROM design_pages dp
        \\WHERE dp.id = ?
    , &.{page_id});
    defer q.deinit();

    const page = (try q.next()) orelse return error.PageNotFound;
    // The page row is owned by `q` — dup the fields BEFORE row.deinit
    // fires (the existing listPages pattern uses allocator.dupe inside
    // the loop body). See project memory
    // `zig-slice-headers-across-defer-lifetimes`.
    var page_owned: DesignPage = undefined;
    {
        defer page.deinit(allocator);
        page_owned = .{
            .id = try allocator.dupe(u8, page.values[0]),
            .workspace_item_id = try allocator.dupe(u8, page.values[1]),
            .name = try allocator.dupe(u8, page.values[2]),
            .width = std.fmt.parseInt(i64, page.values[3], 10) catch 0,
            .height = std.fmt.parseInt(i64, page.values[4], 10) catch 0,
            .position = std.fmt.parseInt(i64, page.values[5], 10) catch 0,
            .created_at = try allocator.dupe(u8, page.values[6]),
            .updated_at = try allocator.dupe(u8, page.values[7]),
        };
    }

    // 2. Fetch the page's elements via the existing listElements helper.
    const elements = try listElements(allocator, db, page_owned.id);

    return .{
        .page = page_owned,
        .elements = elements,
    };
}

/// List ALL pages of a design item, each with its elements (no HTML
/// bodies). Returns an owned slice; caller MUST call `freePagesWithElements`
/// (or each result's `deinit` + `allocator.free(slice)`).
///
/// For an item with N pages and M total elements across all pages,
/// this issues 1 query for the page list and N queries for the
/// elements — fine for small N (the design-mode UI typically has
/// 3-10 pages). If N grows large, callers should batch via
/// `getPageWithElements` per visible page instead.
pub fn listPagesWithElements(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    item_id: []const u8,
) anyerror![]PageWithElements {
    const pages = try listPages(allocator, db, item_id);
    // Track how many pages we've successfully moved into `rows`.
    // Un-consumed pages still own their strings (and need freeing
    // on error). Consumed pages are owned by `rows` (freed by
    // rows.deinit via the errdefer below). The backing slice of
    // `pages` is freed on both paths (success path frees it
    // directly after the loop; error path frees it via the defer
    // below).
    var consumed: usize = 0;
    var backing_slice_freed = false;
    defer {
        if (!backing_slice_freed) {
            // Error path: free the un-consumed tail's strings, then
            // the backing slice. The consumed pages are owned by
            // `rows` and will be freed by its errdefer below
            // (registered AFTER this defer).
            for (pages[consumed..]) |p| {
                allocator.free(p.id);
                allocator.free(p.workspace_item_id);
                allocator.free(p.name);
                allocator.free(p.created_at);
                allocator.free(p.updated_at);
            }
            allocator.free(pages);
        }
    }

    var rows = std.ArrayList(PageWithElements).empty;
    errdefer {
        for (rows.items) |*r| r.deinit(allocator);
        rows.deinit(allocator);
        // The outer defer for `pages` cleanup has ALREADY fired by
        // here (errdefer LIFO ordering — registered last, fires first).
    }

    for (pages) |page| {
        const elements = listElements(allocator, db, page.id) catch |err| {
            // listElements failed before we moved the page into
            // rows. The page's strings will be freed by the outer
            // defer (pages[consumed..] includes this page).
            return err;
        };
        // If rows.append fails, we still own `elements` and need
        // to free them (the page's strings are freed by the outer
        // defer because consumed was not incremented yet).
        errdefer freeElements(allocator, elements);
        rows.append(allocator, .{
            .page = page,
            .elements = elements,
        }) catch |err| return err;
        consumed += 1;
    }

    // Success: backing slice is no longer needed (per-page strings
    // have all been moved into rows.items). Free the backing slice
    // and tell the outer defer to skip its work.
    backing_slice_freed = true;
    allocator.free(pages);
    return rows.toOwnedSlice(allocator);
}

/// Free a slice of PageWithElements and its backing storage.
pub fn freePagesWithElements(allocator: std.mem.Allocator, items: []PageWithElements) void {
    for (items) |*item| item.deinit(allocator);
    allocator.free(items);
}

// ─── deleteElement ────────────────────────────────────────────────────────

/// Delete an element. Returns `true` if the row was deleted, `false`
/// if no such element existed.
///
/// The on-disk file is unlinked AFTER the SQL DELETE succeeds
/// (defer-pattern). If the unlink fails (file missing or
/// permission denied), we silently log and continue — the DB
/// state is the source of truth, and a leftover file becomes an
/// orphan that the next run can clean up.
pub fn deleteElement(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    element_id: []const u8,
) anyerror!bool {
    // Look up file_path + workspace_id + item_id + page_id BEFORE
    // delete so we can both unlink the file and emit a
    // `design_element_deleted` SSE event with the full id context.
    // Single JOIN query that returns all four pieces of context.
    const Lookup = struct {
        file_path: []u8,
        page_id: []u8,
        workspace_id: []u8,
        item_id: []u8,
    };
    const lookup: Lookup = blk: {
        var q = try db.query(allocator,
            \\SELECT de.file_path, de.page_id, wi.workspace_id,
            \\       dp.workspace_item_id
            \\FROM design_page_elements de
            \\JOIN design_pages dp ON dp.id = de.page_id
            \\JOIN workspace_items wi ON wi.id = dp.workspace_item_id
            \\WHERE de.id = ?
        , &.{element_id});
        defer q.deinit();
        const row = (try q.next()) orelse return false;
        defer row.deinit(allocator);
        break :blk .{
            .file_path = try allocator.dupe(u8, row.values[0]),
            .page_id = try allocator.dupe(u8, row.values[1]),
            .workspace_id = try allocator.dupe(u8, row.values[2]),
            .item_id = try allocator.dupe(u8, row.values[3]),
        };
    };
    defer allocator.free(lookup.file_path);
    defer allocator.free(lookup.page_id);
    defer allocator.free(lookup.workspace_id);
    defer allocator.free(lookup.item_id);

    // Delete the row first.
    try db.exec(allocator,
        "DELETE FROM design_page_elements WHERE id = ?",
        &.{element_id});

    // Defer-pattern: unlink file AFTER SQL succeeded. Swallow errors
    // (the file may already be missing or read-only).
    if (lookup.file_path.len > 0) {
        design_io.deleteFileIfExists(allocator, lookup.file_path) catch {};
    }

    // Emit SSE event AFTER the SQL DELETE succeeded. Best-effort: if
    // the event_bus is not initialized or the JSON serialization
    // fails, the caller still gets a successful return value — SSE
    // is a hint, not a hard contract. The lookup slices are still
    // alive at this point; the function-level defers haven't fired.
    on_event_sent_design.onEventSendDesignElementDeleted(allocator, .{
        .action = "deleted",
        .workspace_id = lookup.workspace_id,
        .item_id = lookup.item_id,
        .page_id = lookup.page_id,
        .element_id = element_id,
    }) catch {};
    return true;
}

// ─── loadElementHtml ──────────────────────────────────────────────────────

/// Read the on-disk HTML body for an element. Returns
/// `ElementNotFound` if no such row exists; propagates IO errors
/// from the file read.
pub fn loadElementHtml(
    allocator: std.mem.Allocator,
    io: std.Io,
    db: *sqlite.SqliteBackend,
    element_id: []const u8,
) anyerror![]u8 {
    var q = try db.query(allocator,
        "SELECT de.file_path FROM design_page_elements de WHERE de.id = ?",
        &.{element_id});
    defer q.deinit();
    const row = (try q.next()) orelse return error.ElementNotFound;
    defer row.deinit(allocator);
    const file_path = try allocator.dupe(u8, row.values[0]);
    defer allocator.free(file_path);
    if (file_path.len == 0) return error.FileNotFound;
    return try std.Io.Dir.cwd().readFileAlloc(io, file_path, allocator, .limited(5 * 1024 * 1024));
}
