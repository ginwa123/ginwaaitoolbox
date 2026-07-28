//! LLM tool: `group_elements` — wrap 2+ elements into a new `group`
//! or `frame` parent at the union bounding box of the children.
//!
//! Delegates to `design_model.groupElements` (Phase A — Chunks 2/3 of
//! the grouped-layers plan). The tool validates inputs up-front and
//! re-fetches the parent + each child post-commit so the LLM gets the
//! canonical state in the response.
//!
//! Plan: docs/superpowers/plans/2026-07-28-grouped-layers.md (Chunk 8)

const std = @import("std");
const schemas = @import("schemas.zig");
const AgentTool = schemas.AgentTool;
const nalarcore = @import("nalarcore");
const sqlite = nalarcore.sqlite;
const design_model = nalarcore.ai_mod.design_model;

/// Input structure for `group_elements` tool.
///
/// `page_id` and `child_ids` are required. `name` defaults to
/// `"Group"` and `type` defaults to `"group"` (non-clipping) — the
/// Figma convention. The wire `type` string is one of `"group"` |
/// `"frame"`; any other value is rejected with a self-correcting
/// error XML.
pub const GroupElementsInput = struct {
    /// The page id (NOT the item_id). The LLM discovers page_ids
    /// via `set_design_page` (the response includes the page id).
    page_id: []const u8 = "",
    /// Child element ids. Must contain at least 2 ids; a single-element
    /// group is not meaningful (and is rejected by the model layer).
    /// All ids must reference elements on the SAME `page_id` and none
    /// may already be parented.
    child_ids: []const []const u8 = &.{},
    /// Name for the new parent element (optional). Defaults to
    /// `"Group"`. Must be unique within the page (the model's on-disk
    /// HTML file is `<page_dir>/<sanitized_name>.html`).
    name: ?[]const u8 = null,
    /// Parent type (optional). One of `"group"` (non-clipping
    /// container) or `"frame"` (clipping container). Defaults to
    /// `"group"`.
    type: ?[]const u8 = null,
};

/// Top-level tool definition for the LLM.
pub const group_design_element_tool = AgentTool{
    .type = "function",
    .function = .{
        .name = "group_elements",
        .description =
            \\Wrap 2 or more existing elements into a new `group` (non-clipping container) or `frame` (clipping container) parent. The new parent's geometry is the UNION bounding box of its children: x = min(child.x), y = min(child.y), width = max(child.x + child.width) - min(child.x), height = max(child.y + child.height) - min(child.y).
            \\
            \\You must provide at least 2 child element ids. All children must live on the same `page_id` and none may already be parented to another group or frame (the model rejects nested re-parenting for the first cut).
            \\
            \\Use `type="frame"` when children should be visually clipped to the parent's bounding box (e.g. a card with rounded corners and content overflow); use `type="group"` (the default) when children should render freely inside the parent's bbox without clipping (typical structural grouping like a topbar containing logo + nav + buttons).
            \\
            \\Discover the `page_id` by calling `set_design_page` first — the response includes the page id in the `id="..."` attribute. Discover child element ids from the same `set_design_page` response — each `<element id="...">` block carries an id.
            \\
            \\Returns the new parent's element XML plus one `<child id="..." name="..." parent_id="..."/>` block per child with the freshly assigned parent_id.
            \\
            \\On error, recover by: (1) verify `page_id` from a fresh `set_design_page` call; (2) verify each child_id appears in the same `set_design_page` response (and is not already nested in another group); (3) ensure at least 2 children are selected.
        ,
        .parameters = .{
            .type = "object",
            .properties = &.{
                .{
                    .name = "page_id",
                    .type = "string",
                    .description = "The page id (NOT the item_id). Find it in the `id=\"...\"` attribute of a previous `set_design_page` response. All children must live on this page.",
                },
                .{
                    .name = "child_ids",
                    .type = "array",
                    .description = "List of 2+ element ids to group together. Each id must reference an element on `page_id`, and none may already be parented. Discover ids via `set_design_page` (each `<element id=\"...\">` block).",
                },
                .{
                    .name = "name",
                    .type = "string",
                    .description = "Name for the new parent element (optional). Defaults to \"Group\". Must be unique within the page.",
                },
                .{
                    .name = "type",
                    .type = "string",
                    .description = "Parent type (optional): \"group\" (non-clipping container, the default) or \"frame\" (clipping container).",
                },
            },
            .required = &.{ "page_id", "child_ids" },
        },
    },
};

/// Escape XML special characters. Mirrors the helper in
/// `update_design_element.zig` (duplicated locally to keep this tool
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

