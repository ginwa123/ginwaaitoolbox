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
};

/// Top-level tool definition for the LLM.
///
/// The description emphasizes that ALL fields except `element_id`
/// are optional, and that `set_design_page` is the way to discover
/// element ids (no separate list tool exists).
pub const update_design_element_tool_system_prompt =
    \\## Update Design Element Tool — Behavior
    \\Use `update_element` to partially update an existing design element.
    \\- Only the fields you provide change; others stay. Use for moving, resizing, or restyling.
    \\- Discover `element_id` via `set_design_page` or `get_design_context`.
    \\
;

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
            },
            .required = &.{"element_id"},
        },
        .system_prompt = update_design_element_tool_system_prompt,
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
    }) catch |err| switch (err) {
        error.ElementNotFound => return try errorXml(allocator, "element_id does not match any design element — call set_design_page first"),
        error.FileWriteFailed => return try errorXml(allocator, "could not write the HTML file to disk (permission denied or out of space)"),
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

const testing = std.testing;
const update_element = @import("update_design_element.zig");
const text_normalize = @import("helpers").text_normalize;

const TOOL_PATH = "src/modules/agent/tools/update_design_element.zig";
const TOOL_REGISTRY_PATH = "src/ai_workflow/tui/agentic_loop/tools_equipped.zig"; // legacy alias; tool_registry.zig was deleted 2026-08-06 — see plan
/// The exec function was migrated from `tool_registry.zig` to
/// `src/ai_workflow/tui/agentic_loop/tools_exec_update_element.zig`.
const TOOL_EXEC_PATH = "src/ai_workflow/tui/agentic_loop/tools_exec_update_element.zig";
/// The comptime tool list moved out of `tool_registry.zig` into
/// `src/ai_workflow/tui/agentic_loop/tools_equipped.zig` (which
/// `agentic_loop.tools.all_agent_tools` re-exports as `equips`).
/// Each entry in that comptime `tools_list` array uses the
/// trailing-comma format (`.tool_name,`) that this test grep matches.
const TOOLS_EQUIPPED_PATH = "src/ai_workflow/tui/agentic_loop/tools_equipped.zig";
const ROOT_PATH = "src/root.zig";

fn readSource(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const raw = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        path,
        allocator,
        .limited(256 * 1024),
    );
    const normalized = try text_normalize.normalizeLineEndings(allocator, raw);
    allocator.free(raw);
    return normalized;
}

fn contains(haystack: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, haystack, needle) != null;
}

// ─── Static source-check tests ────────────────────────────────────────────

test "update_element tool definition has correct name" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, TOOL_PATH);
    defer allocator.free(source);
    if (!contains(source, ".name = \"update_element\"")) {
        std.debug.print("!! update_design_element.zig does not define the tool with .name = \"update_element\" !!\n", .{});
        return error.ToolNameMissing;
    }
}

test "update_element description mentions element_id is the only required field" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, TOOL_PATH);
    defer allocator.free(source);
    // The description must make clear that ALL fields except
    // element_id are optional. The LLM needs to know it can update
    // just one field at a time.
    if (!contains(source, "OPTIONAL") and !contains(source, "optional")) {
        std.debug.print("!! update_element description does not mention optional fields !!\n", .{});
        return error.OptionalFieldsHintMissing;
    }
}

test "update_element description explains where element_id comes from" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, TOOL_PATH);
    defer allocator.free(source);
    if (!contains(source, "set_design_page")) {
        std.debug.print("!! update_element description does not reference set_design_page as the source of element_id !!\n", .{});
        return error.ElementIdSourceMissing;
    }
}

test "update_element input struct has all fields" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, TOOL_PATH);
    defer allocator.free(source);
    const fields = [_][]const u8{
        "element_id: []const u8",
        "name: ?[]const u8",
        "type: ?[]const u8",
        "html: ?[]const u8",
        "x: ?i64",
        "y: ?i64",
        "width: ?i64",
        "height: ?i64",
        "rotation: ?f64",
        "fill: ?[]const u8",
        "stroke: ?[]const u8",
        "stroke_width: ?i64",
        "corner_radius: ?i64",
        "opacity: ?f64",
        "text_content: ?[]const u8",
        "text_style: ?[]const u8",
        "image_url: ?[]const u8",
    };
    for (fields) |f| {
        if (!contains(source, f)) {
            std.debug.print("!! UpdateElementInput is missing field '{s}' !!\n", .{f});
            return error.FieldMissing;
        }
    }
}

