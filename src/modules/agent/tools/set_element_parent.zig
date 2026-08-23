//! LLM tool: `set_element_parent` — re-parents an existing design
//! element to a new `group`/`frame` parent, or back to top-level via
//! `null`.
//!
//! Plan: docs/superpowers/plans/2026-07-29-design-element-parent-id-tools.md
//! (Task 5)

const std = @import("std");
const schemas = @import("schemas.zig");
const AgentTool = schemas.AgentTool;
const nalarcore = @import("nalarcore");
const sqlite = nalarcore.sqlite;
const design_model = nalarcore.ai_mod.design_model;

/// Input structure for `set_element_parent` tool.
///
/// Both fields are required. Pass `null` for `new_parent_id` to move
/// the element back to top-level (the inverse of nesting).
pub const SetElementParentInput = struct {
    /// The element id to re-parent. Must exist on the active page.
    element_id: []const u8 = "",
    /// The new parent's element id. Must reference a `group` or
    /// `frame` on the SAME page as `element_id`. Pass `null` to move
    /// the element to top-level (parent_id cleared).
    new_parent_id: ?[]const u8 = null,
};

/// Top-level tool definition for the LLM.
pub const set_element_parent_tool = AgentTool{
    .type = "function",
    .function = .{
        .name = "set_element_parent",
        .description =
            \\Re-parent an existing design element to a new `group` or `frame`, or back to top-level. This is the inverse of `add_element`'s `parent_id` parameter for existing elements — use it to FIX a previously-created element that landed at the wrong nesting level.
            \\
            \\The `element_id` must reference an element on the active page. The `new_parent_id` must reference a `group` or `frame` on the SAME page (leaf types like rectangle, ellipse, text, image cannot contain children — rejected with `ParentNotContainer`). Pass `new_parent_id = null` to move the element to top-level (clears parent_id).
            \\
            \\Discover ids via `set_design_page` — each `<element id="...">` block carries the id. The `<element>` block also carries `parent_id="elem_..."` (or `parent_id=""` for top-level), so you can see the current hierarchy.
            \\
            \\On error, recover by: (1) verify `element_id` from a fresh `set_design_page` call; (2) verify `new_parent_id` is `group` or `frame` on the same page; (3) pass `null` to unparent.
        ,
        .parameters = .{
            .type = "object",
            .properties = &.{
                .{
                    .name = "element_id",
                    .type = "string",
                    .description = "The element id to re-parent (NOT a page_id or workspace_id). Find it in the `id=\"...\"` attribute of an `<element>` block in a previous `set_design_page` response.",
                },
                .{
                    .name = "new_parent_id",
                    .type = "string",
                    .description = "The new parent's element id (a `group` or `frame` on the same page), or null to move to top-level. Pass null for top-level.",
                },
            },
            .required = &.{ "element_id" },
        },
    },
};

/// Escape XML special characters. Mirrors the helper in
/// `update_design_element.zig` / `group_design_elements.zig`
/// (duplicated locally to keep this tool file self-contained).
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

/// Generate an error XML response. The error body is wrapped in
/// `<set_element_parent><error>...</error></set_element_parent>` so
/// the tool dispatcher can detect it via `<error>` substring search.
pub fn errorXml(allocator: std.mem.Allocator, error_msg: []const u8) ![]u8 {
    var xml: std.ArrayList(u8) = .empty;
    errdefer xml.deinit(allocator);

    try xml.appendSlice(allocator, "<set_element_parent><error>");
    const escaped = try xmlEscape(allocator, error_msg);
    defer allocator.free(escaped);
    try xml.appendSlice(allocator, escaped);
    try xml.appendSlice(allocator, "</error></set_element_parent>");
    return try xml.toOwnedSlice(allocator);
}

/// Same as `errorXml` but TAKES OWNERSHIP of `error_msg` and frees it.
pub fn errorXmlOwned(allocator: std.mem.Allocator, error_msg: []u8) ![]u8 {
    defer allocator.free(error_msg);

    var xml: std.ArrayList(u8) = .empty;
    errdefer xml.deinit(allocator);

    try xml.appendSlice(allocator, "<set_element_parent><error>");
    const escaped = try xmlEscape(allocator, error_msg);
    defer allocator.free(escaped);
    try xml.appendSlice(allocator, escaped);
    try xml.appendSlice(allocator, "</error></set_element_parent>");
    return try xml.toOwnedSlice(allocator);
}