/// Generate an error XML response. The error body is wrapped in
/// `<group_elements><error>...</error></group_elements>` so the tool
/// dispatcher can detect it via `<error>` substring search.
pub fn errorXml(allocator: std.mem.Allocator, error_msg: []const u8) ![]u8 {
    var xml: std.ArrayList(u8) = .empty;
    errdefer xml.deinit(allocator);

    try xml.appendSlice(allocator, "<group_elements><error>");
    const escaped = try xmlEscape(allocator, error_msg);
    defer allocator.free(escaped);
    try xml.appendSlice(allocator, escaped);
    try xml.appendSlice(allocator, "</error></group_elements>");
    return try xml.toOwnedSlice(allocator);
}

/// Same as `errorXml` but TAKES OWNERSHIP of `error_msg` and frees it.
pub fn errorXmlOwned(allocator: std.mem.Allocator, error_msg: []u8) ![]u8 {
    defer allocator.free(error_msg);

    var xml: std.ArrayList(u8) = .empty;
    errdefer xml.deinit(allocator);

    try xml.appendSlice(allocator, "<group_elements><error>");
    const escaped = try xmlEscape(allocator, error_msg);
    defer allocator.free(escaped);
    try xml.appendSlice(allocator, escaped);
    try xml.appendSlice(allocator, "</error></group_elements>");
    return try xml.toOwnedSlice(allocator);
}

/// Parse the optional `type` string into an `ElementType` enum.
/// Returns null when the string is null (use the default); returns
/// the parsed enum on success. The string is restricted to
/// `"group" | "frame"` — any other value, including the 4 leaf types
/// (rectangle, ellipse, text, image), is rejected with
/// `error.InvalidGroupType`.
fn parseOptionalGroupType(type_str: ?[]const u8) !?design_model.ElementType {
    const t = type_str orelse return null;
    if (std.mem.eql(u8, t, "group")) return .group;
    if (std.mem.eql(u8, t, "frame")) return .frame;
    return error.InvalidGroupType;
}

/// Validate `page_id` is non-empty and has the right `page_`
/// prefix. Returns null when shape is correct, or an error XML on
/// mismatch.
fn validatePageIdShape(allocator: std.mem.Allocator, page_id: []const u8) !?[]u8 {
    if (page_id.len == 0) {
        return try errorXml(allocator, "page_id is required (find it in the `id=\"...\"` attribute of a previous set_design_page response)");
    }
    if (std.mem.startsWith(u8, page_id, "item_")) {
        return try errorXmlOwned(allocator, try std.fmt.allocPrint(allocator,
            \\page_id '{s}' looks like an ITEM id (starts with 'item_'). Pass the PAGE id instead — find it in the `id="..."` attribute of a `set_design_page` response.
        , .{page_id}));
    }
    if (std.mem.startsWith(u8, page_id, "elem_")) {
        return try errorXmlOwned(allocator, try std.fmt.allocPrint(allocator,
            \\page_id '{s}' looks like an ELEMENT id (starts with 'elem_'). Pass the PAGE id instead.
        , .{page_id}));
    }
    if (!std.mem.startsWith(u8, page_id, "page_")) {
        return try errorXmlOwned(allocator, try std.fmt.allocPrint(allocator,
            \\page_id '{s}' has an unrecognized prefix (expected 'page_'). group_elements expects a page_id from a previous set_design_page response.
        , .{page_id}));
    }
    return null;
}

/// Validate `child_ids` is non-empty, has at least 2 elements, and
/// every entry has the right `elem_` prefix. Returns null when shape
/// is correct, or an error XML on mismatch.
fn validateChildIdsShape(allocator: std.mem.Allocator, child_ids: []const []const u8) !?[]u8 {
    if (child_ids.len == 0) {
        return try errorXml(allocator, "child_ids is required and must contain at least 2 element ids (a single-element group is not meaningful)");
    }
    if (child_ids.len < 2) {
        return try errorXmlOwned(allocator, try std.fmt.allocPrint(allocator,
            \\child_ids must contain at least 2 element ids (got {d}). Select more elements before grouping.
        , .{child_ids.len}));
    }
    for (child_ids) |cid| {
        if (cid.len == 0) {
            return try errorXml(allocator, "child_ids contains an empty string; every entry must be a non-empty element id");
        }
        if (std.mem.startsWith(u8, cid, "page_")) {
            return try errorXmlOwned(allocator, try std.fmt.allocPrint(allocator,
                \\child_ids entry '{s}' looks like a PAGE id (starts with 'page_'). Pass the ELEMENT id instead — find it in the `id="..."` attribute of an `<element>` block in a `set_design_page` response.
            , .{cid}));
        }
        if (std.mem.startsWith(u8, cid, "item_")) {
            return try errorXmlOwned(allocator, try std.fmt.allocPrint(allocator,
                \\child_ids entry '{s}' looks like an ITEM id (starts with 'item_'). Pass the ELEMENT id instead.
            , .{cid}));
        }
        if (!std.mem.startsWith(u8, cid, "elem_")) {
            return try errorXmlOwned(allocator, try std.fmt.allocPrint(allocator,
                \\child_ids entry '{s}' has an unrecognized prefix (expected 'elem_'). group_elements expects element ids from a previous set_design_page response.
            , .{cid}));
        }
    }
    return null;
}

