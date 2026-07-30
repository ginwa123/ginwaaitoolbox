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