/// Validate `element_id` is non-empty and has the right `elem_` prefix.
/// Returns null when shape is correct, or an error XML on mismatch.
fn validateElementIdShape(allocator: std.mem.Allocator, element_id: []const u8) !?[]u8 {
    if (element_id.len == 0) {
        return try errorXml(allocator, "element_id is required (find it in the `id=\"...\"` attribute of an `<element>` block in a previous set_design_page response)");
    }
    if (std.mem.startsWith(u8, element_id, "page_")) {
        return try errorXmlOwned(allocator, try std.fmt.allocPrint(allocator,
            \\element_id '{s}' looks like a PAGE id (starts with 'page_'). Pass the ELEMENT id instead — find it in the `id="..."` attribute of an `<element>` block in a `set_design_page` response.
        , .{element_id}));
    }
    if (std.mem.startsWith(u8, element_id, "item_")) {
        return try errorXmlOwned(allocator, try std.fmt.allocPrint(allocator,
            \\element_id '{s}' looks like an ITEM id (starts with 'item_'). Pass the ELEMENT id instead — find it in the `id="..."` attribute of an `<element>` block in a `set_design_page` response.
        , .{element_id}));
    }
    if (!std.mem.startsWith(u8, element_id, "elem_")) {
        return try errorXmlOwned(allocator, try std.fmt.allocPrint(allocator,
            \\element_id '{s}' has an unrecognized prefix (expected 'elem_'). set_element_parent expects an element id from a previous set_design_page response, not a free-form string.
        , .{element_id}));
    }
    return null;
}

/// Execute the `set_element_parent` tool. Returns an XML string for
/// the LLM.
///
/// On success, the response shape is:
/// ```xml
/// <set_element_parent>
///   <element id="elem_..." name="..." parent_id="..." .../>
/// </set_element_parent>
/// ```
///
/// On error, the response is wrapped in
/// `<set_element_parent><error>...</error></set_element_parent>`.
pub fn executeSetElementParentToString(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    input: SetElementParentInput,
) ![]u8 {
    // 0. Input validation (shape only — DB validation runs after).
    if (try validateElementIdShape(allocator, input.element_id)) |e| return e;

    // 1. Delegate to design_model.setElementParent. The model layer
    //    handles parent existence, type check, cycle detection, and
    //    the actual UPDATE.
    design_model.setElementParent(allocator, db, input.element_id, input.new_parent_id) catch |err| {
        return switch (err) {
            error.ElementNotFound => try errorXml(allocator, "element_id does not reference any design element — call set_design_page first"),
            error.ParentNotFound => try errorXml(allocator, "new_parent_id does not reference any design element — call set_design_page first"),
            error.ParentNotContainer => try errorXml(allocator, "new_parent_id points to a leaf-type element (rectangle/ellipse/text/image); only `group` or `frame` can contain children"),
            error.DifferentPages => try errorXml(allocator, "element and new_parent are on different pages; re-parenting across pages is not supported"),
            error.CycleDetected => try errorXml(allocator, "cycle detected: new_parent is a descendant of element_id (would create a cycle in the group hierarchy)"),
            else => try errorXmlOwned(allocator, try std.fmt.allocPrint(allocator, "DB: setElementParent failed: {s}", .{@errorName(err)})),
        };
    };

    // 2. Re-fetch the element so the LLM gets the canonical state
    //    (with the new parent_id reflected).
    const elem = design_model.getElement(allocator, db, input.element_id) catch |err| {
        return try errorXmlOwned(allocator, try std.fmt.allocPrint(allocator, "DB: getElement failed: {s}", .{@errorName(err)}));
    };
    defer design_model.freeElement(allocator, elem);

    // 3. Render the response XML.
    var xml: std.ArrayList(u8) = .empty;
    errdefer xml.deinit(allocator);

    try xml.appendSlice(allocator, "<set_element_parent>");

    // Re-use the elementToXml renderer from add_design_element.zig.
    const elem_xml = try nalarcore.add_design_element.elementToXml(allocator, elem);
    defer allocator.free(elem_xml);
    try xml.appendSlice(allocator, elem_xml);

    try xml.appendSlice(allocator, "</set_element_parent>");
    return try xml.toOwnedSlice(allocator);
}

const testing = std.testing;

const set_element_parent = @import("set_element_parent.zig");

/// Open a fresh in-memory sqlite DB with the v6 design schema. Same
/// shape as the other test files (`setupDbAndItem`) — copied locally
/// for self-containment.
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

    const item_id_const = "item_design_set_parent_tool";
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