/// Render the parent element XML block. Same shape as
/// `add_design_element.elementToXml` but scoped to the parent fields
/// the LLM needs (id, name, type, geometry + parent_id which is
/// always empty for the new root parent).
fn parentToXml(allocator: std.mem.Allocator, elem: design_model.DesignElement) ![]u8 {
    var xml: std.ArrayList(u8) = .empty;
    errdefer xml.deinit(allocator);

    try xml.appendSlice(allocator, "<parent");

    const eid = try xmlEscape(allocator, elem.id);
    defer allocator.free(eid);
    try xml.appendSlice(allocator, " id=\"");
    try xml.appendSlice(allocator, eid);
    try xml.appendSlice(allocator, "\"");

    const ename = try xmlEscape(allocator, elem.name);
    defer allocator.free(ename);
    try xml.appendSlice(allocator, " name=\"");
    try xml.appendSlice(allocator, ename);
    try xml.appendSlice(allocator, "\"");

    const etype = try xmlEscape(allocator, elem.elem_type);
    defer allocator.free(etype);
    try xml.appendSlice(allocator, " type=\"");
    try xml.appendSlice(allocator, etype);
    try xml.appendSlice(allocator, "\"");

    try appendIntAttr(&xml, allocator, "x", elem.x);
    try appendIntAttr(&xml, allocator, "y", elem.y);
    try appendIntAttr(&xml, allocator, "width", elem.width);
    try appendIntAttr(&xml, allocator, "height", elem.height);

    // The new parent is a top-level element — parent_id is always
    // empty for the root. Render as an explicit empty attribute so
    // the LLM can see it.
    try xml.appendSlice(allocator, " parent_id=\"\"");

    try xml.appendSlice(allocator, "/>");
    return try xml.toOwnedSlice(allocator);
}

/// Render a single child block. Minimal shape (id, name, parent_id)
/// — the LLM doesn't need the child's geometry here because that
/// information is unchanged by the grouping operation (the child's
/// x/y/width/height are preserved on disk; the parent is just a new
/// container around them).
fn childToXml(allocator: std.mem.Allocator, elem: design_model.DesignElement) ![]u8 {
    var xml: std.ArrayList(u8) = .empty;
    errdefer xml.deinit(allocator);

    try xml.appendSlice(allocator, "<child");

    const eid = try xmlEscape(allocator, elem.id);
    defer allocator.free(eid);
    try xml.appendSlice(allocator, " id=\"");
    try xml.appendSlice(allocator, eid);
    try xml.appendSlice(allocator, "\"");

    const ename = try xmlEscape(allocator, elem.name);
    defer allocator.free(ename);
    try xml.appendSlice(allocator, " name=\"");
    try xml.appendSlice(allocator, ename);
    try xml.appendSlice(allocator, "\"");

    if (elem.parent_id.len > 0) {
        const epid = try xmlEscape(allocator, elem.parent_id);
        defer allocator.free(epid);
        try xml.appendSlice(allocator, " parent_id=\"");
        try xml.appendSlice(allocator, epid);
        try xml.appendSlice(allocator, "\"");
    } else {
        try xml.appendSlice(allocator, " parent_id=\"\"");
    }

    try xml.appendSlice(allocator, "/>");
    return try xml.toOwnedSlice(allocator);
}

fn appendIntAttr(
    xml: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    name: []const u8,
    value: i64,
) !void {
    var buf: [32]u8 = undefined;
    const str = std.fmt.bufPrint(&buf, "{d}", .{value}) catch "0";
    try xml.appendSlice(allocator, " ");
    try xml.appendSlice(allocator, name);
    try xml.appendSlice(allocator, "=\"");
    try xml.appendSlice(allocator, str);
    try xml.appendSlice(allocator, "\"");
}

