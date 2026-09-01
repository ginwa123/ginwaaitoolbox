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
pub const set_design_page_tool_system_prompt =
    \\## Set Design Page Tool — Behavior
    \\Use `set_design_page` to create or update a design page (idempotent).
    \\- Returns page + elements (no HTML bodies). Use to ensure a page exists before adding elements.
    \\- Provide `page_id` or create a new page with `name`/`width`/`height`.
    \\
;

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
        .system_prompt = set_design_page_tool_system_prompt,
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

        // parent_id: FK to a `group`/`frame` on the same page (empty
        // string for top-level — the `COALESCE(parent_id, '')` wire
        // convention, same as the read-back path). Render as an
        // explicit empty attribute for top-level so the LLM can see
        // the slot exists.
        if (e.parent_id.len > 0) {
            const v = try xmlEscape(allocator, e.parent_id);
            defer allocator.free(v);
            try xml.appendSlice(allocator, " parent_id=\"");
            try xml.appendSlice(allocator, v);
            try xml.appendSlice(allocator, "\"");
        } else {
            try xml.appendSlice(allocator, " parent_id=\"\"");
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

const testing = std.testing;
const set_design_page = @import("set_design_page.zig");
const text_normalize = @import("helpers").text_normalize;

const TOOL_PATH = "src/modules/agent/tools/set_design_page.zig";
const TOOL_REGISTRY_PATH = "src/ai_workflow/tui/agentic_loop/tools_equipped.zig"; // legacy alias; tool_registry.zig was deleted 2026-08-06 — see plan
/// The exec function was migrated from `tool_registry.zig` to
/// `src/ai_workflow/tui/agentic_loop/tools_exec_set_design_page.zig`.
const TOOL_EXEC_PATH = "src/ai_workflow/tui/agentic_loop/tools_exec_set_design_page.zig";
/// The comptime tool list moved out of `tool_registry.zig` into
/// `src/ai_workflow/tui/agentic_loop/tools_equipped.zig` (which
/// `agentic_loop.tools.all_agent_tools` re-exports as `equips`).
/// Each entry in that comptime `tools_list` array uses the
/// trailing-comma format (`.tool_name,`) that this test grep matches.
const TOOLS_EQUIPPED_PATH = "src/ai_workflow/tui/agentic_loop/tools_equipped.zig";
const ROOT_PATH = "src/root.zig";

/// Read a source file from disk, relative to the project root.
/// Normalizes CRLF → LF so multi-line literal needles match even when
/// the file was checked out on Windows with autocrlf=true (see
/// `.gitattributes` + `src/helpers/text_normalize.zig` for context).
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

test "set_design_page tool definition has correct name" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, TOOL_PATH);
    defer allocator.free(source);
    if (!contains(source, ".name = \"set_design_page\"")) {
        std.debug.print("!! set_design_page.zig does not define the tool with .name = \"set_design_page\" !!\n", .{});
        return error.ToolNameMissing;
    }
}

test "set_design_page description mentions Workspace Context for ids" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, TOOL_PATH);
    defer allocator.free(source);
    // The description must tell the LLM that item_id comes from the
    // active chat's workspace context — otherwise the LLM will
    // hallucinate ids or fail to call the tool.
    if (!contains(source, "Workspace Context")) {
        std.debug.print("!! set_design_page description does not mention the Workspace Context !!\n", .{});
        return error.WorkspaceContextHintMissing;
    }
}

test "set_design_page description explains WHEN to use the tool" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, TOOL_PATH);
    defer allocator.free(source);
    if (!contains(source, "Use this tool to")) {
        std.debug.print("!! set_design_page description does not include a 'Use this tool to' signal !!\n", .{});
        return error.WhenToUseMissing;
    }
}

test "set_design_page input struct has item_id + page_name fields" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, TOOL_PATH);
    defer allocator.free(source);
    if (!contains(source, "item_id: []const u8")) {
        std.debug.print("!! SetDesignPageInput is missing the 'item_id' field !!\n", .{});
        return error.ItemIdFieldMissing;
    }
    if (!contains(source, "page_name: []const u8")) {
        std.debug.print("!! SetDesignPageInput is missing the 'page_name' field !!\n", .{});
        return error.PageNameFieldMissing;
    }
}

