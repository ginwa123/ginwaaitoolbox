//! LLM tool: `set_design_page` — idempotent create/update for a design
//! canvas page. Returns the page (with all elements, but no HTML bodies)
//! so the LLM can discover existing state in a single call (the v6
//! "no list_elements tool" simplification — see design §6.4).
//!
//! Plan: docs/superpowers/plans/2026-07-08-design-mode-redesign.md (Chunk 4)
//! Design: docs/plans/2026-07-08-design-mode-redesign-design.md §6.1

const std = @import("std");
const schemas = @import("schemas.zig");
const AgentTool = schemas.AgentTool;
const nalarcore = @import("nalarcore");
const sqlite = nalarcore.sqlite;
const design_model = nalarcore.ai_mod.design_model;

/// Input structure for `set_design_page` tool.
///
/// The agent passes `item_id` from the active chat context (injected by
/// the frontend via `BuildDesignCanvasPrompt` into the system prompt).
/// `width` and `height` are optional and default to the v6 standard
/// (1440 × 1024 — matches the standard design viewport).
pub const SetDesignPageInput = struct {
    /// The design workspace item id. From the chat's workspace context
    /// (system prompt's `## Workspace Context` section). Always starts
    /// with `item_` and has `item_type = 'design'`.
    item_id: []const u8 = "",
    /// Human-readable page name (e.g. "Login", "Dashboard", "Settings").
    /// Must be unique within the design item. Must NOT contain `/` or
    /// null bytes (the v6 file-backed model stores pages under
    /// `<item_path>/.nalar/design/<sanitized_page_name>/`).
    page_name: []const u8 = "",
    /// Page width in CSS pixels. Defaults to 1440 when null.
    width: ?i64 = null,
    /// Page height in CSS pixels. Defaults to 1024 when null.
    height: ?i64 = null,
};

/// Top-level tool definition for the LLM.
///
/// The description tells the LLM:
/// 1. That `set_design_page` has dual semantics (create + list) — every
///    call returns the full page including all elements.
/// 2. That the operation is idempotent — re-issuing the same (item_id,
///    page_name) updates width/height in place.
/// 3. That `item_id` comes from the chat's workspace context (system
///    prompt's `## Workspace Context` section).
pub const set_design_page_tool = AgentTool{
    .type = "function",
    .function = .{
        .name = "set_design_page",
        .description =
            \\Create or update a page on a design canvas. This tool has dual semantics: it both CREATES a new page (when none exists with this name on this design item) AND returns the current state of the page INCLUDING all its elements. Use this tool to (1) discover what elements already exist on a page, (2) set the page dimensions, or (3) create a new page.
            \\
            \\The call is idempotent: re-issuing `set_design_page` with the same (item_id, page_name) REPLACES the existing page's width/height in place. Other connected clients see the change via SSE.
            \\
            \\The item_id must come from the chat context — see the "## Workspace Context" section of the system prompt. Each sibling item is rendered as `- **<name>** (id: <id>, item_type: <type>, path: <path>)` where the id is a backtick-quoted id (e.g. item_1782313125505579000). The id is the **canonical** lookup key — do NOT pass the human-readable name. The design item is the one with `item_type='design'`.
            \\
            \\Page name rules: must be unique per design item, must NOT contain `/` or null bytes (the unique index rejects duplicates with an `<error>` response). Pick clear names: `Login`, `Dashboard`, `Settings`, `Profile`, etc.
            \\
            \\On error, recover by: (1) verify the item_id from the Workspace Context (the active design item is the one marked `*(this task)*`); (2) if the item has no path set, the user must open the AddDesign dialog first to set one — you cannot create pages for an unconfigured item.
        ,
        .parameters = .{
            .type = "object",
            .properties = &.{
                .{
                    .name = "item_id",
                    .type = "string",
                    .description = "The design workspace item id (NOT the name). Find it next to the literal text `id: ` followed by a backtick-quoted id (e.g. item_1782313125505579000) in the Workspace Context listing — pass the value between the backticks, not the human-readable item name. The item has `item_type='design'`.",
                },
                .{
                    .name = "page_name",
                    .type = "string",
                    .description = "Human-readable page name (e.g. 'Login', 'Dashboard'). Must be unique per design item. Must NOT contain '/' or null bytes.",
                },
                .{
                    .name = "width",
                    .type = "integer",
                    .description = "Page width in CSS pixels. Optional; defaults to 1440 (standard design viewport).",
                },
                .{
                    .name = "height",
                    .type = "integer",
                    .description = "Page height in CSS pixels. Optional; defaults to 1024 (standard design viewport).",
                },
            },
            .required = &.{ "item_id", "page_name" },
        },
    },
};