/// Execute the `group_elements` tool. Returns an XML string for the
/// LLM.
///
/// On success, the response shape is:
/// ```xml
/// <group_elements>
///   <parent id="elem_..." name="..." type="group|frame" x=".." y=".." width=".." height=".." parent_id="" />
///   <child id="elem_..." name="..." parent_id="elem_NEW_ID" />
///   ...
/// </group_elements>
/// ```
///
/// On error, the response is wrapped in
/// `<group_elements><error>...</error></group_elements>`.
pub fn executeGroupElementsToString(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    input: GroupElementsInput,
) ![]u8 {
    // 0. Input validation (shape only — DB validation runs after).
    if (try validatePageIdShape(allocator, input.page_id)) |e| return e;
    if (try validateChildIdsShape(allocator, input.child_ids)) |e| return e;

    // 1. Parse the optional type string. parseOptionalGroupType
    //    returns:
    //      null → "use default" (string was null) → caller applies .group
    //      enum value → parsed successfully
    //      error.InvalidGroupType → not one of the 2 valid container types
    const parsed_type = parseOptionalGroupType(input.type) catch |err| {
        if (err == error.InvalidGroupType) {
            return try errorXml(allocator,
                "type must be one of: group, frame");
        }
        return try errorXmlOwned(allocator, try std.fmt.allocPrint(allocator, "DB: parseOptionalGroupType failed: {s}", .{@errorName(err)}));
    };

    // 2. Apply the Figma defaults (name="Group", type=group).
    const parent_name: []const u8 = if (input.name) |n| (if (n.len == 0) "Group" else n) else "Group";
    const parent_type: design_model.ElementType = parsed_type orelse .group;

    // 3. Call groupElements. Returns the new element_id on success;
    //    errors are mapped to wire XML below.
    const new_id = design_model.groupElements(allocator, db, .{
        .page_id = input.page_id,
        .child_ids = input.child_ids,
        .parent_name = parent_name,
        .parent_type = parent_type,
    }) catch |err| switch (err) {
        error.PageNotFound => return try errorXml(allocator, "page_id does not match any design page — call set_design_page first"),
        error.BadChildId => return try errorXmlOwned(allocator, try std.fmt.allocPrint(allocator, "child_id is invalid — one of the child_ids ({s}) does not match any design element. Re-fetch the page via set_design_page to get fresh ids.", .{input.child_ids[0]})),
        error.ChildAcrossDifferentPages => return try errorXml(allocator, "one of the child_ids lives on a different page than page_id. All children must be on the same page as the new parent"),
        error.ChildAlreadyParented => return try errorXml(allocator, "one of the child_ids is already parented to another group or frame. group_elements does not support nested re-parenting in the first cut"),
        error.ItemPathMissing => return try errorXml(allocator, "the design item has no path; set one via the design item dialog"),
        error.FileWriteFailed => return try errorXml(allocator, "could not write the group HTML file to disk (permission denied or out of space)"),
        else => return try errorXmlOwned(allocator, try std.fmt.allocPrint(allocator, "DB: groupElements failed: {s}", .{@errorName(err)})),
    };
    defer allocator.free(new_id);

    // 4. Re-fetch the parent + each reparented child so the response
    //    carries the canonical state (with timestamps + parent_id).
    const parent = design_model.getElement(allocator, db, new_id) catch |err| {
        return try errorXmlOwned(allocator, try std.fmt.allocPrint(allocator, "DB: getElement(parent) failed: {s}", .{@errorName(err)}));
    };
    defer design_model.freeElement(allocator, parent);

    var xml: std.ArrayList(u8) = .empty;
    errdefer xml.deinit(allocator);

    try xml.appendSlice(allocator, "<group_elements>");
    const parent_xml = try parentToXml(allocator, parent);
    defer allocator.free(parent_xml);
    try xml.appendSlice(allocator, parent_xml);

    for (input.child_ids) |cid| {
        const child = design_model.getElement(allocator, db, cid) catch |err| {
            return try errorXmlOwned(allocator, try std.fmt.allocPrint(allocator, "DB: getElement(child='{s}') failed: {s}", .{ cid, @errorName(err) }));
        };
        defer design_model.freeElement(allocator, child);
        const child_xml = try childToXml(allocator, child);
        defer allocator.free(child_xml);
        try xml.appendSlice(allocator, child_xml);
    }

    try xml.appendSlice(allocator, "</group_elements>");
    return try xml.toOwnedSlice(allocator);
}