test "set_design_page input supports optional width/height" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, TOOL_PATH);
    defer allocator.free(source);
    if (!contains(source, "width: ?i64")) {
        std.debug.print("!! SetDesignPageInput is missing the 'width: ?i64' field !!\n", .{});
        return error.WidthFieldMissing;
    }
    if (!contains(source, "height: ?i64")) {
        std.debug.print("!! SetDesignPageInput is missing the 'height: ?i64' field !!\n", .{});
        return error.HeightFieldMissing;
    }
}

test "set_design_page description mentions idempotent behavior" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, TOOL_PATH);
    defer allocator.free(source);
    // The description must mention idempotency — the v6 dual-semantics
    // design (create + list) requires the LLM to understand that
    // re-issuing the call doesn't break.
    if (!contains(source, "idempotent")) {
        std.debug.print("!! set_design_page description does not mention 'idempotent' behavior !!\n", .{});
        return error.IdempotentHintMissing;
    }
}

// ─── Static wiring tests ─────────────────────────────────────────────────

test "tools_equipped.zig imports set_design_page module" {
    // After deduplication of `UNIFIED_TOOL_REGISTRY` (2026-08-06), the
    // registry body lives in `tools_equipped.zig` and no longer lives
    // in `tool_registry.zig`. This test now reads the imports from
    // the canonical home.
    const allocator = testing.allocator;
    const source = try readSource(allocator, TOOLS_EQUIPPED_PATH);
    defer allocator.free(source);
    if (!contains(source, "const set_design_page_mod = nalarcore.set_design_page;")) {
        std.debug.print("!! tools_equipped.zig does not bind set_design_page_mod = nalarcore.set_design_page !!\n", .{});
        return error.SetDesignPageModBindingMissing;
    }
}

test "agentic_loop defines execSetDesignPage" {
    // After the migration, the exec function lives in
    // `tools_exec_set_design_page.zig` (re-exported via
    // `agentic_loop_mod.tools.execSetDesignPage`).
    const allocator = testing.allocator;
    const source = try readSource(allocator, TOOL_EXEC_PATH);
    defer allocator.free(source);
    if (!contains(source, "pub fn execSetDesignPage(")) {
        std.debug.print("!! tools_exec_set_design_page.zig does not define pub fn execSetDesignPage !!\n", .{});
        return error.ExecSetDesignPageMissing;
    }
}

test "UNIFIED_TOOL_REGISTRY contains set_design_page entry" {
    // The registry body moved from `tool_registry.zig` (deleted) to
    // `tools_equipped.zig` (canonical home) on 2026-08-06. The test
    // now reads from the canonical file. tools_equipped.zig imports
    // `tools = @import("tools.zig")` directly, so the `.exec` binding
    // is `tools.execSetDesignPage` (NOT `agentic_loop_mod.tools.execSetDesignPage`).
    const allocator = testing.allocator;
    const source = try readSource(allocator, TOOLS_EQUIPPED_PATH);
    defer allocator.free(source);
    if (!contains(source, ".name = \"set_design_page\"")) {
        std.debug.print("!! UNIFIED_TOOL_REGISTRY is missing the set_design_page entry !!\n", .{});
        return error.RegistryEntryMissing;
    }
    if (!contains(source, ".exec = tools.execSetDesignPage")) {
        std.debug.print("!! UNIFIED_TOOL_REGISTRY entry is missing .exec = tools.execSetDesignPage !!\n", .{});
        return error.RegistryExecBindingMissing;
    }
    if (!contains(source, ".tool_def = set_design_page_mod.set_design_page_tool")) {
        std.debug.print("!! UNIFIED_TOOL_REGISTRY entry is missing .tool_def binding !!\n", .{});
        return error.RegistryToolDefBindingMissing;
    }
}

test "allAgentTools comptime list contains set_design_page tool def" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, TOOLS_EQUIPPED_PATH);
    defer allocator.free(source);
    if (!contains(source, "set_design_page_mod.set_design_page_tool,")) {
        std.debug.print("!! tools_equipped.zig comptime list is missing set_design_page_mod.set_design_page_tool !!\n", .{});
        return error.AllAgentToolsEntryMissing;
    }
}

test "root.zig exposes set_design_page module" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, ROOT_PATH);
    defer allocator.free(source);
    if (!contains(source, "pub const set_design_page = @import(\"modules/agent/tools/set_design_page.zig\");")) {
        std.debug.print("!! root.zig does not expose set_design_page as a top-level module !!\n", .{});
        return error.NalarcoreExportMissing;
    }
}

// ─── XML serialization behavioral tests (no DB required) ────────────────

