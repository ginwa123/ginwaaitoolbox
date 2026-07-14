//! LLM tool: `add_element` — creates a new element on a design page.
//!
//! Writes the element's HTML body to disk atomically (under
//! `<workspace_item.path>/.nalar/design/<page>/<element>.html`) and
//! inserts the metadata row in `design_page_elements` with the 11 v6
//! properties from Migration 057.
//!
//! Plan: docs/superpowers/plans/2026-07-08-design-mode-redesign.md (Chunk 4)
//! Design: docs/plans/2026-07-08-design-mode-redesign-design.md §6.2

const std = @import("std");
const schemas = @import("schemas.zig");
const AgentTool = schemas.AgentTool;
const nalarcore = @import("nalarcore");
const sqlite = nalarcore.sqlite;
const design_model = nalarcore.ai_mod.design_model;

/// Input structure for `add_element` tool.
///
/// The agent passes `page_id` (from the `set_design_page` response),
/// the element's `name`, `type`, and `html`. All other fields are
/// optional with sensible defaults (rectangle at origin, 200×100, no
/// fill, no rotation, full opacity).
pub const AddElementInput = struct {
    /// The page id (NOT the item_id). The LLM discovers page_ids
    /// via `set_design_page` (the response includes the page id).
    page_id: []const u8 = "",
    /// Human-readable element name. Must be unique within the page.
    /// Must NOT contain '/' or null bytes (the v6 file-backed model
    /// stores the HTML body at `<page_dir>/<sanitized_name>.html`).
    name: []const u8 = "",
    /// Element type — one of: rectangle, ellipse, text, image, frame,
    /// group. Determines the rendering shape (rectangle = solid
    /// fill box, ellipse = circle/ellipse, text = HTML text node,
    /// image = raster image with image_url, frame = container that
    /// clips its children, group = container that does not clip).
    /// Wire format is the lowercase string; we parse to `ElementType`.
    type: []const u8 = "rectangle",
    /// HTML body. Written to
    /// `<workspace_item.path>/.nalar/design/<page>/<element>.html`.
    /// Required (non-empty) — an empty html would create an
    /// on-disk file with zero bytes that the LLM has to populate
    /// via `update_element` later, so requiring it here forces the
    /// LLM to think about the content up-front.
    html: []const u8 = "",
    /// X position in CSS pixels. Defaults to 0.
    x: ?i64 = null,
    /// Y position in CSS pixels. Defaults to 0.
    y: ?i64 = null,
    /// Width in CSS pixels. Defaults to 200.
    width: ?i64 = null,
    /// Height in CSS pixels. Defaults to 100.
    height: ?i64 = null,
    /// Fill color (CSS color string, e.g. `#ffffff`, `rgba(0,0,0,0.5)`,
    /// `transparent`). Defaults to "" (no fill).
    fill: []const u8 = "",
    /// Rotation in degrees (clockwise). Defaults to 0.
    rotation: ?f64 = null,
    /// Corner radius in CSS pixels (for rectangle only). Defaults to 0.
    corner_radius: ?i64 = null,
    /// Opacity (0.0 = transparent, 1.0 = opaque). Defaults to 1.0.
    opacity: ?f64 = null,
    /// Text content (for `type='text'`). Defaults to "".
    text_content: []const u8 = "",
    /// Text style (JSON-encoded string, e.g.
    /// `{"font":"Inter","size":14}`). Defaults to "".
    text_style: []const u8 = "",
    /// Image URL (for `type='image'`). Defaults to "".
    image_url: []const u8 = "",
};