// ─── Static wiring tests ─────────────────────────────────────────────────

test "tools_equipped.zig imports update_design_element module" {
    // After deduplication of `UNIFIED_TOOL_REGISTRY` (2026-08-06), the
    // registry body lives in `tools_equipped.zig` and no longer lives
    // in `tool_registry.zig`. This test now reads the imports from
    // the canonical home.
    const allocator = testing.allocator;
    const source = try readSource(allocator, TOOLS_EQUIPPED_PATH);
    defer allocator.free(source);
    if (!contains(source, "const update_design_element_mod = nalarcore.update_design_element;")) {
        std.debug.print("!! tools_equipped.zig does not bind update_design_element_mod = nalarcore.update_design_element !!\n", .{});
        return error.UpdateElementModBindingMissing;
    }
}

test "agentic_loop defines execUpdateElement" {
    // After the migration, the exec function lives in
    // `tools_exec_update_element.zig` (re-exported via
    // `agentic_loop_mod.tools.execUpdateElement`).
    const allocator = testing.allocator;
    const source = try readSource(allocator, TOOL_EXEC_PATH);
    defer allocator.free(source);
    if (!contains(source, "pub fn execUpdateElement(")) {
        std.debug.print("!! tools_exec_update_element.zig does not define pub fn execUpdateElement !!\n", .{});
        return error.ExecUpdateElementMissing;
    }
}

test "UNIFIED_TOOL_REGISTRY contains update_element entry" {
    // The registry body moved from `tool_registry.zig` (deleted) to
    // `tools_equipped.zig` (canonical home) on 2026-08-06. The test
    // now reads from the canonical file. tools_equipped.zig imports
    // `tools = @import("tools.zig")` directly, so the `.exec` binding
    // is `tools.execUpdateElement` (NOT `agentic_loop_mod.tools.execUpdateElement`).
    const allocator = testing.allocator;
    const source = try readSource(allocator, TOOLS_EQUIPPED_PATH);
    defer allocator.free(source);
    if (!contains(source, ".name = \"update_element\"")) {
        std.debug.print("!! UNIFIED_TOOL_REGISTRY is missing the update_element entry !!\n", .{});
        return error.RegistryEntryMissing;
    }
    if (!contains(source, ".exec = tools.execUpdateElement")) {
        std.debug.print("!! UNIFIED_TOOL_REGISTRY entry is missing .exec = tools.execUpdateElement !!\n", .{});
        return error.RegistryExecBindingMissing;
    }
    if (!contains(source, ".tool_def = update_design_element_mod.update_design_element_tool")) {
        std.debug.print("!! UNIFIED_TOOL_REGISTRY entry is missing .tool_def binding !!\n", .{});
        return error.RegistryToolDefBindingMissing;
    }
}

test "allAgentTools comptime list contains update_design_element tool def" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, TOOLS_EQUIPPED_PATH);
    defer allocator.free(source);
    if (!contains(source, "update_design_element_mod.update_design_element_tool,")) {
        std.debug.print("!! tools_equipped.zig comptime list is missing update_design_element_mod.update_design_element_tool !!\n", .{});
        return error.AllAgentToolsEntryMissing;
    }
}

test "root.zig exposes update_design_element module" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, ROOT_PATH);
    defer allocator.free(source);
    if (!contains(source, "pub const update_design_element = @import(\"modules/agent/tools/update_design_element.zig\");")) {
        std.debug.print("!! root.zig does not expose update_design_element as a top-level module !!\n", .{});
        return error.NalarcoreExportMissing;
    }
}

// ─── XML serialization ───────────────────────────────────────────────────

test "errorXml on missing field returns <update_element><error>...</error></update_element>" {
    const alloc = testing.allocator;
    const xml = try update_element.errorXml(alloc, "element_id is required");
    defer alloc.free(xml);
    try testing.expect(std.mem.startsWith(u8, xml, "<update_element>"));
    try testing.expect(std.mem.endsWith(u8, xml, "</update_element>"));
    try testing.expect(contains(xml, "<error>"));
    try testing.expect(contains(xml, "element_id is required"));
}

// ─── DB integration behavioral tests (in-memory SQLite) ────────────────