test "toXml on page with no elements produces <page .../>...</page>" {
    const alloc = testing.allocator;
    const page = design_model.DesignPage{
        .id = try alloc.dupe(u8, "page_abc"),
        .workspace_item_id = try alloc.dupe(u8, "item_test"),
        .name = try alloc.dupe(u8, "Login"),
        .workspace_item_task_id = try alloc.dupe(u8, "task_test"),
        .width = 1440,
        .height = 1024,
        .position = 0,
        .created_at = try alloc.dupe(u8, ""),
        .updated_at = try alloc.dupe(u8, ""),
    };
    defer {
        alloc.free(page.id);
        alloc.free(page.workspace_item_id);
        alloc.free(page.name);
        alloc.free(page.workspace_item_task_id);
        alloc.free(page.created_at);
        alloc.free(page.updated_at);
    }
    const xml = try set_design_page.toXml(alloc, page, &.{});
    defer alloc.free(xml);
    try testing.expect(std.mem.startsWith(u8, xml, "<page"));
    try testing.expect(std.mem.endsWith(u8, xml, "</page>"));
    try testing.expect(contains(xml, "id=\"page_abc\""));
    try testing.expect(contains(xml, "name=\"Login\""));
    try testing.expect(contains(xml, "width=\"1440\""));
    try testing.expect(contains(xml, "height=\"1024\""));
    try testing.expect(contains(xml, "position=\"0\""));
    // No <element> blocks for an empty elements slice.
    try testing.expect(!contains(xml, "<element"));
}

test "toXml renders element attributes with v6 fields" {
    const alloc = testing.allocator;
    const page = design_model.DesignPage{
        .id = try alloc.dupe(u8, "page_abc"),
        .workspace_item_id = try alloc.dupe(u8, "item_test"),
        .name = try alloc.dupe(u8, "Login"),
        .workspace_item_task_id = try alloc.dupe(u8, "task_test"),
        .width = 1440,
        .height = 1024,
        .position = 0,
        .created_at = try alloc.dupe(u8, ""),
        .updated_at = try alloc.dupe(u8, ""),
    };
    defer {
        alloc.free(page.id);
        alloc.free(page.workspace_item_id);
        alloc.free(page.name);
        alloc.free(page.workspace_item_task_id);
        alloc.free(page.created_at);
        alloc.free(page.updated_at);
    }
    const elem = design_model.DesignElement{
        .id = try alloc.dupe(u8, "elem_xyz"),
        .page_id = try alloc.dupe(u8, "page_abc"),
        .name = try alloc.dupe(u8, "login-card"),
        .file_path = try alloc.dupe(u8, "/tmp/.nalar/design/Login/login-card.html"),
        .x = 100,
        .y = 200,
        .width = 400,
        .height = 300,
        .z_index = 0,
        .position = 0,
        .elem_type = try alloc.dupe(u8, "rectangle"),
        .rotation = 0.0,
        .fill = try alloc.dupe(u8, "#ffffff"),
        .stroke = try alloc.dupe(u8, ""),
        .stroke_width = 0,
        .corner_radius = 0,
        .opacity = 1.0,
        .text_content = try alloc.dupe(u8, ""),
        .text_style = try alloc.dupe(u8, ""),
        .image_url = try alloc.dupe(u8, ""),
        .parent_id = try alloc.dupe(u8, ""),
        .created_at = try alloc.dupe(u8, ""),
        .updated_at = try alloc.dupe(u8, ""),
    };
    defer design_model.freeElement(alloc, elem);
    const elements = [_]design_model.DesignElement{elem};
    const xml = try set_design_page.toXml(alloc, page, &elements);
    defer alloc.free(xml);
    try testing.expect(contains(xml, "<element"));
    try testing.expect(contains(xml, "id=\"elem_xyz\""));
    try testing.expect(contains(xml, "name=\"login-card\""));
    try testing.expect(contains(xml, "type=\"rectangle\""));
    try testing.expect(contains(xml, "x=\"100\""));
    try testing.expect(contains(xml, "y=\"200\""));
    try testing.expect(contains(xml, "width=\"400\""));
    try testing.expect(contains(xml, "height=\"300\""));
    try testing.expect(contains(xml, "fill=\"#ffffff\""));
    try testing.expect(contains(xml, "file_path="));
    try testing.expect(contains(xml, "parent_id=\"\""));
}