/// Escape XML special characters. Mirrors the helper in
/// kanban_list.zig / list_memory.zig / list_skills.zig (duplicated
/// locally to keep this tool file self-contained).
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
/// `<page><error>...</error></page>` so `tool_registry.execSetDesignPage`
/// can detect it via `<error>` substring search and surface the
/// structured error to the LLM as `success=false`.
pub fn errorXml(allocator: std.mem.Allocator, error_msg: []const u8) ![]u8 {
    var xml: std.ArrayList(u8) = .empty;
    errdefer xml.deinit(allocator);

    try xml.appendSlice(allocator, "<page><error>");
    const escaped = try xmlEscape(allocator, error_msg);
    defer allocator.free(escaped);
    try xml.appendSlice(allocator, escaped);
    try xml.appendSlice(allocator, "</error></page>");
    return try xml.toOwnedSlice(allocator);
}

/// Same as `errorXml` but TAKES OWNERSHIP of `error_msg` and frees it
/// on return. Used to avoid leaks when the caller's message is an
/// `allocPrint` result (can't `defer` across a `return`).
pub fn errorXmlOwned(allocator: std.mem.Allocator, error_msg: []u8) ![]u8 {
    defer allocator.free(error_msg);

    var xml: std.ArrayList(u8) = .empty;
    errdefer xml.deinit(allocator);

    try xml.appendSlice(allocator, "<page><error>");
    const escaped = try xmlEscape(allocator, error_msg);
    defer allocator.free(escaped);
    try xml.appendSlice(allocator, escaped);
    try xml.appendSlice(allocator, "</error></page>");
    return try xml.toOwnedSlice(allocator);
}

/// Detect the two known LLM id-confusion mistakes (task_id or column_id
/// passed where item_id was expected). Returns null when the shape
/// looks correct, or a structured error XML describing the exact
/// mistake + the canonical id source.
///
/// This runs BEFORE the DB query so the LLM gets a fast, typed error
/// instead of a silent failure that produces an empty `<page>` block
/// (which the LLM would interpret as "no elements yet" — wrong).
pub fn validateItemIdShape(allocator: std.mem.Allocator, item_id: []const u8) !?[]u8 {
    if (item_id.len == 0) {
        return try errorXml(allocator, "item_id is required (pass the design item's id from the Workspace Context listing)");
    }
    // The DB-generated ids use these prefixes (see workspace_items_create.zig
    // for item_, workspace_item_tasks_create.zig for task_,
    // kanban_model.generateColumnId for col_, workspaces_create.zig for ws_).
    // Anything with the wrong prefix is a shape mistake.
    if (std.mem.startsWith(u8, item_id, "task_")) {
        return try errorXmlOwned(allocator, try std.fmt.allocPrint(allocator,
            \\item_id '{s}' looks like a TASK id (starts with 'task_'). Pass the DESIGN's item_id instead — find it next to the literal text `item_id: ` in the Workspace Context listing. The item_id always starts with 'item_'.
        , .{item_id}));
    }
    if (std.mem.startsWith(u8, item_id, "page_")) {
        return try errorXmlOwned(allocator, try std.fmt.allocPrint(allocator,
            \\item_id '{s}' looks like a PAGE id (starts with 'page_'). Pass the DESIGN's item_id instead — find it next to the literal text `item_id: ` in the Workspace Context listing. The item_id always starts with 'item_'.
        , .{item_id}));
    }
    if (std.mem.startsWith(u8, item_id, "elem_")) {
        return try errorXmlOwned(allocator, try std.fmt.allocPrint(allocator,
            \\item_id '{s}' looks like an ELEMENT id (starts with 'elem_'). Pass the DESIGN's item_id instead — find it next to the literal text `item_id: ` in the Workspace Context listing. The item_id always starts with 'item_'.
        , .{item_id}));
    }
    if (std.mem.startsWith(u8, item_id, "ws_")) {
        return try errorXmlOwned(allocator, try std.fmt.allocPrint(allocator,
            \\item_id '{s}' looks like a WORKSPACE id (starts with 'ws_'). You probably swapped workspace_id and item_id. The DESIGN's item_id starts with 'item_' — find it next to the literal text `item_id: ` in the Workspace Context listing.
        , .{item_id}));
    }
    if (!std.mem.startsWith(u8, item_id, "item_")) {
        return try errorXmlOwned(allocator, try std.fmt.allocPrint(allocator,
            \\item_id '{s}' has an unrecognized prefix (expected 'item_'). Workspace-scoped tools expect a design item_id from the Workspace Context listing, not a free-form string.
        , .{item_id}));
    }
    return null;
}

