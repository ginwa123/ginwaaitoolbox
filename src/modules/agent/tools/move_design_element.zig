//! LLM tool: `move_design_element` — translates an existing design
//! element by a `(dx, dy)` delta. When `apply_to_children = true`
//! (the default), the delta cascades to every transitive descendant
//! of the element via the backend's recursive CTE in one SQL
//! transaction — so the LLM can say "move Group 2 by 50 right" and
//! every nested child follows (Figma parity).
//!
//! Optional `width` / `height` / `rotation` apply ONLY to the root
//! element (resize is per-element, Figma convention).
//!
//! Plan: docs/superpowers/plans/2026-08-06-move-element-with-descendants.md
//! (Chunk 5, Task 5.1)

const std = @import("std");
const schemas = @import("schemas.zig");
const AgentTool = schemas.AgentTool;
const nalarcore = @import("nalarcore");
const sqlite = nalarcore.sqlite;
const design_model = nalarcore.ai_mod.design_model;

/// Input structure for `move_design_element` tool.
///
/// All fields except `element_id`, `dx`, `dy` are optional.
/// - `apply_to_children` defaults to `true` — matches the user's
///   "move element parent will be move all child" mental model.
///   Pass `false` to move a single element only (rare — used for
///   "I want to move a leaf out from inside a group without taking
///   the group with it").
/// - `width` / `height` / `rotation` apply ONLY to the root element
///   when `apply_to_children = true` — they never cascade.
pub const MoveDesignElementInput = struct {
    /// The element id to translate. Must exist on the active page.
    element_id: []const u8 = "",
    /// X translation delta (design-px). Cascades to descendants when
    /// `apply_to_children = true`.
    dx: i64 = 0,
    /// Y translation delta (design-px). Cascades to descendants when
    /// `apply_to_children = true`.
    dy: i64 = 0,
    /// Optional. Applies ONLY to the root element (not descendants).
    width: ?i64 = null,
    height: ?i64 = null,
    rotation: ?f64 = null,
    /// Default true. Pass false to move a single element only (skip
    /// the backend's recursive CTE cascade).
    apply_to_children: bool = true,
};

/// Top-level tool definition for the LLM.
pub const move_design_element_tool = AgentTool{
    .type = "function",
    .function = .{
        .name = "move_design_element",
        .description =
            \\Translate an existing design element by a (dx, dy) delta in one atomic batch PATCH. When apply_to_children=true (the default), the delta cascades to every transitive descendant of the element — so moving a `group`/`frame` moves the whole subtree (Figma parity). Optional width/height/rotation apply ONLY to the root element (resize is per-element, Figma convention).
            \\
            \\The element_id must reference an element on the active page. The dx/dy is mandatory (zero is valid for a pure resize). Pass apply_to_children=false to move a single element WITHOUT cascading to its children (rare — e.g. "I want to move a leaf out from inside a group without taking the group with it").
            \\
            \\Discover ids via `set_design_page` — each `<element id="...">` block carries the id.
            \\
            \\On error, recover by: (1) verify `element_id` from a fresh `set_design_page` call; (2) if dx/dy is huge and the cascade leaves the canvas, use `update_design_element` with explicit x/y values instead.
        ,
        .parameters = .{
            .type = "object",
            .properties = &.{
                .{
                    .name = "element_id",
                    .type = "string",
                    .description = "The element id to translate (NOT a page_id or workspace_id). Find it in the `id=\"...\"` attribute of an `<element>` block in a previous set_design_page response.",
                },
                .{
                    .name = "dx",
                    .type = "number",
                    .description = "X translation delta in design-px. Cascades to descendants when apply_to_children=true.",
                },
                .{
                    .name = "dy",
                    .type = "number",
                    .description = "Y translation delta in design-px. Cascades to descendants when apply_to_children=true.",
                },
                .{
                    .name = "apply_to_children",
                    .type = "boolean",
                    .description = "Default true. When true, the delta cascades to every transitive descendant of the element. Pass false to move a single element only.",
                },
                .{
                    .name = "width",
                    .type = "number",
                    .description = "Optional. New width (root only, never cascades).",
                },
                .{
                    .name = "height",
                    .type = "number",
                    .description = "Optional. New height (root only, never cascades).",
                },
                .{
                    .name = "rotation",
                    .type = "number",
                    .description = "Optional. New rotation in degrees (root only, never cascades).",
                },
            },
            .required = &.{ "element_id", "dx", "dy" },
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
/// `<move_design_element><error>...</error></move_design_element>` so
/// the tool dispatcher can detect it via `<error>` substring search.
pub fn errorXml(allocator: std.mem.Allocator, error_msg: []const u8) ![]u8 {
    var xml: std.ArrayList(u8) = .empty;
    errdefer xml.deinit(allocator);

    try xml.appendSlice(allocator, "<move_design_element><error>");
    const escaped = try xmlEscape(allocator, error_msg);
    defer allocator.free(escaped);
    try xml.appendSlice(allocator, escaped);
    try xml.appendSlice(allocator, "</error></move_design_element>");
    return try xml.toOwnedSlice(allocator);
}

/// Same as `errorXml` but TAKES OWNERSHIP of `error_msg` and frees it.
pub fn errorXmlOwned(allocator: std.mem.Allocator, error_msg: []u8) ![]u8 {
    defer allocator.free(error_msg);

    var xml: std.ArrayList(u8) = .empty;
    errdefer xml.deinit(allocator);

    try xml.appendSlice(allocator, "<move_design_element><error>");
    const escaped = try xmlEscape(allocator, error_msg);
    defer allocator.free(escaped);
    try xml.appendSlice(allocator, escaped);
    try xml.appendSlice(allocator, "</error></move_design_element>");
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
            \\element_id '{s}' has an unrecognized prefix (expected 'elem_'). move_design_element expects an element id from a previous set_design_page response, not a free-form string.
        , .{element_id}));
    }
    return null;
}

