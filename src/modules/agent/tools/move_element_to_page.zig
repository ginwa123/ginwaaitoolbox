//! LLM tool: `move_element_to_page` — relocates an existing design
//! element from one page to another page in the same design item.
//! When `apply_to_children = true` (the default), the move cascades to
//! every transitive descendant of the element via the backend's
//! recursive CTE in one SQL transaction — so the LLM can say "move
//! Group 2 to page 'Checkout'" and the whole subtree follows (Figma
//! parity).
//!
//! Plan: docs/superpowers/plans/2026-08-06-move-element-to-page.md
//! (Chunk 3, Task 3.1)

const std = @import("std");
const schemas = @import("schemas.zig");
const AgentTool = schemas.AgentTool;
const nalarcore = @import("nalarcore");
const sqlite = nalarcore.sqlite;
const design_model = nalarcore.ai_mod.design_model;

/// Input shape for `move_element_to_page` tool.
///
/// All fields except `element_id` and `new_page_id` are optional.
/// - `apply_to_children` defaults to `true` — matches the user's
///   "move element parent will be move all child" mental model from
///   the `move_design_element` tool.
/// - `new_page_id` is REQUIRED (no default) — the tool errors out on
///   empty / missing values.
pub const MoveElementToPageInput = struct {
    /// The element id to move. Must exist on the active page.
    element_id: []const u8 = "",
    /// The destination page id. Both pages must live on the same
    /// design item (`workspace_item_id`); cross-design moves are
    /// rejected with `CrossDesign`.
    new_page_id: []const u8 = "",
    /// Default true. When false, only the root moves (descendants
    /// stay behind on the source page as top-level orphans).
    apply_to_children: bool = true,
};

/// Top-level tool definition for the LLM.
pub const move_element_to_page_tool = AgentTool{
    .type = "function",
    .function = .{
        .name = "move_element_to_page",
        .description =
            \\Relocate an existing design element from the active page to a different page within the same design item. Use this when the user wants to reorganize elements across the page list — e.g. "move this button to the Checkout page". When `apply_to_children=true` (the default), every transitive descendant of the element moves with it (Figma parity: moving a `group` or `frame` moves the whole subtree). When `apply_to_children=false`, only the root moves; descendants are left behind on the source page as top-level orphans.
            \\
            \\The `element_id` must reference an element on the active page. The `new_page_id` must be a sibling page in the same design item — discover siblings via `get_design_context` (the `<pages count="N">` block). Both fields are required. Passing the same page as the active page (`new_page_id == active_page`) returns `SamePage`.
            \\
            \\Discover ids via `set_design_page` / `get_design_context` — each `<element>` / `<page>` block carries an `id="..."` attribute.
            \\
            \\On error, recover by: (1) verify `element_id` and `new_page_id` are non-empty and correctly prefixed; (2) call `get_design_context` to confirm `new_page_id` exists on the same design item as the active page; (3) on `ElementNotFound`, refresh the active page's element list — the element may have been deleted.
        ,
        .parameters = .{
            .type = "object",
            .properties = &.{
                .{
                    .name = "element_id",
                    .type = "string",
                    .description = "The element id to move. Find it in the `id=\"...\"` attribute of an `<element>` block in a `set_design_page` or `get_design_context` response.",
                },
                .{
                    .name = "new_page_id",
                    .type = "string",
                    .description = "The destination page id. Must be a sibling page in the same design item. Find it in the `id=\"...\"` attribute of a `<page>` block in `get_design_context`.",
                },
                .{
                    .name = "apply_to_children",
                    .type = "boolean",
                    .description = "Default true. When true, every transitive descendant of the element moves with it. Pass false to move a single element only (descendants stay on the source page as orphans).",
                },
            },
            .required = &.{ "element_id", "new_page_id" },
        },
    },
};

/// Escape XML special characters. Mirrors the helper in
/// `move_design_element.zig` (duplicated locally to keep this tool
/// file self-contained).
fn xmlEscape(allocator: std.mem.Allocator, s: []const u8) ![]u8 {
    var result: std.ArrayList(u8) = .empty;
    errdefer result.deinit(allocator);

    for (s) |c| {
        switch (c) {
            '<' => try result.appendSlice(allocator, "&lt;"),
            '>' => try result.appendSlice(allocator, "&gt;"),
            '&' => try result.appendSlice(allocator, "&amp;"),
            '"' => try result.appendSlice(allocator, "&quot;"),
            '\'' => try result.appendSlice(allocator, "&apos;"),
            else => try result.append(allocator, c),
        }
    }

    return try result.toOwnedSlice(allocator);
}