/// Top-level tool definition for the LLM.
///
/// The description enumerates the 6 valid types, lists the geometry
/// defaults, and tells the LLM that `page_id` comes from a previous
/// `set_design_page` call (NOT from Workspace Context).
pub const add_design_element_tool = AgentTool{
    .type = "function",
    .function = .{
        .name = "add_element",
        .description =
            \\Add a new element to a design page. This creates a positioned visual element with a writable HTML body stored on disk under `<workspace_item.path>/.nalar/design/<page>/<element>.html`.
            \\
            \\The 6 valid element types are: `rectangle` (solid fill box), `ellipse` (circle/ellipse), `text` (HTML text node — set `text_content`), `image` (raster image — set `image_url`), `frame` (container that clips children), `group` (container that does not clip).
            \\
            \\Discover the `page_id` by calling `set_design_page` first — the response includes the page id in the `id="..."` attribute. Element names must be unique within a page; re-issuing with the same name fails with `<error>name must be unique within page; ...</error>`.
            \\
            \\Defaults: x=0, y=0, width=200, height=100, fill="" (no fill), rotation=0, corner_radius=0, opacity=1.0, text_content="", text_style="", image_url="".
            \\
            \\Returns the full element XML (omits the html body to keep the response compact — the body lives at `file_path` which is shown in the response).
            \\
            \\On error, recover by: (1) verify `page_id` from a fresh `set_design_page` call; (2) check the element name is unique within the page (use `set_design_page` to list existing elements); (3) check `type` is one of the 6 valid values.
        ,
        .parameters = .{
            .type = "object",
            .properties = &.{
                .{
                    .name = "page_id",
                    .type = "string",
                    .description = "The page id (NOT the item_id). Find it in the `id=\"...\"` attribute of a previous `set_design_page` response.",
                },
                .{
                    .name = "name",
                    .type = "string",
                    .description = "Human-readable element name (e.g. 'login-card', 'hero-image'). Must be unique within the page. Must NOT contain '/' or null bytes.",
                },
                .{
                    .name = "type",
                    .type = "string",
                    .description = "Element type: one of 'rectangle', 'ellipse', 'text', 'image', 'frame', 'group'.",
                },
                .{
                    .name = "html",
                    .type = "string",
                    .description = "HTML body for the element. Required (non-empty). Written to disk under `<workspace_item.path>/.nalar/design/<page>/<element>.html`.",
                },
                .{
                    .name = "x",
                    .type = "integer",
                    .description = "X position in CSS pixels. Defaults to 0.",
                },
                .{
                    .name = "y",
                    .type = "integer",
                    .description = "Y position in CSS pixels. Defaults to 0.",
                },
                .{
                    .name = "width",
                    .type = "integer",
                    .description = "Width in CSS pixels. Defaults to 200.",
                },
                .{
                    .name = "height",
                    .type = "integer",
                    .description = "Height in CSS pixels. Defaults to 100.",
                },
                .{
                    .name = "fill",
                    .type = "string",
                    .description = "Fill color (CSS color string, e.g. '#ffffff', 'transparent'). Defaults to ''.",
                },
                .{
                    .name = "rotation",
                    .type = "number",
                    .description = "Rotation in degrees (clockwise). Defaults to 0.",
                },
                .{
                    .name = "corner_radius",
                    .type = "integer",
                    .description = "Corner radius in CSS pixels (for rectangle only). Defaults to 0.",
                },
                .{
                    .name = "opacity",
                    .type = "number",
                    .description = "Opacity (0.0 transparent to 1.0 opaque). Defaults to 1.0.",
                },
                .{
                    .name = "text_content",
                    .type = "string",
                    .description = "Text content (for type='text'). Defaults to ''.",
                },
                .{
                    .name = "text_style",
                    .type = "string",
                    .description = "Text style as JSON (e.g. {\"font\":\"Inter\",\"size\":14}). Defaults to ''.",
                },
                .{
                    .name = "image_url",
                    .type = "string",
                    .description = "Image URL (for type='image'). Defaults to ''.",
                },
            },
            .required = &.{ "page_id", "name", "type", "html" },
        },
    },
};

/// Escape XML special characters. Mirrors the helper in
/// kanban_list.zig / set_design_page.zig (duplicated locally to keep
/// this tool file self-contained).
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
/// `<add_element><error>...</error></add_element>` so the tool
/// dispatcher can detect it via `<error>` substring search.
pub fn errorXml(allocator: std.mem.Allocator, error_msg: []const u8) ![]u8 {
    var xml: std.ArrayList(u8) = .empty;
    errdefer xml.deinit(allocator);

    try xml.appendSlice(allocator, "<add_element><error>");
    const escaped = try xmlEscape(allocator, error_msg);
    defer allocator.free(escaped);
    try xml.appendSlice(allocator, escaped);
    try xml.appendSlice(allocator, "</error></add_element>");
    return try xml.toOwnedSlice(allocator);
}

/// Same as `errorXml` but TAKES OWNERSHIP of `error_msg` and frees it.
pub fn errorXmlOwned(allocator: std.mem.Allocator, error_msg: []u8) ![]u8 {
    defer allocator.free(error_msg);

    var xml: std.ArrayList(u8) = .empty;
    errdefer xml.deinit(allocator);

    try xml.appendSlice(allocator, "<add_element><error>");
    const escaped = try xmlEscape(allocator, error_msg);
    defer allocator.free(escaped);
    try xml.appendSlice(allocator, escaped);
    try xml.appendSlice(allocator, "</error></add_element>");
    return try xml.toOwnedSlice(allocator);
}

/// Parse the `type` string into an `ElementType` enum. Returns the
/// parsed enum on success, or `null` when the string is not one of
/// the 6 valid types. The wire format is the lowercase string
/// representation of the enum (`@tagName(ElementType.rectangle)` is
/// `"rectangle"`).
pub fn parseElementType(type_str: []const u8) ?design_model.ElementType {
    if (std.mem.eql(u8, type_str, "rectangle")) return .rectangle;
    if (std.mem.eql(u8, type_str, "ellipse")) return .ellipse;
    if (std.mem.eql(u8, type_str, "text")) return .text;
    if (std.mem.eql(u8, type_str, "image")) return .image;
    if (std.mem.eql(u8, type_str, "frame")) return .frame;
    if (std.mem.eql(u8, type_str, "group")) return .group;
    return null;
}