test "toXml renders parent_id for a nested element" {
    const alloc = testing.allocator;
    const page = design_model.DesignPage{
        .id = try alloc.dupe(u8, "page_abc"),
        .workspace_item_id = try alloc.dupe(u8, "item_test"),
        .name = try alloc.dupe(u8, "Login"),
        .workspace_item_task_id = try alloc.dupe(u8, "task_test"),
        .width = 1440,
        .height = 1024,
        .position = 0,
        .created_at = try alloc.dupe(u8, ""),
        .updated_at = try alloc.dupe(u8, ""),
    };
    defer {
        alloc.free(page.id);
        alloc.free(page.workspace_item_id);
        alloc.free(page.name);
        alloc.free(page.workspace_item_task_id);
        alloc.free(page.created_at);
        alloc.free(page.updated_at);
    }
    // A child element parented under elem_parent_1.
    const elem = design_model.DesignElement{
        .id = try alloc.dupe(u8, "elem_child_1"),
        .page_id = try alloc.dupe(u8, "page_abc"),
        .name = try alloc.dupe(u8, "login-button"),
        .file_path = try alloc.dupe(u8, "/tmp/.nalar/design/Login/login-button.html"),
        .x = 10,
        .y = 20,
        .width = 80,
        .height = 30,
        .z_index = 0,
        .position = 1,
        .elem_type = try alloc.dupe(u8, "rectangle"),
        .rotation = 0.0,
        .fill = try alloc.dupe(u8, "#000000"),
        .stroke = try alloc.dupe(u8, ""),
        .stroke_width = 0,
        .corner_radius = 0,
        .opacity = 1.0,
        .text_content = try alloc.dupe(u8, ""),
        .text_style = try alloc.dupe(u8, ""),
        .image_url = try alloc.dupe(u8, ""),
        .parent_id = try alloc.dupe(u8, "elem_parent_1"),
        .created_at = try alloc.dupe(u8, ""),
        .updated_at = try alloc.dupe(u8, ""),
    };
    defer design_model.freeElement(alloc, elem);
    const elements = [_]design_model.DesignElement{elem};
    const xml = try set_design_page.toXml(alloc, page, &elements);
    defer alloc.free(xml);
    try testing.expect(contains(xml, "parent_id=\"elem_parent_1\""));
}

test "errorXml on missing field returns <page><error>...</error></page>" {
    const alloc = testing.allocator;
    const xml = try set_design_page.errorXml(alloc, "item_id is required");
    defer alloc.free(xml);
    try testing.expect(std.mem.startsWith(u8, xml, "<page>"));
    try testing.expect(std.mem.endsWith(u8, xml, "</page>"));
    try testing.expect(contains(xml, "<error>"));
    try testing.expect(contains(xml, "item_id is required"));
}

// ─── DB integration behavioral tests (in-memory SQLite) ────────────────

/// Set up an in-memory SQLite with the v6 design schema (workspace_items
/// + design_pages + design_page_elements with the 11 Migration 057
/// columns). Creates one workspace item with `path='/tmp'` so
/// `setDesignPage` doesn't return `ItemPathMissing`.
///
/// Returns the db + threaded as a value (not a pointer) so the
/// caller's `var s = try setupDb();` can pass `&s.db` to
/// non-const-`*SqliteBackend` parameters.
fn setupDb() !struct { db: sqlite.SqliteBackend, threaded: std.Io.Threaded, item_id: []u8, item_path: []u8 } {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    errdefer threaded.deinit();
    const io = threaded.io();
    var db: sqlite.SqliteBackend = .{};
    errdefer db.deinit();
    try db.init(io, ":memory:");

    // workspace_items.
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

    // design_pages (v6 schema).
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

    // design_page_elements (v6 schema).
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

    // Real tempdir for path (setDesignPage needs a non-empty path so
    // its `ItemPathMissing` early-return doesn't fire).
    var tmp = testing.tmpDir(.{});
    var tmpdir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmpdir_len = try tmp.dir.realPath(testing.io, &tmpdir_buf);
    const tmpdir_path = try alloc.dupe(u8, tmpdir_buf[0..tmpdir_len]);

    const item_id_str = "item_design_1";
    try db.exec(alloc,
        "INSERT INTO workspace_items (id, workspace_id, item_type, name, path) " ++
        "VALUES (?, 'ws_test', 'design', 'Test Design', ?)",
        &.{ item_id_str, tmpdir_path });

    return .{
        .db = db,
        .threaded = threaded,
        .item_id = try alloc.dupe(u8, item_id_str),
        .item_path = tmpdir_path,
    };
}