/// Error XML response wrapped in the `move_element_to_page` envelope so
/// the tool dispatcher can detect it via `<error>` substring search.
pub fn errorXml(allocator: std.mem.Allocator, error_msg: []const u8) ![]u8 {
    var xml: std.ArrayList(u8) = .empty;
    errdefer xml.deinit(allocator);

    try xml.appendSlice(allocator, "<move_element_to_page><error>");
    const escaped = try xmlEscape(allocator, error_msg);
    defer allocator.free(escaped);
    try xml.appendSlice(allocator, escaped);
    try xml.appendSlice(allocator, "</error></move_element_to_page>");
    return try xml.toOwnedSlice(allocator);
}

/// Same as `errorXml` but TAKES OWNERSHIP of `error_msg` and frees it.
pub fn errorXmlOwned(allocator: std.mem.Allocator, error_msg: []u8) ![]u8 {
    defer allocator.free(error_msg);

    var xml: std.ArrayList(u8) = .empty;
    errdefer xml.deinit(allocator);

    try xml.appendSlice(allocator, "<move_element_to_page><error>");
    const escaped = try xmlEscape(allocator, error_msg);
    defer allocator.free(escaped);
    try xml.appendSlice(allocator, escaped);
    try xml.appendSlice(allocator, "</error></move_element_to_page>");
    return try xml.toOwnedSlice(allocator);
}

/// Validate `element_id` is non-empty and `new_page_id` is non-empty.
/// Returns null when both are valid, or an error XML on a missing
/// field.
fn validateInputShape(allocator: std.mem.Allocator, input: MoveElementToPageInput) !?[]u8 {
    if (input.element_id.len == 0) {
        return try errorXml(allocator, "element_id is required (find it in the `id=\"...\"` attribute of an `<element>` block in a `set_design_page` or `get_design_context` response)");
    }
    if (input.new_page_id.len == 0) {
        return try errorXml(allocator, "new_page_id is required (find it in the `id=\"...\"` attribute of a `<page>` block in `get_design_context`)");
    }
    if (std.mem.startsWith(u8, input.element_id, "page_")) {
        return try errorXmlOwned(allocator, try std.fmt.allocPrint(allocator,
            \\element_id '{s}' looks like a PAGE id (starts with 'page_'). Pass the ELEMENT id instead — find it in the `id="..."` attribute of an `<element>` block in a `set_design_page` response.
        , .{input.element_id}));
    }
    if (std.mem.startsWith(u8, input.element_id, "item_")) {
        return try errorXmlOwned(allocator, try std.fmt.allocPrint(allocator,
            \\element_id '{s}' looks like an ITEM id (starts with 'item_'). Pass the ELEMENT id instead.
        , .{input.element_id}));
    }
    if (!std.mem.startsWith(u8, input.element_id, "elem_")) {
        return try errorXmlOwned(allocator, try std.fmt.allocPrint(allocator,
            \\element_id '{s}' has an unrecognized prefix (expected 'elem_'). move_element_to_page expects an element id from a previous set_design_page or get_design_context response.
        , .{input.element_id}));
    }
    if (!std.mem.startsWith(u8, input.new_page_id, "page_")) {
        return try errorXmlOwned(allocator, try std.fmt.allocPrint(allocator,
            \\new_page_id '{s}' has an unrecognized prefix (expected 'page_'). move_element_to_page expects a page id from a previous get_design_context response.
        , .{input.new_page_id}));
    }
    return null;
}