/// Execute the `set_design_page` tool. Returns an XML string for the
/// LLM.
///
/// On success, the response shape is:
/// ```xml
/// <page id="page_xxx" name="Login" width="1440" height="1024" position="0">
///   <element id="elem_yyy" name="login-card" type="rectangle" x="100" y="200"
///           width="400" height="300" fill="#ffffff" rotation="0" />
///   ... more elements ...
/// </page>
/// ```
///
/// On error (item_path missing, page name invalid, DB failure, id
/// confusion), the response is wrapped in `<page><error>...</error></page>`.
pub fn executeSetDesignPageToString(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    input: SetDesignPageInput,
) ![]u8 {
    // 0. Detect the four known LLM id-confusion mistakes. Runs BEFORE
    //    the DB query so the LLM gets a fast, typed error instead of
    //    a silent failure.
    if (try validateItemIdShape(allocator, input.item_id)) |err_xml| {
        return err_xml;
    }

    // 1. Verify the page_name is non-empty and has no illegal
    //    characters. Empty page_name would create a row with `name=''`
    //    that conflicts with subsequent pages; the v6 file-backed
    //    model stores pages under `<item_path>/.nalar/design/<name>/`,
    //    so `/` would escape the parent directory.
    if (input.page_name.len == 0) {
        return try errorXml(allocator, "page_name is required");
    }
    if (std.mem.indexOfScalar(u8, input.page_name, '/') != null) {
        return try errorXml(allocator, "page_name must not contain '/' (it becomes a directory name)");
    }
    if (std.mem.indexOfScalar(u8, input.page_name, 0) != null) {
        return try errorXml(allocator, "page_name must not contain null bytes");
    }

    // 2. Resolve width/height defaults (1440 × 1024 = v6 standard
    //    design viewport).
    const width = input.width orelse 1440;
    const height = input.height orelse 1024;

    // 3. Idempotent create/update. Returns the page_id of the
    //    existing-or-newly-created page. Errors are surfaced as
    //    structured <page><error>...</error></page> responses.
    const page_id = design_model.setDesignPage(allocator, db, .{
        .item_id = input.item_id,
        .page_name = input.page_name,
        .width = width,
        .height = height,
    }) catch |err| switch (err) {
        error.ItemPathMissing => return try errorXml(allocator, "design item has no path; set one via AddDesignDialog"),
        error.BadPageName => return try errorXml(allocator, "page_name is invalid (empty or contains illegal characters)"),
        else => return try errorXmlOwned(allocator, try std.fmt.allocPrint(allocator, "DB: setDesignPage failed: {s}", .{@errorName(err)})),
    };
    defer allocator.free(page_id);

    // 4. Re-fetch the page + all elements via getPageWithElements
    //    (returns a bundled PageWithElements — single query for the
    //    page, single query for the elements).
    var bundle = design_model.getPageWithElements(allocator, db, page_id) catch |err| {
        return try errorXmlOwned(allocator, try std.fmt.allocPrint(allocator, "DB: getPageWithElements failed: {s}", .{@errorName(err)}));
    };
    defer bundle.deinit(allocator);

    // 5. Render the XML. The element loop omits `html` (the LLM
    //    doesn't need it) and emits the file_path so the LLM knows
    //    where the on-disk content lives.
    return try toXml(allocator, bundle.page, bundle.elements);
}