/// Set up an in-memory SQLite with the v6 design schema + one page +
/// one rectangle element named "card". Returns the DB handle + the
/// element_id so tests can call update_element on it.
fn setupDbWithElement() !struct {
    db: sqlite.SqliteBackend,
    threaded: std.Io.Threaded,
    item_id: []u8,
    page_id: []u8,
    element_id: []u8,
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
    const tmpdir_path: []const u8 = tmpdir_buf[0..tmpdir_len];

    const item_id_str = "item_design_1";
    try db.exec(alloc,
        "INSERT INTO workspace_items (id, workspace_id, item_type, name, path) " ++
        "VALUES (?, 'ws_test', 'design', 'Test Design', ?)",
        &.{ item_id_str, tmpdir_path });

    const page_id_str = "page_test_1";
    try db.exec(alloc,
        "INSERT INTO design_pages (id, workspace_item_id, name, width, height, position) " ++
        "VALUES (?, ?, 'Login', 1440, 1024, 0)",
        &.{ page_id_str, item_id_str });

    const element_id_str = "elem_test_1";
    try db.exec(alloc,
        "INSERT INTO design_page_elements (id, page_id, name, file_path, x, y, width, height, type, fill) " ++
        "VALUES (?, ?, 'card', '/tmp/card.html', 100, 200, 300, 150, 'rectangle', '#ffffff')",
        &.{ element_id_str, page_id_str });

    return .{
        .db = db,
        .threaded = threaded,
        .item_id = try alloc.dupe(u8, item_id_str),
        .page_id = try alloc.dupe(u8, page_id_str),
        .element_id = try alloc.dupe(u8, element_id_str),
    };
}

test "executeUpdateElementToString updates x and y only" {
    const alloc = testing.allocator;
    var s = try setupDbWithElement();
    defer s.threaded.deinit();
    defer s.db.deinit();
    defer alloc.free(s.item_id);
    defer alloc.free(s.page_id);
    defer alloc.free(s.element_id);

    const input = update_element.UpdateElementInput{
        .element_id = s.element_id,
        .x = 250,
        .y = 350,
    };
    const xml = try update_element.executeUpdateElementToString(alloc, &s.db, input);
    defer alloc.free(xml);

    try testing.expect(std.mem.startsWith(u8, xml, "<element"));
    try testing.expect(contains(xml, "id=\"elem_test_1\""));
    try testing.expect(contains(xml, "x=\"250\""));
    try testing.expect(contains(xml, "y=\"350\""));
    // Other fields stay unchanged.
    try testing.expect(contains(xml, "width=\"300\""));
    try testing.expect(contains(xml, "height=\"150\""));
    try testing.expect(contains(xml, "name=\"card\""));
    try testing.expect(contains(xml, "type=\"rectangle\""));
    try testing.expect(contains(xml, "fill=\"#ffffff\""));
    try testing.expect(!contains(xml, "<error>"));
}

test "executeUpdateElementToString updates fill" {
    const alloc = testing.allocator;
    var s = try setupDbWithElement();
    defer s.threaded.deinit();
    defer s.db.deinit();
    defer alloc.free(s.item_id);
    defer alloc.free(s.page_id);
    defer alloc.free(s.element_id);

    const input = update_element.UpdateElementInput{
        .element_id = s.element_id,
        .fill = "#22c55e",
    };
    const xml = try update_element.executeUpdateElementToString(alloc, &s.db, input);
    defer alloc.free(xml);

    try testing.expect(contains(xml, "fill=\"#22c55e\""));
}

test "executeUpdateElementToString updates name" {
    const alloc = testing.allocator;
    var s = try setupDbWithElement();
    defer s.threaded.deinit();
    defer s.db.deinit();
    defer alloc.free(s.item_id);
    defer alloc.free(s.page_id);
    defer alloc.free(s.element_id);

    const input = update_element.UpdateElementInput{
        .element_id = s.element_id,
        .name = "primary-card",
    };
    const xml = try update_element.executeUpdateElementToString(alloc, &s.db, input);
    defer alloc.free(xml);

    try testing.expect(contains(xml, "name=\"primary-card\""));
}

test "executeUpdateElementToString updates type" {
    const alloc = testing.allocator;
    var s = try setupDbWithElement();
    defer s.threaded.deinit();
    defer s.db.deinit();
    defer alloc.free(s.item_id);
    defer alloc.free(s.page_id);
    defer alloc.free(s.element_id);

    const input = update_element.UpdateElementInput{
        .element_id = s.element_id,
        .type = "ellipse",
    };
    const xml = try update_element.executeUpdateElementToString(alloc, &s.db, input);
    defer alloc.free(xml);

    try testing.expect(contains(xml, "type=\"ellipse\""));
}