/// Execute the `move_element_to_page` tool. Returns an XML string for
/// the LLM.
///
/// On success, the response shape is:
/// ```xml
/// <move_element_to_page>
///   <moved>
///     <element id="..." page_id="..." name="..." />
///     ...
///   </moved>
/// </move_element_to_page>
/// ```
///
/// On error, the response is wrapped in
/// `<move_element_to_page><error>...</error></move_element_to_page>`.
pub fn executeMoveElementToPageToString(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    active_page_id: []const u8,
    input: MoveElementToPageInput,
) ![]u8 {
    // 0. Input validation (shape only — DB validation runs after).
    if (try validateInputShape(allocator, input)) |e| return e;

    // 1. Delegate to the design-model layer. The cascade + auto-detach
    //    + SSE event all happen inside `moveElementToPage`.
    const updated = design_model.moveElementToPage(allocator, db, .{
        .source_page_id = active_page_id,
        .element_id = input.element_id,
        .target_page_id = input.new_page_id,
        .apply_to_children = input.apply_to_children,
    }) catch |err| {
        return switch (err) {
            error.SamePage => try errorXml(allocator, "new_page_id must be a DIFFERENT page from the active page (you tried to move to the same page)"),
            error.ElementNotFound => try errorXml(allocator, "element_id does not reference any element on the active page — call set_design_page to refresh"),
            error.PageNotFound => try errorXml(allocator, "new_page_id does not reference any design page — call get_design_context to find the correct page id"),
            error.CrossDesign => try errorXml(allocator, "new_page_id belongs to a different design item — cross-design moves are not supported"),
            error.DbError => try errorXml(allocator, "DB: moveElementToPage failed (unexpected SQL error)"),
            error.OutOfMemory => try errorXml(allocator, "Out of memory"),
            else => try errorXmlOwned(allocator, try std.fmt.allocPrint(allocator, "DB: moveElementToPage failed: {s}", .{@errorName(err)})),
        };
    };
    defer design_model.freeElements(allocator, updated);

    return try renderSuccessXml(allocator, updated);
}

/// Render the success XML response. Lists every moved element
/// (root + descendants) with their `page_id`, `name`, `type`.
fn renderSuccessXml(
    allocator: std.mem.Allocator,
    moved: []const design_model.DesignElement,
) ![]u8 {
    var xml: std.ArrayList(u8) = .empty;
    errdefer xml.deinit(allocator);

    try xml.appendSlice(allocator, "<move_element_to_page><moved>");
    for (moved) |e| {
        const id_esc = try xmlEscape(allocator, e.id);
        defer allocator.free(id_esc);
        const pid_esc = try xmlEscape(allocator, e.page_id);
        defer allocator.free(pid_esc);
        const name_esc = try xmlEscape(allocator, e.name);
        defer allocator.free(name_esc);
        const type_esc = try xmlEscape(allocator, e.elem_type);
        defer allocator.free(type_esc);
        try xml.appendSlice(allocator, "<element id=\"");
        try xml.appendSlice(allocator, id_esc);
        try xml.appendSlice(allocator, "\" page_id=\"");
        try xml.appendSlice(allocator, pid_esc);
        try xml.appendSlice(allocator, "\" name=\"");
        try xml.appendSlice(allocator, name_esc);
        try xml.appendSlice(allocator, "\" type=\"");
        try xml.appendSlice(allocator, type_esc);
        try xml.appendSlice(allocator, "\"/>");
    }
    try xml.appendSlice(allocator, "</moved></move_element_to_page>");
    return try xml.toOwnedSlice(allocator);
}

const move_element_to_page = @import("move_element_to_page.zig");
const testing = std.testing;

// =====================================================================
// Test fixtures
// =====================================================================

const TestCtx = struct {
    db: sqlite.SqliteBackend,
    threaded: std.Io.Threaded,
    item_id: []const u8,
    item_path: []u8,
};

fn setupDb() !TestCtx {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    errdefer threaded.deinit();
    const io = threaded.io();

    var db: sqlite.SqliteBackend = .{};
    errdefer db.deinit();
    try db.init(io, ":memory:");

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
    const tmpdir_path = try alloc.dupe(u8, tmpdir_buf[0..tmpdir_len]);
    defer alloc.free(tmpdir_path);

    const item_id_const = "item_move_to_page_tool";
    try db.exec(alloc,
        "INSERT INTO workspace_items (id, workspace_id, item_type, path) " ++
        "VALUES (?, 'ws_test', 'design', ?)",
        &.{ item_id_const, tmpdir_path });

    const item_id_slice = try alloc.dupe(u8, item_id_const);
    return .{
        .db = db,
        .threaded = threaded,
        .item_id = item_id_slice,
        .item_path = try alloc.dupe(u8, tmpdir_path),
    };
}

fn teardownDb(ctx: *TestCtx) void {
    ctx.db.deinit();
    ctx.threaded.deinit();
    testing.allocator.free(ctx.item_id);
    testing.allocator.free(ctx.item_path);
}