test "executeSetDesignPageToString creates a page when none exists" {
    const alloc = testing.allocator;
    var s = try setupDb();
    defer s.threaded.deinit();
    defer s.db.deinit();
    defer alloc.free(s.item_id);
    defer alloc.free(s.item_path);

    const input = set_design_page.SetDesignPageInput{
        .item_id = s.item_id,
        .page_name = "Login",
    };
    const xml = try set_design_page.executeSetDesignPageToString(alloc, &s.db, input);
    defer alloc.free(xml);

    try testing.expect(std.mem.startsWith(u8, xml, "<page"));
    try testing.expect(std.mem.endsWith(u8, xml, "</page>"));
    try testing.expect(contains(xml, "id=\"page_"));
    try testing.expect(contains(xml, "name=\"Login\""));
    try testing.expect(contains(xml, "width=\"1440\""));
    try testing.expect(contains(xml, "height=\"1024\""));
    try testing.expect(!contains(xml, "<error>"));
}

test "executeSetDesignPageToString is idempotent on second call with same name" {
    const alloc = testing.allocator;
    var s = try setupDb();
    defer s.threaded.deinit();
    defer s.db.deinit();
    defer alloc.free(s.item_id);
    defer alloc.free(s.item_path);

    const input = set_design_page.SetDesignPageInput{
        .item_id = s.item_id,
        .page_name = "Login",
        .width = 800,
        .height = 600,
    };
    const xml1 = try set_design_page.executeSetDesignPageToString(alloc, &s.db, input);
    defer alloc.free(xml1);
    try testing.expect(contains(xml1, "width=\"800\""));
    try testing.expect(contains(xml1, "height=\"600\""));

    // Second call with same name → must reuse the same page id (idempotent
    // upsert via setDesignPage), and pick up the new dimensions.
    const input2 = set_design_page.SetDesignPageInput{
        .item_id = s.item_id,
        .page_name = "Login",
        .width = 1920,
        .height = 1080,
    };
    const xml2 = try set_design_page.executeSetDesignPageToString(alloc, &s.db, input2);
    defer alloc.free(xml2);
    try testing.expect(contains(xml2, "width=\"1920\""));
    try testing.expect(contains(xml2, "height=\"1080\""));

    // The page id should be the same between the two calls — extract
    // the id="..." value and compare.
    const id_start1 = (std.mem.indexOf(u8, xml1, "id=\"") orelse 0) + 4;
    const id_end1 = std.mem.indexOf(u8, xml1[id_start1..], "\"") orelse xml1.len;
    const id1 = xml1[id_start1..][0..id_end1];

    const id_start2 = (std.mem.indexOf(u8, xml2, "id=\"") orelse 0) + 4;
    const id_end2 = std.mem.indexOf(u8, xml2[id_start2..], "\"") orelse xml2.len;
    const id2 = xml2[id_start2..][0..id_end2];

    try testing.expect(std.mem.eql(u8, id1, id2));
}

test "executeSetDesignPageToString returns error XML when item_id is empty" {
    const alloc = testing.allocator;
    var s = try setupDb();
    defer s.threaded.deinit();
    defer s.db.deinit();
    defer alloc.free(s.item_id);
    defer alloc.free(s.item_path);

    const input = set_design_page.SetDesignPageInput{
        .item_id = "",
        .page_name = "Login",
    };
    const xml = try set_design_page.executeSetDesignPageToString(alloc, &s.db, input);
    defer alloc.free(xml);
    try testing.expect(contains(xml, "<error>"));
    try testing.expect(contains(xml, "item_id"));
}

test "executeSetDesignPageToString returns error XML when item_id looks like a task_id" {
    const alloc = testing.allocator;
    var s = try setupDb();
    defer s.threaded.deinit();
    defer s.db.deinit();
    defer alloc.free(s.item_id);
    defer alloc.free(s.item_path);

    const input = set_design_page.SetDesignPageInput{
        .item_id = "task_1782442569739",
        .page_name = "Login",
    };
    const xml = try set_design_page.executeSetDesignPageToString(alloc, &s.db, input);
    defer alloc.free(xml);
    try testing.expect(contains(xml, "<error>"));
    try testing.expect(contains(xml, "task_"));
    // Should mention the correct id source so the LLM self-corrects.
    try testing.expect(contains(xml, "item_"));
}

