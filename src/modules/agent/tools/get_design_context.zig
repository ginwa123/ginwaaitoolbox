//! LLM tool: `get_design_context` — read-only inspection of a design canvas.
//!
//! Pass EITHER `page_id` to get one page with its elements, OR
//! `workspace_item_id` to get ALL pages of the design item. Exactly one of
//! the two must be provided.
//!
//! Returns an XML envelope mirroring the design DB wire shape (every element
//! field the agent needs for layout reasoning is rendered as an attribute).
//! HTML bodies are intentionally NOT included — the agent can read them
//! individually with `read_file` if needed (matches the existing
//! `set_design_page` convention).
//!
//! Plan: docs/superpowers/plans/2026-08-06-ai-agent-design-context-tool.md (Chunk 1)

const std = @import("std");
const schemas = @import("schemas.zig");
const AgentTool = schemas.AgentTool;
const nalarcore = @import("nalarcore");
const sqlite = nalarcore.sqlite;
const design_model = nalarcore.ai_mod.design_model;

/// Input structure for `get_design_context` tool.
///
/// The agent picks ONE of the two modes:
///   - `page_id` → returns that single page + its elements
///   - `workspace_item_id` → returns ALL pages of the design item + their elements
///
/// Both null OR both set → error envelope.
pub const GetDesignContextInput = struct {
    page_id: ?[]const u8 = null,
    workspace_item_id: ?[]const u8 = null,
};

/// Top-level tool definition for the LLM.
pub const get_design_context_tool_system_prompt =
    \\## Get Design Context Tool — Behavior
    \\Use `get_design_context` to inspect design structure: pages + elements with geometry.
    \\- Pass `page_id` for one page or `workspace_item_id` for all pages. Use to discover `element_id`/`page_id` before editing.
    \\- HTML bodies are not included — read them via `read_file` if needed.
    \\
;

pub const get_design_context_tool = AgentTool{
    .type = "function",
    .function = .{
        .name = "get_design_context",
        .description =
            \\Inspect the structure of a design canvas (pages + elements). Pass EITHER `page_id` to get one page with its elements, OR `workspace_item_id` to get ALL pages of the design item. Exactly one of the two must be provided.
            \\
            \\Returns an XML envelope:
            \\
            \\<design_context>
            \\  <pages count="N">
            \\    <page id="page_X" name="Login" width="1440" height="1024" position="0">
            \\      <design_page_elements count="M">
            \\        <element id="elem_Y" page_id="page_X" name="..." type="rectangle"
            \\                x="..." y="..." width="..." height="..." rotation="..."
            \\                fill="..." stroke="..." corner_radius="..." opacity="..."
            \\                text_content="..." image_url="..." parent_id="..."
            \\                file_path="..." z_index="..." position="..."
            \\                created_at="..." updated_at="..." />
            \\      </design_page_elements>
            \\    </page>
            \\  </pages>
            \\</design_context>
            \\
            \\Each element attribute matches the design DB row wire shape (so the agent can spot `x`/`y`/`width`/`height` for layout, `parent_id` for grouping, `text_content` for content).
            \\
            \\HTML bodies are intentionally NOT included — the agent can read them individually with `read_file` if needed. If the page has no HTML bodies yet, use `add_element` (or `set_design_page` to create the page) first.
            \\
            \\On error, the response is wrapped in `<design_context><error>...</error></design_context>`.
        ,
        .parameters = .{
            .type = "object",
            .properties = &.{
                .{
                    .name = "page_id",
                    .type = "string",
                    .description = "Get context for ONE page. Pass it OR `workspace_item_id` (not both). Use `set_design_page` first if you don't know the page_id.",
                },
                .{
                    .name = "workspace_item_id",
                    .type = "string",
                    .description = "Get context for ALL pages of a design item. Must come from the Workspace Context listing (item_type='design'). Pass it OR `page_id` (not both).",
                },
            },
            .required = &.{},
        },
        .system_prompt = get_design_context_tool_system_prompt,
    },
};

// ─── XML helpers (local — project convention is per-file duplication) ────

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

fn errorEnvelope(allocator: std.mem.Allocator, error_msg: []const u8) ![]u8 {
    var xml: std.ArrayList(u8) = .empty;
    errdefer xml.deinit(allocator);

    try xml.appendSlice(allocator, "<design_context><error>");
    const escaped = try xmlEscape(allocator, error_msg);
    defer allocator.free(escaped);
    try xml.appendSlice(allocator, escaped);
    try xml.appendSlice(allocator, "</error></design_context>");
    return try xml.toOwnedSlice(allocator);
}

// ─── Execute ─────────────────────────────────────────────────────────────