// =====================================================================
// Tests
// =====================================================================

test "move_element_to_page_tool has the expected LLM-facing schema (name, required fields)" {
    const tool = move_element_to_page.move_element_to_page_tool;

    try testing.expectEqualStrings("function", tool.type);
    try testing.expectEqualStrings("move_element_to_page", tool.function.name);

    // element_id + new_page_id are required.
    try testing.expectEqual(@as(usize, 2), tool.function.parameters.required.len);
    var saw_element_id = false;
    var saw_new_page_id = false;
    for (tool.function.parameters.required) |r| {
        if (std.mem.eql(u8, r, "element_id")) saw_element_id = true;
        if (std.mem.eql(u8, r, "new_page_id")) saw_new_page_id = true;
    }
    try testing.expect(saw_element_id);
    try testing.expect(saw_new_page_id);

    // All three declared properties exist.
    var saw_apply_to_children = false;
    for (tool.function.parameters.properties) |p| {
        if (std.mem.eql(u8, p.name, "apply_to_children")) saw_apply_to_children = true;
    }
    try testing.expect(saw_apply_to_children);
}

test "executeMoveElementToPageToString returns a structured success XML on happy path" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer teardownDb(&ctx);

    // Use the production helpers (matches `move_design_element_test.zig`).
    const source_page_id = try design_model.setDesignPage(alloc, &ctx.db, .{
        .item_id = ctx.item_id,
        .page_name = "source",
        .width = 1440,
        .height = 1024,
    });
    defer alloc.free(source_page_id);
    const target_page_id = try design_model.setDesignPage(alloc, &ctx.db, .{
        .item_id = ctx.item_id,
        .page_name = "target",
        .width = 1440,
        .height = 1024,
    });
    defer alloc.free(target_page_id);

    const elem_id = try design_model.addElement(alloc, &ctx.db, ctx.threaded.io(), .{
        .page_id = source_page_id,
        .name = "leaf",
        .elem_type = .rectangle,
        .html = "<div></div>",
        .x = 10, .y = 20, .width = 50, .height = 50,
        .fill = "#000000", .rotation = 0.0, .corner_radius = 0, .opacity = 1.0,
    });
    defer alloc.free(elem_id);

    const xml = try move_element_to_page.executeMoveElementToPageToString(
        alloc, &ctx.db, source_page_id,
        .{ .element_id = elem_id, .new_page_id = target_page_id, .apply_to_children = true },
    );
    defer alloc.free(xml);

    // Response shape: <move_element_to_page><moved>...<element/>...</moved>...</move_element_to_page>.
    try testing.expect(std.mem.indexOf(u8, xml, "<move_element_to_page>") != null);
    try testing.expect(std.mem.indexOf(u8, xml, "</move_element_to_page>") != null);
    try testing.expect(std.mem.indexOf(u8, xml, "<moved>") != null);
    try testing.expect(std.mem.indexOf(u8, xml, "</moved>") != null);
    try testing.expect(std.mem.indexOf(u8, xml, elem_id) != null);
    try testing.expect(std.mem.indexOf(u8, xml, target_page_id) != null);
}

test "executeMoveElementToPageToString wraps the error in <move_element_to_page><error> on missing element_id" {
    const alloc = testing.allocator;
    const xml = try move_element_to_page.executeMoveElementToPageToString(
        alloc, undefined, // DB never reached (input validation fails first)
        "page_unused",
        .{ .element_id = "", .new_page_id = "page_target", .apply_to_children = true },
    );
    defer alloc.free(xml);

    try testing.expect(std.mem.indexOf(u8, xml, "<move_element_to_page><error>") != null);
    try testing.expect(std.mem.indexOf(u8, xml, "element_id is required") != null);
}

test "executeMoveElementToPageToString rejects bad prefixes via error XML" {
    const alloc = testing.allocator;
    const xml = try move_element_to_page.executeMoveElementToPageToString(
        alloc, undefined,
        "page_unused",
        .{ .element_id = "page_wrong_shape", .new_page_id = "page_target", .apply_to_children = true },
    );
    defer alloc.free(xml);

    try testing.expect(std.mem.indexOf(u8, xml, "<error>") != null);
    try testing.expect(std.mem.indexOf(u8, xml, "PAGE id") != null);
}