fn teardown(db: *sqlite.SqliteBackend, threaded: *std.Io.Threaded) void {
    db.deinit();
    threaded.deinit();
}

// ─── Test 1: happy path — re-parent into an existing frame ───────────────

test "executeSetElementParentToString moves element into existing group" {
    const alloc = testing.allocator;
    var ctx = try setupDbAndItem();
    defer teardown(&ctx.db, &ctx.threaded);
    defer alloc.free(ctx.item_id);
    defer alloc.free(ctx.item_path);

    const page_id = try design_model.setDesignPage(alloc, &ctx.db, .{
        .item_id = ctx.item_id,
        .page_name = "Login",
        .width = 1440,
        .height = 1024,
    });
    defer alloc.free(page_id);

    const group_id = try design_model.addElement(alloc, &ctx.db, ctx.threaded.io(), .{
        .page_id = page_id,
        .name = "login-card",
        .elem_type = .frame,
        .html = "<div></div>",
        .x = 100, .y = 200, .width = 400, .height = 300,
        .fill = "#ffffff", .rotation = 0.0, .corner_radius = 0, .opacity = 1.0,
    });
    defer alloc.free(group_id);

    const child_id = try design_model.addElement(alloc, &ctx.db, ctx.threaded.io(), .{
        .page_id = page_id,
        .name = "login-button",
        .elem_type = .rectangle,
        .html = "<div></div>",
        .x = 110, .y = 220, .width = 80, .height = 30,
        .fill = "#000000", .rotation = 0.0, .corner_radius = 0, .opacity = 1.0,
    });
    defer alloc.free(child_id);

    // Call the LLM tool.
    const xml = try set_element_parent.executeSetElementParentToString(alloc, &ctx.db, .{
        .element_id = child_id,
        .new_parent_id = group_id,
    });
    defer alloc.free(xml);
    // Tool response shape: `<set_element_parent><element id="..." parent_id="..." .../></set_element_parent>`.
    // It must NOT contain `<error>` on the happy path.
    try testing.expect(!std.mem.containsAtLeast(u8, xml, 1, "<error>"));
    try testing.expect(std.mem.indexOf(u8, xml, "<set_element_parent>") != null);
    try testing.expect(std.mem.indexOf(u8, xml, group_id) != null);

    // Verify the DB state directly (round-trip via design_model).
    const got = try design_model.getElement(alloc, &ctx.db, child_id);
    defer design_model.freeElement(alloc, got);
    try testing.expectEqualStrings(group_id, got.parent_id);
}

// ─── Test 2: reject leaf-type parent ──────────────────────────────────────

test "executeSetElementParentToString rejects leaf-type parent" {
    const alloc = testing.allocator;
    var ctx = try setupDbAndItem();
    defer teardown(&ctx.db, &ctx.threaded);
    defer alloc.free(ctx.item_id);
    defer alloc.free(ctx.item_path);

    const page_id = try design_model.setDesignPage(alloc, &ctx.db, .{
        .item_id = ctx.item_id,
        .page_name = "Login",
        .width = 1440,
        .height = 1024,
    });
    defer alloc.free(page_id);

    const leaf_id = try design_model.addElement(alloc, &ctx.db, ctx.threaded.io(), .{
        .page_id = page_id,
        .name = "leaf",
        .elem_type = .rectangle,
        .html = "<div></div>",
        .x = 0, .y = 0, .width = 50, .height = 50,
        .fill = "#ffffff", .rotation = 0.0, .corner_radius = 0, .opacity = 1.0,
    });
    defer alloc.free(leaf_id);

    const child_id = try design_model.addElement(alloc, &ctx.db, ctx.threaded.io(), .{
        .page_id = page_id,
        .name = "child",
        .elem_type = .rectangle,
        .html = "<div></div>",
        .x = 0, .y = 0, .width = 50, .height = 50,
        .fill = "#ffffff", .rotation = 0.0, .corner_radius = 0, .opacity = 1.0,
    });
    defer alloc.free(child_id);

    const xml = try set_element_parent.executeSetElementParentToString(alloc, &ctx.db, .{
        .element_id = child_id,
        .new_parent_id = leaf_id,
    });
    defer alloc.free(xml);
    try testing.expect(std.mem.indexOf(u8, xml, "<error>") != null);
    try testing.expect(std.mem.indexOf(u8, xml, "group") != null); // error mentions "group or frame"
}