/// Serialize a page + its elements to the LLM-facing XML string.
///
/// Element shape (per design §6.2 response):
/// `<element id="elem_xxx" name="login-card" type="rectangle" x="0" y="0"
///           width="200" height="100" fill="#ffffff" rotation="0"
///           corner_radius="0" opacity="1.0" file_path="/abs/path/to/.html"
///           created_at="..." updated_at="..." />`
///
/// We use attributes (not nested elements) for the element fields —
/// matches the spec's `<element .../>` shape and keeps the response
/// compact when a page has 20+ elements.
pub fn toXml(
    allocator: std.mem.Allocator,
    page: design_model.DesignPage,
    elements: []const design_model.DesignElement,
) ![]u8 {
    var xml: std.ArrayList(u8) = .empty;
    errdefer xml.deinit(allocator);

    // Open <page> with the four canonical attributes from §6.1.
    try xml.appendSlice(allocator, "<page");

    const escaped_id = try xmlEscape(allocator, page.id);
    defer allocator.free(escaped_id);
    try xml.appendSlice(allocator, " id=\"");
    try xml.appendSlice(allocator, escaped_id);
    try xml.appendSlice(allocator, "\"");

    const escaped_name = try xmlEscape(allocator, page.name);
    defer allocator.free(escaped_name);
    try xml.appendSlice(allocator, " name=\"");
    try xml.appendSlice(allocator, escaped_name);
    try xml.appendSlice(allocator, "\"");

    var w_buf: [32]u8 = undefined;
    const w_str = std.fmt.bufPrint(&w_buf, "{d}", .{page.width}) catch "0";
    try xml.appendSlice(allocator, " width=\"");
    try xml.appendSlice(allocator, w_str);
    try xml.appendSlice(allocator, "\"");

    var h_buf: [32]u8 = undefined;
    const h_str = std.fmt.bufPrint(&h_buf, "{d}", .{page.height}) catch "0";
    try xml.appendSlice(allocator, " height=\"");
    try xml.appendSlice(allocator, h_str);
    try xml.appendSlice(allocator, "\"");

    var pos_buf: [32]u8 = undefined;
    const pos_str = std.fmt.bufPrint(&pos_buf, "{d}", .{page.position}) catch "0";
    try xml.appendSlice(allocator, " position=\"");
    try xml.appendSlice(allocator, pos_str);
    try xml.appendSlice(allocator, "\"");

    try xml.appendSlice(allocator, ">");

    // Elements. Each <element .../> is self-closing and carries the
    // 11 v6 fields from design §5.1 + file_path + timestamps. `html`
    // is intentionally omitted — the LLM doesn't need the body for
    // layout decisions and the body can be 5+ KB.
    for (elements) |e| {
        try xml.appendSlice(allocator, "<element");

        const eid = try xmlEscape(allocator, e.id);
        defer allocator.free(eid);
        try xml.appendSlice(allocator, " id=\"");
        try xml.appendSlice(allocator, eid);
        try xml.appendSlice(allocator, "\"");

        const ename = try xmlEscape(allocator, e.name);
        defer allocator.free(ename);
        try xml.appendSlice(allocator, " name=\"");
        try xml.appendSlice(allocator, ename);
        try xml.appendSlice(allocator, "\"");

        const etype = try xmlEscape(allocator, e.elem_type);
        defer allocator.free(etype);
        try xml.appendSlice(allocator, " type=\"");
        try xml.appendSlice(allocator, etype);
        try xml.appendSlice(allocator, "\"");

        try appendIntAttr(&xml, allocator, "x", e.x);
        try appendIntAttr(&xml, allocator, "y", e.y);
        try appendIntAttr(&xml, allocator, "width", e.width);
        try appendIntAttr(&xml, allocator, "height", e.height);
        try appendFloatAttr(&xml, allocator, "rotation", e.rotation);
        try appendFloatAttr(&xml, allocator, "opacity", e.opacity);

        // fill / stroke / text_content / text_style / image_url are
        // user-provided strings that may contain `&`, `<`, `>`, `"`.
        // xmlEscape them so the LLM sees the real characters and the
        // attribute doesn't break.
        if (e.fill.len > 0) {
            const v = try xmlEscape(allocator, e.fill);
            defer allocator.free(v);
            try xml.appendSlice(allocator, " fill=\"");
            try xml.appendSlice(allocator, v);
            try xml.appendSlice(allocator, "\"");
        }
        if (e.stroke.len > 0) {
            const v = try xmlEscape(allocator, e.stroke);
            defer allocator.free(v);
            try xml.appendSlice(allocator, " stroke=\"");
            try xml.appendSlice(allocator, v);
            try xml.appendSlice(allocator, "\"");
        }

        // file_path: the on-disk location. Escaped — may contain
        // spaces, slashes, etc.
        if (e.file_path.len > 0) {
            const v = try xmlEscape(allocator, e.file_path);
            defer allocator.free(v);
            try xml.appendSlice(allocator, " file_path=\"");
            try xml.appendSlice(allocator, v);
            try xml.appendSlice(allocator, "\"");
        }

        try xml.appendSlice(allocator, " />");
    }

    try xml.appendSlice(allocator, "</page>");
    return try xml.toOwnedSlice(allocator);
}

/// Helper: append ` name="N"` (integer attribute) to the XML
/// ArrayList. Inline so we don't repeat the bufPrint dance.
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

/// Helper: append ` name="F"` (float attribute). Floats use a fixed
/// format with up to 6 decimal places to keep the XML compact.
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