test "executeSetDesignPageToString returns error XML when item_id looks like a page_id" {
    const alloc = testing.allocator;
    var s = try setupDb();
    defer s.threaded.deinit();
    defer s.db.deinit();
    defer alloc.free(s.item_id);
    defer alloc.free(s.item_path);

    const input = set_design_page.SetDesignPageInput{
        .item_id = "page_1782442554112",
        .page_name = "Login",
    };
    const xml = try set_design_page.executeSetDesignPageToString(alloc, &s.db, input);
    defer alloc.free(xml);
    try testing.expect(contains(xml, "<error>"));
    try testing.expect(contains(xml, "page_"));
}

test "executeSetDesignPageToString returns error XML when item_id looks like an elem_id" {
    const alloc = testing.allocator;
    var s = try setupDb();
    defer s.threaded.deinit();
    defer s.db.deinit();
    defer alloc.free(s.item_id);
    defer alloc.free(s.item_path);

    const input = set_design_page.SetDesignPageInput{
        .item_id = "elem_1782442554112",
        .page_name = "Login",
    };
    const xml = try set_design_page.executeSetDesignPageToString(alloc, &s.db, input);
    defer alloc.free(xml);
    try testing.expect(contains(xml, "<error>"));
    try testing.expect(contains(xml, "elem_"));
}

test "executeSetDesignPageToString returns error XML when item_id looks like a workspace_id" {
    const alloc = testing.allocator;
    var s = try setupDb();
    defer s.threaded.deinit();
    defer s.db.deinit();
    defer alloc.free(s.item_id);
    defer alloc.free(s.item_path);

    const input = set_design_page.SetDesignPageInput{
        .item_id = "ws_test",
        .page_name = "Login",
    };
    const xml = try set_design_page.executeSetDesignPageToString(alloc, &s.db, input);
    defer alloc.free(xml);
    try testing.expect(contains(xml, "<error>"));
}

test "executeSetDesignPageToString returns error XML when item_id has unrecognized prefix" {
    const alloc = testing.allocator;
    var s = try setupDb();
    defer s.threaded.deinit();
    defer s.db.deinit();
    defer alloc.free(s.item_id);
    defer alloc.free(s.item_path);

    const input = set_design_page.SetDesignPageInput{
        .item_id = "foo_123",
        .page_name = "Login",
    };
    const xml = try set_design_page.executeSetDesignPageToString(alloc, &s.db, input);
    defer alloc.free(xml);
    try testing.expect(contains(xml, "<error>"));
    try testing.expect(contains(xml, "unrecognized"));
}

test "executeSetDesignPageToString returns error XML when page_name is empty" {
    const alloc = testing.allocator;
    var s = try setupDb();
    defer s.threaded.deinit();
    defer s.db.deinit();
    defer alloc.free(s.item_id);
    defer alloc.free(s.item_path);

    const input = set_design_page.SetDesignPageInput{
        .item_id = s.item_id,
        .page_name = "",
    };
    const xml = try set_design_page.executeSetDesignPageToString(alloc, &s.db, input);
    defer alloc.free(xml);
    try testing.expect(contains(xml, "<error>"));
    try testing.expect(contains(xml, "page_name"));
}

test "executeSetDesignPageToString returns error XML when page_name contains '/'" {
    const alloc = testing.allocator;
    var s = try setupDb();
    defer s.threaded.deinit();
    defer s.db.deinit();
    defer alloc.free(s.item_id);
    defer alloc.free(s.item_path);

    const input = set_design_page.SetDesignPageInput{
        .item_id = s.item_id,
        .page_name = "Login/Foo",
    };
    const xml = try set_design_page.executeSetDesignPageToString(alloc, &s.db, input);
    defer alloc.free(xml);
    try testing.expect(contains(xml, "<error>"));
    try testing.expect(contains(xml, "/"));
}

test "executeSetDesignPageToString returns ItemPathMissing error when item has no path" {
    const alloc = testing.allocator;
    var s = try setupDb();
    defer s.threaded.deinit();
    defer s.db.deinit();
    defer alloc.free(s.item_id);
    defer alloc.free(s.item_path);

    // Insert a second design item WITHOUT a path.
    try s.db.exec(alloc,
        "INSERT INTO workspace_items (id, workspace_id, item_type, name, path) " ++
        "VALUES ('item_no_path', 'ws_test', 'design', 'No path', '')",
        &.{});

    const input = set_design_page.SetDesignPageInput{
        .item_id = "item_no_path",
        .page_name = "Login",
    };
    const xml = try set_design_page.executeSetDesignPageToString(alloc, &s.db, input);
    defer alloc.free(xml);
    try testing.expect(contains(xml, "<error>"));
    try testing.expect(contains(xml, "no path"));
    try testing.expect(contains(xml, "AddDesignDialog"));
}