// ─── Test 3: reject non-existent element_id ──────────────────────────────

test "executeSetElementParentToString rejects non-existent element_id" {
    const alloc = testing.allocator;
    var ctx = try setupDbAndItem();
    defer teardown(&ctx.db, &ctx.threaded);
    defer alloc.free(ctx.item_id);
    defer alloc.free(ctx.item_path);

    const page_id = try design_model.setDesignPage(alloc, &ctx.db, .{
        .item_id = ctx.item_id,
        .page_name = "Login",
        .width = 1440,
        .height = 1024,
    });
    defer alloc.free(page_id);

    const group_id = try design_model.addElement(alloc, &ctx.db, ctx.threaded.io(), .{
        .page_id = page_id,
        .name = "group",
        .elem_type = .frame,
        .html = "<div></div>",
        .x = 0, .y = 0, .width = 100, .height = 100,
        .fill = "#ffffff", .rotation = 0.0, .corner_radius = 0, .opacity = 1.0,
    });
    defer alloc.free(group_id);

    const xml = try set_element_parent.executeSetElementParentToString(alloc, &ctx.db, .{
        .element_id = "elem_does_not_exist",
        .new_parent_id = group_id,
    });
    defer alloc.free(xml);
    try testing.expect(std.mem.indexOf(u8, xml, "<error>") != null);
}

// ─── Test 4: invalid element_id prefix returns XML error ──────────────────

test "executeSetElementParentToString rejects element_id with invalid prefix" {
    const alloc = testing.allocator;
    var ctx = try setupDbAndItem();
    defer teardown(&ctx.db, &ctx.threaded);
    defer alloc.free(ctx.item_id);
    defer alloc.free(ctx.item_path);

    const xml = try set_element_parent.executeSetElementParentToString(alloc, &ctx.db, .{
        .element_id = "not_elem_anything",
        .new_parent_id = "elem_anything",
    });
    defer alloc.free(xml);
    try testing.expect(std.mem.indexOf(u8, xml, "<error>") != null);
    try testing.expect(std.mem.indexOf(u8, xml, "element_id") != null);
}

// ─── Test 5: set_element_parent to null moves element to top-level ─────

test "executeSetElementParentToString with null moves element to top-level" {
    const alloc = testing.allocator;
    var ctx = try setupDbAndItem();
    defer teardown(&ctx.db, &ctx.threaded);
    defer alloc.free(ctx.item_id);
    defer alloc.free(ctx.item_path);

    const page_id = try design_model.setDesignPage(alloc, &ctx.db, .{
        .item_id = ctx.item_id,
        .page_name = "Login",
        .width = 1440,
        .height = 1024,
    });
    defer alloc.free(page_id);

    const group_id = try design_model.addElement(alloc, &ctx.db, ctx.threaded.io(), .{
        .page_id = page_id,
        .name = "group",
        .elem_type = .frame,
        .html = "<div></div>",
        .x = 0, .y = 0, .width = 100, .height = 100,
        .fill = "#ffffff", .rotation = 0.0, .corner_radius = 0, .opacity = 1.0,
    });
    defer alloc.free(group_id);

    // Create a child with parent_id = group_id via direct SQL
    // (addElement always sets parent_id = NULL).
    try ctx.db.exec(alloc,
        \\INSERT INTO design_page_elements
        \\   (id, page_id, name, file_path, x, y, width, height, z_index, position,
        \\    type, rotation, fill, stroke, stroke_width, corner_radius, opacity,
        \\    text_content, text_style, image_url, parent_id,
        \\    created_at, updated_at)
        \\VALUES
        \\   ('elem_inner', ?, 'inner', '', 10, 10, 20, 20, 0, 0,
        \\    'rectangle', 0.0, '', '', 0, 0, 1.0,
        \\    '', '', '', ?, datetime('now'), datetime('now'))
    , &.{ page_id, group_id });

    // Call set_element_parent with null.
    const xml = try set_element_parent.executeSetElementParentToString(alloc, &ctx.db, .{
        .element_id = "elem_inner",
        .new_parent_id = null,
    });
    defer alloc.free(xml);
    try testing.expect(!std.mem.containsAtLeast(u8, xml, 1, "<error>"));

    // Verify DB state.
    const got = try design_model.getElement(alloc, &ctx.db, "elem_inner");
    defer design_model.freeElement(alloc, got);
    try testing.expectEqual(@as(usize, 0), got.parent_id.len);
}