/// Execute `get_design_context`.
///
/// Returns an XML envelope:
///   - success: `<design_context>...</design_context>`
///   - error:   `<design_context><error>...</error></design_context>`
///
/// Both forms are detectable by the exec wrapper via the `<error>` substring
/// search (matches the convention used by `set_design_page` / `show_preview`).
pub fn executeGetDesignContextToString(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    input: GetDesignContextInput,
) ![]u8 {
    // 1. Validate exactly-one of the two ids.
    const page_id_present = input.page_id != null and input.page_id.?.len > 0;
    const item_id_present = input.workspace_item_id != null and input.workspace_item_id.?.len > 0;
    if (page_id_present == item_id_present) {
        return try errorEnvelope(
            allocator,
            "exactly one of `page_id` or `workspace_item_id` must be provided (use Workspace Context to find the design item_id)",
        );
    }

    // 2. Dispatch to the right inner function.
    if (page_id_present) {
        return try executeForPage(allocator, db, input.page_id.?);
    } else {
        return try executeForItem(allocator, db, input.workspace_item_id.?);
    }
}

fn executeForPage(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    page_id: []const u8,
) ![]u8 {
    var bundle = design_model.getPageWithElements(allocator, db, page_id) catch |err| {
        const msg = try std.fmt.allocPrint(
            allocator,
            "page_id '{s}' not found: {s}",
            .{ page_id, @errorName(err) },
        );
        defer allocator.free(msg);
        return try errorEnvelope(allocator, msg);
    };
    defer bundle.deinit(allocator);

    var xml: std.ArrayList(u8) = .empty;
    errdefer xml.deinit(allocator);

    try xml.appendSlice(allocator, "<design_context>");
    try xml.appendSlice(allocator, "<pages count=\"1\">");
    try appendPage(&xml, allocator, bundle.page, bundle.elements);
    try xml.appendSlice(allocator, "</pages>");
    try xml.appendSlice(allocator, "</design_context>");

    return try xml.toOwnedSlice(allocator);
}

fn executeForItem(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    item_id: []const u8,
) ![]u8 {
    const pages = design_model.listPagesWithElements(allocator, db, item_id) catch |err| {
        const msg = try std.fmt.allocPrint(
            allocator,
            "workspace_item_id '{s}' not found or DB error: {s}",
            .{ item_id, @errorName(err) },
        );
        defer allocator.free(msg);
        return try errorEnvelope(allocator, msg);
    };
    defer design_model.freePagesWithElements(allocator, pages);

    var xml: std.ArrayList(u8) = .empty;
    errdefer xml.deinit(allocator);

    var count_buf: [32]u8 = undefined;
    const count_str = std.fmt.bufPrint(&count_buf, "{d}", .{pages.len}) catch "0";

    try xml.appendSlice(allocator, "<design_context>");
    try xml.appendSlice(allocator, "<pages count=\"");
    try xml.appendSlice(allocator, count_str);
    try xml.appendSlice(allocator, "\">");

    for (pages) |*page| {
        try appendPage(&xml, allocator, page.page, page.elements);
    }

    try xml.appendSlice(allocator, "</pages>");
    try xml.appendSlice(allocator, "</design_context>");

    return try xml.toOwnedSlice(allocator);
}

fn appendPage(
    xml: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    page: design_model.DesignPage,
    elements: []const design_model.DesignElement,
) !void {
    try xml.appendSlice(allocator, "<page");

    const eid = try xmlEscape(allocator, page.id);
    defer allocator.free(eid);
    try xml.appendSlice(allocator, " id=\"");
    try xml.appendSlice(allocator, eid);
    try xml.appendSlice(allocator, "\"");

    const ename = try xmlEscape(allocator, page.name);
    defer allocator.free(ename);
    try xml.appendSlice(allocator, " name=\"");
    try xml.appendSlice(allocator, ename);
    try xml.appendSlice(allocator, "\"");

    try appendIntAttr(xml, allocator, "width", page.width);
    try appendIntAttr(xml, allocator, "height", page.height);
    try appendIntAttr(xml, allocator, "position", page.position);

    try xml.appendSlice(allocator, ">");

    // The wrapper element name mirrors the user's request:
    // `design_page_elements` (the DB table name). count="N" is required so
    // the agent can iterate without first parsing the children.
    var count_buf: [32]u8 = undefined;
    const count_str = std.fmt.bufPrint(&count_buf, "{d}", .{elements.len}) catch "0";
    try xml.appendSlice(allocator, "<design_page_elements count=\"");
    try xml.appendSlice(allocator, count_str);
    try xml.appendSlice(allocator, "\">");

    for (elements) |e| {
        try appendElement(xml, allocator, e);
    }

    try xml.appendSlice(allocator, "</design_page_elements>");
    try xml.appendSlice(allocator, "</page>");
}