test "executeUpdateElementToString returns error XML on invalid type" {
    const alloc = testing.allocator;
    var s = try setupDbWithElement();
    defer s.threaded.deinit();
    defer s.db.deinit();
    defer alloc.free(s.item_id);
    defer alloc.free(s.page_id);
    defer alloc.free(s.element_id);

    const input = update_element.UpdateElementInput{
        .element_id = s.element_id,
        .type = "hexagon",
    };
    const xml = try update_element.executeUpdateElementToString(alloc, &s.db, input);
    defer alloc.free(xml);
    try testing.expect(contains(xml, "<error>"));
    try testing.expect(contains(xml, "type"));
}

test "executeUpdateElementToString returns error XML when element_id is empty" {
    const alloc = testing.allocator;
    var s = try setupDbWithElement();
    defer s.threaded.deinit();
    defer s.db.deinit();
    defer alloc.free(s.item_id);
    defer alloc.free(s.page_id);
    defer alloc.free(s.element_id);

    const input = update_element.UpdateElementInput{
        .element_id = "",
        .x = 100,
    };
    const xml = try update_element.executeUpdateElementToString(alloc, &s.db, input);
    defer alloc.free(xml);
    try testing.expect(contains(xml, "<error>"));
    try testing.expect(contains(xml, "element_id"));
}

test "executeUpdateElementToString returns error XML when element_id has wrong prefix" {
    const alloc = testing.allocator;
    var s = try setupDbWithElement();
    defer s.threaded.deinit();
    defer s.db.deinit();
    defer alloc.free(s.item_id);
    defer alloc.free(s.page_id);
    defer alloc.free(s.element_id);

    const input = update_element.UpdateElementInput{
        .element_id = "page_1782442554112",
        .x = 100,
    };
    const xml = try update_element.executeUpdateElementToString(alloc, &s.db, input);
    defer alloc.free(xml);
    try testing.expect(contains(xml, "<error>"));
    try testing.expect(contains(xml, "page_"));
}

test "executeUpdateElementToString returns ElementNotFound error when element_id doesn't exist" {
    const alloc = testing.allocator;
    var s = try setupDbWithElement();
    defer s.threaded.deinit();
    defer s.db.deinit();
    defer alloc.free(s.item_id);
    defer alloc.free(s.page_id);
    defer alloc.free(s.element_id);

    const input = update_element.UpdateElementInput{
        .element_id = "elem_does_not_exist",
        .x = 100,
    };
    const xml = try update_element.executeUpdateElementToString(alloc, &s.db, input);
    defer alloc.free(xml);
    try testing.expect(contains(xml, "<error>"));
    try testing.expect(contains(xml, "element_id"));
}

test "executeUpdateElementToString with only element_id is a no-op success" {
    // All fields null except element_id → updateElement short-circuits
    // (no SET clauses), but still succeeds and returns the current state.
    const alloc = testing.allocator;
    var s = try setupDbWithElement();
    defer s.threaded.deinit();
    defer s.db.deinit();
    defer alloc.free(s.item_id);
    defer alloc.free(s.page_id);
    defer alloc.free(s.element_id);

    const input = update_element.UpdateElementInput{
        .element_id = s.element_id,
    };
    const xml = try update_element.executeUpdateElementToString(alloc, &s.db, input);
    defer alloc.free(xml);
    try testing.expect(std.mem.startsWith(u8, xml, "<element"));
    try testing.expect(contains(xml, "id=\"elem_test_1\""));
    // The state is unchanged.
    try testing.expect(contains(xml, "x=\"100\""));
    try testing.expect(contains(xml, "y=\"200\""));
    try testing.expect(contains(xml, "width=\"300\""));
    try testing.expect(!contains(xml, "<error>"));
}

test "executeUpdateElementToString updates rotation and opacity" {
    const alloc = testing.allocator;
    var s = try setupDbWithElement();
    defer s.threaded.deinit();
    defer s.db.deinit();
    defer alloc.free(s.item_id);
    defer alloc.free(s.page_id);
    defer alloc.free(s.element_id);

    const input = update_element.UpdateElementInput{
        .element_id = s.element_id,
        .rotation = 45.0,
        .opacity = 0.7,
    };
    const xml = try update_element.executeUpdateElementToString(alloc, &s.db, input);
    defer alloc.free(xml);
    try testing.expect(contains(xml, "rotation=\"45"));
    try testing.expect(contains(xml, "opacity=\"0.700000\""));
}
