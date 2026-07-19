//! LLM tool: `update_element` — partial-update an existing element on a
//! design page. Only fields that are explicitly set (non-null) are
//! updated in the SQL UPDATE; null fields are left unchanged.
//!
//! If `html` is set, the element's on-disk HTML file is rewritten
//! atomically. If the file is missing (orphan), `updateElement` will
//! recreate it via the JOIN chain (design_page_elements → design_pages
//! → workspace_items) — see design_model.zig `updateElement` for the
//! recovery logic.
//!
//! Plan: docs/superpowers/plans/2026-07-08-design-mode-redesign.md (Chunk 4)
//! Design: docs/plans/2026-07-08-design-mode-redesign-design.md §6.3

const std = @import("std");
const schemas = @import("schemas.zig");
const AgentTool = schemas.AgentTool;
const nalarcore = @import("nalarcore");
const sqlite = nalarcore.sqlite;
const design_model = nalarcore.ai_mod.design_model;

/// Input structure for `update_element` tool.
///
/// ALL fields except `element_id` are optional. When a field is set
/// (non-null), the corresponding column is updated in the SQL
/// UPDATE; null fields are left unchanged. The `type` field is a
/// string that gets parsed to `ElementType` enum (same as
/// `add_element`); null means "leave type unchanged".
pub const UpdateElementInput = struct {
    /// The element id (NOT the page_id). The LLM discovers element
    /// ids via `set_design_page` (the response includes the element
    /// ids in each `<element id="...">` block).
    element_id: []const u8 = "",
    /// New name (optional). Must be unique within the page if changed.
    name: ?[]const u8 = null,
    /// New element type (optional). One of: rectangle, ellipse, text,
    /// image, frame, group. Null = no change.
    type: ?[]const u8 = null,
    /// New HTML body (optional). When set, the on-disk file at
    /// `file_path` is rewritten atomically. If the file doesn't
    /// exist (orphan), it's recreated.
    html: ?[]const u8 = null,
    /// New X position (optional).
    x: ?i64 = null,
    /// New Y position (optional).
    y: ?i64 = null,
    /// New width (optional).
    width: ?i64 = null,
    /// New height (optional).
    height: ?i64 = null,
    /// New rotation in degrees (optional).
    rotation: ?f64 = null,
    /// New fill color (optional). Empty string means "use default"
    /// (no fill) — same as add_element's behavior.
    fill: ?[]const u8 = null,
    /// New stroke color (optional).
    stroke: ?[]const u8 = null,
    /// New stroke width in pixels (optional).
    stroke_width: ?i64 = null,
    /// New corner radius in pixels (optional, rectangle only).
    corner_radius: ?i64 = null,
    /// New opacity 0.0–1.0 (optional).
    opacity: ?f64 = null,
    /// New text content (optional, for type='text').
    text_content: ?[]const u8 = null,
    /// New text style JSON (optional, for type='text').
    text_style: ?[]const u8 = null,
    /// New image URL (optional, for type='image').
    image_url: ?[]const u8 = null,
    /// Re-parent the element. Semantics:
    ///   - `null` (omitted) — leave parent unchanged.
    ///   - empty string `""` — DETACH (set DB column NULL). The
    ///     element becomes top-level.
    ///   - non-empty string — set parent_id to that value. The
    ///     target must exist on the same page, be of type `frame` or
    ///     `group`, and not be a descendant of this element. Set
    ///     `parent_id = element_id` (self) is rejected.
    parent_id: ?[]const u8 = null,
};