fn appendElement(
    xml: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    e: design_model.DesignElement,
) !void {
    try xml.appendSlice(allocator, "<element");

    // Required ident attributes
    const eid = try xmlEscape(allocator, e.id);
    defer allocator.free(eid);
    try xml.appendSlice(allocator, " id=\"");
    try xml.appendSlice(allocator, eid);
    try xml.appendSlice(allocator, "\"");

    const epid = try xmlEscape(allocator, e.page_id);
    defer allocator.free(epid);
    try xml.appendSlice(allocator, " page_id=\"");
    try xml.appendSlice(allocator, epid);
    try xml.appendSlice(allocator, "\"");

    const ename = try xmlEscape(allocator, e.name);
    defer allocator.free(ename);
    try xml.appendSlice(allocator, " name=\"");
    try xml.appendSlice(allocator, ename);
    try xml.appendSlice(allocator, "\"");

    // File path: the on-disk HTML location. Always rendered (even when
    // empty) so the slot is visible. xmlEscape handles path traversal
    // characters safely.
    if (e.file_path.len > 0) {
        const v = try xmlEscape(allocator, e.file_path);
        defer allocator.free(v);
        try xml.appendSlice(allocator, " file_path=\"");
        try xml.appendSlice(allocator, v);
        try xml.appendSlice(allocator, "\"");
    } else {
        try xml.appendSlice(allocator, " file_path=\"\"");
    }

    // Geometry
    try appendIntAttr(xml, allocator, "x", e.x);
    try appendIntAttr(xml, allocator, "y", e.y);
    try appendIntAttr(xml, allocator, "width", e.width);
    try appendIntAttr(xml, allocator, "height", e.height);
    try appendIntAttr(xml, allocator, "z_index", e.z_index);
    try appendIntAttr(xml, allocator, "position", e.position);

    // Type
    const etype = try xmlEscape(allocator, e.elem_type);
    defer allocator.free(etype);
    try xml.appendSlice(allocator, " type=\"");
    try xml.appendSlice(allocator, etype);
    try xml.appendSlice(allocator, "\"");

    // Visual props
    try appendFloatAttr(xml, allocator, "rotation", e.rotation);
    try appendFloatAttr(xml, allocator, "opacity", e.opacity);

    // fill / stroke — always rendered (even when empty) so the slot is
    // visible to the agent.
    if (e.fill.len > 0) {
        const v = try xmlEscape(allocator, e.fill);
        defer allocator.free(v);
        try xml.appendSlice(allocator, " fill=\"");
        try xml.appendSlice(allocator, v);
        try xml.appendSlice(allocator, "\"");
    } else {
        try xml.appendSlice(allocator, " fill=\"\"");
    }
    if (e.stroke.len > 0) {
        const v = try xmlEscape(allocator, e.stroke);
        defer allocator.free(v);
        try xml.appendSlice(allocator, " stroke=\"");
        try xml.appendSlice(allocator, v);
        try xml.appendSlice(allocator, "\"");
    } else {
        try xml.appendSlice(allocator, " stroke=\"\"");
    }

    try appendIntAttr(xml, allocator, "stroke_width", e.stroke_width);
    try appendIntAttr(xml, allocator, "corner_radius", e.corner_radius);

    // Content fields — always rendered so the slot is visible.
    if (e.text_content.len > 0) {
        const v = try xmlEscape(allocator, e.text_content);
        defer allocator.free(v);
        try xml.appendSlice(allocator, " text_content=\"");
        try xml.appendSlice(allocator, v);
        try xml.appendSlice(allocator, "\"");
    } else {
        try xml.appendSlice(allocator, " text_content=\"\"");
    }
    if (e.text_style.len > 0) {
        const v = try xmlEscape(allocator, e.text_style);
        defer allocator.free(v);
        try xml.appendSlice(allocator, " text_style=\"");
        try xml.appendSlice(allocator, v);
        try xml.appendSlice(allocator, "\"");
    } else {
        try xml.appendSlice(allocator, " text_style=\"\"");
    }
    if (e.image_url.len > 0) {
        const v = try xmlEscape(allocator, e.image_url);
        defer allocator.free(v);
        try xml.appendSlice(allocator, " image_url=\"");
        try xml.appendSlice(allocator, v);
        try xml.appendSlice(allocator, "\"");
    } else {
        try xml.appendSlice(allocator, " image_url=\"\"");
    }

    // parent_id — always rendered (empty string for top-level).
    if (e.parent_id.len > 0) {
        const v = try xmlEscape(allocator, e.parent_id);
        defer allocator.free(v);
        try xml.appendSlice(allocator, " parent_id=\"");
        try xml.appendSlice(allocator, v);
        try xml.appendSlice(allocator, "\"");
    } else {
        try xml.appendSlice(allocator, " parent_id=\"\"");
    }

    // Timestamps
    if (e.created_at.len > 0) {
        try xml.appendSlice(allocator, " created_at=\"");
        try xml.appendSlice(allocator, e.created_at);
        try xml.appendSlice(allocator, "\"");
    } else {
        try xml.appendSlice(allocator, " created_at=\"\"");
    }
    if (e.updated_at.len > 0) {
        try xml.appendSlice(allocator, " updated_at=\"");
        try xml.appendSlice(allocator, e.updated_at);
        try xml.appendSlice(allocator, "\"");
    } else {
        try xml.appendSlice(allocator, " updated_at=\"\"");
    }

    try xml.appendSlice(allocator, " />");
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