/// Execute the `move_design_element` tool. Returns an XML string for
/// the LLM.
///
/// The tool supports two modes:
/// - `apply_to_children = true` (default): calls
///   `design_model.moveElementsWithDescendantsBatch` which cascades
///   the (dx, dy) delta to every transitive descendant of
///   `element_id` in one SQL transaction.
/// - `apply_to_children = false`: calls `design_model.setElementParent`'s
///   single-element translation via the existing
///   `updateElement` path with explicit x/y values. Less common —
///   used when the LLM wants to move a leaf out from inside a
///   group without taking the group with it.
///
/// On success, the response shape is:
/// ```xml
/// <move_design_element>
///   <updated>...elements...</updated>
/// </move_design_element>
/// ```
/// where `<updated>` contains the cascaded element ids.
///
/// On error, the response is wrapped in
/// `<move_design_element><error>...</error></move_design_element>`.
pub fn executeMoveDesignElementToString(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    input: MoveDesignElementInput,
) ![]u8 {
    // 0. Input validation (shape only — DB validation runs after).
    if (try validateElementIdShape(allocator, input.element_id)) |e| return e;

    // 1. Read the element's current position (always required — even
    //    when apply_to_children=false, the per-element path needs the
    //    OLD x/y to compute the new x/y).
    const current = design_model.getElement(allocator, db, input.element_id) catch |err| {
        return switch (err) {
            error.ElementNotFound => try errorXml(allocator, "element_id does not reference any design element — call set_design_page first"),
            else => try errorXmlOwned(allocator, try std.fmt.allocPrint(allocator, "DB: getElement failed: {s}", .{@errorName(err)})),
        };
    };
    defer design_model.freeElement(allocator, current);

    // 2a. Cascade path (default). Build a single-item batch for the
    //     recursive CTE.
    if (input.apply_to_children) {
        const item = design_model.MoveItem{
            .element_id = input.element_id,
            .dx = input.dx,
            .dy = input.dy,
            .width = input.width,
            .height = input.height,
            .rotation = input.rotation,
        };
        const items = [_]design_model.MoveItem{item};

        // We need the page_id for the cascade — fetch it from the row
        // we already have in `current`.
        const updated = design_model.moveElementsWithDescendantsBatch(allocator, db, .{
            .page_id = current.page_id,
            .items = &items,
        }) catch |err| {
            return switch (err) {
                error.EmptyItems => try errorXml(allocator, "items array was empty (this is an internal error — should not happen with a single item)"),
                error.ElementNotFound => try errorXml(allocator, "element_id does not reference any design element — call set_design_page first"),
                error.PageNotFound => try errorXml(allocator, "page_id does not reference any design page (this is an internal error — the page should exist if the element exists)"),
                else => try errorXmlOwned(allocator, try std.fmt.allocPrint(allocator, "DB: moveElementsWithDescendantsBatch failed: {s}", .{@errorName(err)})),
            };
        };
        defer allocator.free(updated);
        for (updated) |e| design_model.freeElement(allocator, e);

        return try renderSuccessXml(allocator, updated);
    }

    // 2b. Single-element path (apply_to_children = false). Use the
    //     existing per-element translation by computing the new x/y
    //     from the current x/y + dx/dy.
    const new_x = current.x + input.dx;
    const new_y = current.y + input.dy;

    const inner_id = try design_model.updateElement(allocator, db, .{
        .element_id = input.element_id,
        .x = new_x,
        .y = new_y,
        .width = input.width,
        .height = input.height,
        .rotation = input.rotation,
    });
    defer allocator.free(inner_id);

    // Re-fetch the element to confirm the new state.
    const after = design_model.getElement(allocator, db, input.element_id) catch |err| {
        return try errorXmlOwned(allocator, try std.fmt.allocPrint(allocator, "DB: getElement failed: {s}", .{@errorName(err)}));
    };
    defer design_model.freeElement(allocator, after);

    const single: []const design_model.DesignElement = &[_]design_model.DesignElement{after};
    return try renderSuccessXml(allocator, single);
}

/// Render the success XML response. Lists every cascaded element id
/// + their new x/y. Heap-borrows the input slice; the caller is
/// responsible for the input's lifetime.
fn renderSuccessXml(
    allocator: std.mem.Allocator,
    updated: []const design_model.DesignElement,
) ![]u8 {
    var xml: std.ArrayList(u8) = .empty;
    errdefer xml.deinit(allocator);

    try xml.appendSlice(allocator, "<move_design_element><updated>");
    for (updated) |e| {
        const id_esc = try xmlEscape(allocator, e.id);
        defer allocator.free(id_esc);
        try xml.appendSlice(allocator, "<element id=\"");
        try xml.appendSlice(allocator, id_esc);
        try xml.appendSlice(allocator, "\" x=\"");
        const x_str = try std.fmt.allocPrint(allocator, "{d}", .{e.x});
        defer allocator.free(x_str);
        try xml.appendSlice(allocator, x_str);
        try xml.appendSlice(allocator, "\" y=\"");
        const y_str = try std.fmt.allocPrint(allocator, "{d}", .{e.y});
        defer allocator.free(y_str);
        try xml.appendSlice(allocator, y_str);
        try xml.appendSlice(allocator, "\"/>");
    }
    try xml.appendSlice(allocator, "</updated></move_design_element>");
    return try xml.toOwnedSlice(allocator);
}