/// Render the canonical "element" XML response shape. Mirrors the
/// spec in design §6.2 — `<element id="..." page_id="..." name="..."
/// type="..." x="..." y="..." width="..." height="..." fill="..."
/// rotation="..." opacity="..." file_path="..." created_at="..."
/// updated_at="..." />`.
///
/// `html` is intentionally omitted (the LLM doesn't need the body,
/// and it can be 5+ KB). The LLM can fetch the body via the REST
/// endpoint when it needs to inspect or modify it.
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

/// Validate `page_id` is non-empty and has the right `page_` prefix.
/// Returns null when shape is correct, or an error XML on mismatch.
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
            \\page_id '{s}' has an unrecognized prefix (expected 'page_'). add_element expects a page_id from a previous set_design_page response, not a free-form string.
        , .{page_id}));
    }
    return null;
}

/// Validate `name` is non-empty and contains no illegal characters.
/// The v6 file-backed model stores the HTML at
/// `<item_path>/.nalar/design/<page>/<sanitized_name>.html`, so `/`
/// would escape the page directory.
fn validateNameShape(allocator: std.mem.Allocator, name: []const u8) !?[]u8 {
    if (name.len == 0) {
        return try errorXml(allocator, "name is required");
    }
    if (std.mem.indexOfScalar(u8, name, '/') != null) {
        return try errorXml(allocator, "name must not contain '/' (it becomes a filename)");
    }
    if (std.mem.indexOfScalar(u8, name, 0) != null) {
        return try errorXml(allocator, "name must not contain null bytes");
    }
    return null;
}

/// Validate `html` is non-empty. The DB stores `html` separately on
/// disk, so an empty body would create an orphan `<element>` row with
/// a zero-byte file.
fn validateHtmlShape(allocator: std.mem.Allocator, html: []const u8) !?[]u8 {
    if (html.len == 0) {
        return try errorXml(allocator, "html is required (the element's HTML body — write something)");
    }
    return null;
}

/// Execute the `add_element` tool. Returns an XML string for the LLM.
///
/// On success, the response shape is the same as `set_design_page`'s
/// `<element .../>` block (without the wrapping `<page>...</page>`).
///
/// On error (bad type, bad page_id, bad name, DB failure), the
/// response is wrapped in `<add_element><error>...</error></add_element>`.
pub fn executeAddElementToString(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    io: std.Io,
    input: AddElementInput,
) ![]u8 {
    // 0. Input validation (shape only — DB validation runs after).
    if (try validatePageIdShape(allocator, input.page_id)) |e| return e;
    if (try validateNameShape(allocator, input.name)) |e| return e;
    if (try validateHtmlShape(allocator, input.html)) |e| return e;

    // 1. Parse the type string into the ElementType enum. Returns a
    //    structured error when the type is not one of the 6 valid
    //    values — the LLM is told all 6 in the description so it can
    //    self-correct.
    const elem_type = parseElementType(input.type) orelse {
        return try errorXml(allocator,
            "type must be one of: rectangle, ellipse, text, image, frame, group");
    };

    // 2. Resolve defaults.
    const x = input.x orelse 0;
    const y = input.y orelse 0;
    const width = input.width orelse 200;
    const height = input.height orelse 100;
    const rotation = input.rotation orelse 0.0;
    const corner_radius = input.corner_radius orelse 0;
    const opacity = input.opacity orelse 1.0;

    // 3. Call addElement (atomically writes the HTML to disk and
    //    inserts the metadata row). Returns the new element_id.
    //
    // The `fill` column is `NOT NULL DEFAULT ''` in the v6 schema,
    // but `SqliteBackend.exec` binds empty slices as SQL NULL (see
    // project memory `sqlite-backend-empty-slice-binds-as-null`).
    // That would trigger `NOT NULL constraint failed: fill`.
    // Substitute the literal `"transparent"` (valid CSS color, conveys
    // "no fill" to the renderer) when the user passed an empty
    // string. The element XML response still surfaces the original
    // `input.fill` value via `getElement` (which reads back `''`).
    const fill_for_db: []const u8 = if (input.fill.len == 0) "transparent" else input.fill;
    const element_id = design_model.addElement(allocator, db, io, .{
        .page_id = input.page_id,
        .name = input.name,
        .elem_type = elem_type,
        .html = input.html,
        .x = x,
        .y = y,
        .width = width,
        .height = height,
        .fill = fill_for_db,
        .rotation = rotation,
        .corner_radius = corner_radius,
        .opacity = opacity,
        .text_content = input.text_content,
        .text_style = input.text_style,
        .image_url = input.image_url,
    }) catch |err| switch (err) {
        error.PageNotFound => return try errorXml(allocator, "page_id does not match any design page — call set_design_page first"),
        error.ItemPathMissing => return try errorXml(allocator, "the design item has no path; set one via AddDesignDialog"),
        error.BadName => return try errorXml(allocator, "name is invalid (empty or contains illegal characters)"),
        error.FileWriteFailed => return try errorXml(allocator, "could not write the HTML file to disk (permission denied or out of space)"),
        else => return try errorXmlOwned(allocator, try std.fmt.allocPrint(allocator, "DB: addElement failed: {s}", .{@errorName(err)})),
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