/// Top-level tool definition for the LLM.
///
/// The description emphasizes that ALL fields except `element_id`
/// are optional, and that `set_design_page` is the way to discover
/// element ids (no separate list tool exists).
pub const update_design_element_tool = AgentTool{
    .type = "function",
    .function = .{
        .name = "update_element",
        .description =
            \\Partially update an existing element on a design page. ALL fields except `element_id` are OPTIONAL — only the fields you provide are updated; everything else is left unchanged.
            \\
            \\This is the tool for moving an element (`x`/`y`), resizing (`width`/`height`), changing properties (fill/rotation/opacity/corner_radius), changing the type, or rewriting the HTML body. For visual layout tweaks, you usually only need to set `x`, `y`, `width`, `height`.
            \\
            \\Discover the `element_id` via `set_design_page` — the response includes element ids in each `<element id="...">` attribute.
            \\
            \\If you set `html`, the on-disk HTML file at the element's `file_path` is rewritten atomically. If the file is missing (orphan), it's recreated automatically.
            \\
            \\Setting `fill` to an empty string "" is treated as "use the default (no fill)" — same as `add_element`.
            \\
            \\Returns the full updated element XML (same shape as `add_element`'s response, omits the html body to keep it compact).
            \\
            \\On error, recover by: (1) verify `element_id` from a fresh `set_design_page` call; (2) if you set `name`, ensure the new name is unique within the page (use `set_design_page` to check).
        ,
        .parameters = .{
            .type = "object",
            .properties = &.{
                .{
                    .name = "element_id",
                    .type = "string",
                    .description = "The element id (NOT the page_id). Find it in the `id=\"...\"` attribute of an `<element>` block in a previous `set_design_page` response.",
                },
                .{
                    .name = "name",
                    .type = "string",
                    .description = "New name (optional). Must be unique within the page if changed.",
                },
                .{
                    .name = "type",
                    .type = "string",
                    .description = "New element type (optional): one of 'rectangle', 'ellipse', 'text', 'image', 'frame', 'group'.",
                },
                .{
                    .name = "html",
                    .type = "string",
                    .description = "New HTML body (optional). Triggers atomic file rewrite at file_path. Orphan files are recreated.",
                },
                .{
                    .name = "x",
                    .type = "integer",
                    .description = "New X position in CSS pixels (optional).",
                },
                .{
                    .name = "y",
                    .type = "integer",
                    .description = "New Y position in CSS pixels (optional).",
                },
                .{
                    .name = "width",
                    .type = "integer",
                    .description = "New width in CSS pixels (optional).",
                },
                .{
                    .name = "height",
                    .type = "integer",
                    .description = "New height in CSS pixels (optional).",
                },
                .{
                    .name = "rotation",
                    .type = "number",
                    .description = "New rotation in degrees (optional).",
                },
                .{
                    .name = "fill",
                    .type = "string",
                    .description = "New fill color (optional). Empty string = no fill.",
                },
                .{
                    .name = "stroke",
                    .type = "string",
                    .description = "New stroke color (optional).",
                },
                .{
                    .name = "stroke_width",
                    .type = "integer",
                    .description = "New stroke width in pixels (optional).",
                },
                .{
                    .name = "corner_radius",
                    .type = "integer",
                    .description = "New corner radius in pixels (optional, rectangle only).",
                },
                .{
                    .name = "opacity",
                    .type = "number",
                    .description = "New opacity 0.0–1.0 (optional).",
                },
                .{
                    .name = "text_content",
                    .type = "string",
                    .description = "New text content (optional, for type='text').",
                },
                .{
                    .name = "text_style",
                    .type = "string",
                    .description = "New text style as JSON (optional).",
                },
                .{
                    .name = "image_url",
                    .type = "string",
                    .description = "New image URL (optional, for type='image').",
                },
                .{
                    .name = "parent_id",
                    .type = "string",
                    .description = "Re-parent the element. Empty string '' DETACHES the element (clears its parent_id). Omit (or pass null) to leave parent unchanged. To re-parent, pass the new parent's element id (must be of type 'frame' or 'group' and on the same page).",
                },
            },
            .required = &.{"element_id"},
        },
    },
};

/// Escape XML special characters. Mirrors the helper in
/// kanban_list.zig / set_design_page.zig / add_design_element.zig
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
/// `<update_element><error>...</error></update_element>` so the tool
/// dispatcher can detect it via `<error>` substring search.
pub fn errorXml(allocator: std.mem.Allocator, error_msg: []const u8) ![]u8 {
    var xml: std.ArrayList(u8) = .empty;
    errdefer xml.deinit(allocator);

    try xml.appendSlice(allocator, "<update_element><error>");
    const escaped = try xmlEscape(allocator, error_msg);
    defer allocator.free(escaped);
    try xml.appendSlice(allocator, escaped);
    try xml.appendSlice(allocator, "</error></update_element>");
    return try xml.toOwnedSlice(allocator);
}

/// Same as `errorXml` but TAKES OWNERSHIP of `error_msg` and frees it.
pub fn errorXmlOwned(allocator: std.mem.Allocator, error_msg: []u8) ![]u8 {
    defer allocator.free(error_msg);

    var xml: std.ArrayList(u8) = .empty;
    errdefer xml.deinit(allocator);

    try xml.appendSlice(allocator, "<update_element><error>");
    const escaped = try xmlEscape(allocator, error_msg);
    defer allocator.free(escaped);
    try xml.appendSlice(allocator, escaped);
    try xml.appendSlice(allocator, "</error></update_element>");
    return try xml.toOwnedSlice(allocator);
}

/// Render the canonical "element" XML response shape (same as
/// `add_design_element.elementToXml` — kept local so each tool file
/// is self-contained).
pub fn elementToXml(
    allocator: std.mem.Allocator,
    elem: design_model.DesignElement,
) ![]u8 {
    var xml: std.ArrayList(u8) = .empty;
    errdefer xml.deinit(allocator);

    try xml.appendSlice(allocator, "<element");

    const eid = try xmlEscape(allocator, elem.id);
    defer allocator.free(eid);
    try xml.appendSlice(allocator, " id=\"");
    try xml.appendSlice(allocator, eid);
    try xml.appendSlice(allocator, "\"");

    const epid = try xmlEscape(allocator, elem.page_id);
    defer allocator.free(epid);
    try xml.appendSlice(allocator, " page_id=\"");
    try xml.appendSlice(allocator, epid);
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
    try appendFloatAttr(&xml, allocator, "rotation", elem.rotation);
    try appendFloatAttr(&xml, allocator, "opacity", elem.opacity);
    try appendIntAttr(&xml, allocator, "corner_radius", elem.corner_radius);

    if (elem.fill.len > 0) {
        const v = try xmlEscape(allocator, elem.fill);
        defer allocator.free(v);
        try xml.appendSlice(allocator, " fill=\"");
        try xml.appendSlice(allocator, v);
        try xml.appendSlice(allocator, "\"");
    }
    if (elem.stroke.len > 0) {
        const v = try xmlEscape(allocator, elem.stroke);
        defer allocator.free(v);
        try xml.appendSlice(allocator, " stroke=\"");
        try xml.appendSlice(allocator, v);
        try xml.appendSlice(allocator, "\"");
    }
    if (elem.text_content.len > 0) {
        const v = try xmlEscape(allocator, elem.text_content);
        defer allocator.free(v);
        try xml.appendSlice(allocator, " text_content=\"");
        try xml.appendSlice(allocator, v);
        try xml.appendSlice(allocator, "\"");
    }
    if (elem.text_style.len > 0) {
        const v = try xmlEscape(allocator, elem.text_style);
        defer allocator.free(v);
        try xml.appendSlice(allocator, " text_style=\"");
        try xml.appendSlice(allocator, v);
        try xml.appendSlice(allocator, "\"");
    }
    if (elem.image_url.len > 0) {
        const v = try xmlEscape(allocator, elem.image_url);
        defer allocator.free(v);
        try xml.appendSlice(allocator, " image_url=\"");
        try xml.appendSlice(allocator, v);
        try xml.appendSlice(allocator, "\"");
    }
    if (elem.parent_id) |pid| {
        if (pid.len > 0) {
            const v = try xmlEscape(allocator, pid);
            defer allocator.free(v);
            try xml.appendSlice(allocator, " parent_id=\"");
            try xml.appendSlice(allocator, v);
            try xml.appendSlice(allocator, "\"");
        }
    }
    if (elem.file_path.len > 0) {
        const v = try xmlEscape(allocator, elem.file_path);
        defer allocator.free(v);
        try xml.appendSlice(allocator, " file_path=\"");
        try xml.appendSlice(allocator, v);
        try xml.appendSlice(allocator, "\"");
    }

    try xml.appendSlice(allocator, " created_at=\"");
    try xml.appendSlice(allocator, elem.created_at);
    try xml.appendSlice(allocator, "\" updated_at=\"");
    try xml.appendSlice(allocator, elem.updated_at);
    try xml.appendSlice(allocator, "\" />");

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

fn appendFloatAttr(
    xml: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    name: []const u8,
    value: f64,
) !void {
    var buf: [64]u8 = undefined;
    const str = std.fmt.bufPrint(&buf, "{d:.6}", .{value}) catch "0";
    try xml.appendSlice(allocator, " ");
    try xml.appendSlice(allocator, name);
    try xml.appendSlice(allocator, "=\"");
    try xml.appendSlice(allocator, str);
    try xml.appendSlice(allocator, "\"");
}

/// Parse the optional `type` string into an `ElementType` enum.
/// Returns null when the string is null (no change), or an error XML
/// when the string is non-null but not one of the 6 valid types.
fn parseOptionalElementType(_: std.mem.Allocator, type_str: ?[]const u8) !?design_model.ElementType {
    const t = type_str orelse return null;
    if (std.mem.eql(u8, t, "rectangle")) return .rectangle;
    if (std.mem.eql(u8, t, "ellipse")) return .ellipse;
    if (std.mem.eql(u8, t, "text")) return .text;
    if (std.mem.eql(u8, t, "image")) return .image;
    if (std.mem.eql(u8, t, "frame")) return .frame;
    if (std.mem.eql(u8, t, "group")) return .group;
    return error.BadTypeString;
}

/// Validate `element_id` is non-empty and has the right `elem_`
/// prefix. Returns null when shape is correct, or an error XML on
/// mismatch.
fn validateElementIdShape(allocator: std.mem.Allocator, element_id: []const u8) !?[]u8 {
    if (element_id.len == 0) {
        return try errorXml(allocator, "element_id is required (find it in the `id=\"...\"` attribute of an `<element>` block in a previous set_design_page response)");
    }
    if (std.mem.startsWith(u8, element_id, "item_")) {
        return try errorXmlOwned(allocator, try std.fmt.allocPrint(allocator,
            \\element_id '{s}' looks like an ITEM id (starts with 'item_'). Pass the ELEMENT id instead — find it in the `id="..."` attribute of an `<element>` block in a `set_design_page` response.
        , .{element_id}));
    }
    if (std.mem.startsWith(u8, element_id, "page_")) {
        return try errorXmlOwned(allocator, try std.fmt.allocPrint(allocator,
            \\element_id '{s}' looks like a PAGE id (starts with 'page_'). Pass the ELEMENT id instead.
        , .{element_id}));
    }
    if (!std.mem.startsWith(u8, element_id, "elem_")) {
        return try errorXmlOwned(allocator, try std.fmt.allocPrint(allocator,
            \\element_id '{s}' has an unrecognized prefix (expected 'elem_'). update_element expects an element_id from a previous set_design_page response, not a free-form string.
        , .{element_id}));
    }
    return null;
}

/// Execute the `update_element` tool. Returns an XML string for the
/// LLM.
///
/// On success, the response shape is the same as `add_element`'s
/// `<element .../>` block (without the wrapping `<page>...</page>`).
///
/// On error (bad element_id, bad type, DB failure), the response is
/// wrapped in `<update_element><error>...</error></update_element>`.
pub fn executeUpdateElementToString(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    input: UpdateElementInput,
) ![]u8 {
    // 0. Input validation (shape only — DB validation runs after).
    if (try validateElementIdShape(allocator, input.element_id)) |e| return e;

    // 1. Parse the optional type string. parseOptionalElementType
    //    returns:
    //      null → "no change" (string was null)
    //      enum value → parsed successfully
    //      error.BadTypeString → malformed string (not one of the 6)
    const parsed_type = parseOptionalElementType(allocator, input.type) catch |err| {
        if (err == error.BadTypeString) {
            return try errorXml(allocator,
                "type must be one of: rectangle, ellipse, text, image, frame, group");
        }
        return try errorXmlOwned(allocator, try std.fmt.allocPrint(allocator, "DB: parseOptionalElementType failed: {s}", .{@errorName(err)}));
    };

    // 2. Apply the same fill workaround as add_element: empty fill
    //    string would bind as NULL and violate the v6 NOT NULL
    //    constraint on the `fill` column. Substitute "transparent".
    const fill_for_db: ?[]const u8 = if (input.fill) |f| blk: {
        break :blk if (f.len == 0) @as([]const u8, "transparent") else f;
    } else null;

    // 3. Call updateElement. Returns the element_id on success;
    //    returns ElementNotFound if no such row exists.
    const element_id = design_model.updateElement(allocator, db, .{
        .element_id = input.element_id,
        .name = input.name,
        .elem_type = parsed_type,
        .html = input.html,
        .x = input.x,
        .y = input.y,
        .width = input.width,
        .height = input.height,
        .rotation = input.rotation,
        .fill = fill_for_db,
        .stroke = input.stroke,
        .stroke_width = input.stroke_width,
        .corner_radius = input.corner_radius,
        .opacity = input.opacity,
        .text_content = input.text_content,
        .text_style = input.text_style,
        .image_url = input.image_url,
        .parent_id = input.parent_id,
    }) catch |err| switch (err) {
        error.ElementNotFound => return try errorXml(allocator, "element_id does not match any design element — call set_design_page first"),
        error.FileWriteFailed => return try errorXml(allocator, "could not write the HTML file to disk (permission denied or out of space)"),
        error.InvalidParent => return try errorXml(allocator, "parent_id must reference an existing 'frame' or 'group' on the same page (or be empty string to detach). Self-parenting or creating a cycle is rejected."),
        else => return try errorXmlOwned(allocator, try std.fmt.allocPrint(allocator, "DB: updateElement failed: {s}", .{@errorName(err)})),
    };
    defer allocator.free(element_id);

    // 4. Re-fetch the full element via getElement so the LLM gets
    //    the canonical state (with file_path, timestamps, etc.).
    const elem = design_model.getElement(allocator, db, element_id) catch |err| {
        return try errorXmlOwned(allocator, try std.fmt.allocPrint(allocator, "DB: getElement failed: {s}", .{@errorName(err)}));
    };
    defer design_model.freeElement(allocator, elem);

    return try elementToXml(allocator, elem);
}