//! LLM tool: `get_design_context` — read-only inspection of a design canvas.
//!
//! Pass EITHER `page_id` to get one page with its elements, OR
//! `workspace_item_id` to get ALL pages of the design item. Exactly one of
//! the two must be provided.
//!
//! Returns a JSON object mirroring the design DB wire shape (every element
//! field the agent needs for layout reasoning is a key).
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
const helpers = @import("helpers");
const sanitizeControlChars = helpers.sanitize_control_chars;

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
        \\Returns a JSON object:
        \\
        \\{"pages": [{"id": "page_X", "name": "Login", "width": 1440,
        \\"height": 1024, "position": 0, "elements": [{"id": "elem_Y",
        \\"page_id": "page_X", "name": "...", "type": "rectangle",
        \\"x": ..., "y": ..., "width": ..., "height": ...,
        \\"rotation": ..., "fill": ..., "stroke": ...,
        \\"corner_radius": ..., "opacity": ..., "text_content": ...,
        \\"image_url": ..., "parent_id": ..., "file_path": ...,
        \\"z_index": ..., "position": ..., "created_at": ...,
        \\"updated_at": ...}]}]}
        \\
        \\Each element key matches the design DB row wire shape (so the agent can spot `x`/`y`/`width`/`height` for layout, `parent_id` for grouping, `text_content` for content).
        \\
        \\HTML bodies are intentionally NOT included — the agent can read them individually with `read_file` if needed. If the page has no HTML bodies yet, use `add_element` (or `set_design_page` to create the page) first.
        \\
        \\On error, the response is `{"error":...}`.
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

// ─── JSON helpers ────

fn errorJSON(allocator: std.mem.Allocator, error_msg: []const u8) ![]u8 {
    const clean = try sanitizeControlChars(allocator, error_msg);
    defer allocator.free(clean);
    return try std.json.Stringify.valueAlloc(allocator, .{ .@"error" = clean }, .{});
}

// ─── Execute ─────────────────────────────────────────────────────────────

/// Execute `get_design_context`.
///
/// Returns a JSON object:
///   - success: `{"pages":[...]}`
///   - error:   `{"error":...}`
///
/// The error form is detectable by the exec wrapper via the top-level
/// `error` key (matches the convention used by `set_design_page`).
pub fn executeGetDesignContextToString(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    input: GetDesignContextInput,
) ![]u8 {
    // 1. Validate exactly-one of the two ids.
    const page_id_present = input.page_id != null and input.page_id.?.len > 0;
    const item_id_present = input.workspace_item_id != null and input.workspace_item_id.?.len > 0;
    if (page_id_present == item_id_present) {
        return try errorJSON(
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
        return try errorJSON(allocator, msg);
    };
    defer bundle.deinit(allocator);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const page = try contextPageJSON(a, bundle.page, bundle.elements);
    const pages = [_]ContextPageJSON{page};
    return try std.json.Stringify.valueAlloc(allocator, .{ .pages = pages }, .{});
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
        return try errorJSON(allocator, msg);
    };
    defer design_model.freePagesWithElements(allocator, pages);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var out: std.ArrayList(ContextPageJSON) = .empty;
    for (pages) |*page| {
        try out.append(a, try contextPageJSON(a, page.page, page.elements));
    }
    return try std.json.Stringify.valueAlloc(allocator, .{ .pages = out.items }, .{});
}

/// JSON page object (keys mirror the old `<page ...>` attributes 1:1;
/// repeated `<element>` children become the `elements` array).
pub const ContextPageJSON = struct {
    id: []const u8,
    name: []const u8,
    width: i64,
    height: i64,
    position: i64,
    elements: []ContextElementJSON,
};

/// JSON element object (keys mirror the old `<element ... />` attributes
/// 1:1; attributes rendered-when-empty become explicit nulls).
pub const ContextElementJSON = struct {
    id: []const u8,
    page_id: []const u8,
    name: []const u8,
    file_path: ?[]const u8,
    x: i64,
    y: i64,
    width: i64,
    height: i64,
    z_index: i64,
    position: i64,
    type: []const u8,
    rotation: f64,
    opacity: f64,
    fill: ?[]const u8,
    stroke: ?[]const u8,
    stroke_width: i64,
    corner_radius: i64,
    text_content: ?[]const u8,
    text_style: ?[]const u8,
    image_url: ?[]const u8,
    parent_id: ?[]const u8,
    created_at: ?[]const u8,
    updated_at: ?[]const u8,
};

fn contextPageJSON(
    allocator: std.mem.Allocator,
    page: design_model.DesignPage,
    elements: []const design_model.DesignElement,
) !ContextPageJSON {
    var out: std.ArrayList(ContextElementJSON) = .empty;
    for (elements) |e| {
        try out.append(allocator, try contextElementJSON(allocator, e));
    }
    return .{
        .id = try sanitizeControlChars(allocator, page.id),
        .name = try sanitizeControlChars(allocator, page.name),
        .width = page.width,
        .height = page.height,
        .position = page.position,
        .elements = out.items,
    };
}

fn contextElementJSON(
    allocator: std.mem.Allocator,
    e: design_model.DesignElement,
) !ContextElementJSON {
    return .{
        .id = try sanitizeControlChars(allocator, e.id),
        .page_id = try sanitizeControlChars(allocator, e.page_id),
        .name = try sanitizeControlChars(allocator, e.name),
        .file_path = try optClean(allocator, e.file_path),
        .x = e.x,
        .y = e.y,
        .width = e.width,
        .height = e.height,
        .z_index = e.z_index,
        .position = e.position,
        .type = try sanitizeControlChars(allocator, e.elem_type),
        .rotation = e.rotation,
        .opacity = e.opacity,
        .fill = try optClean(allocator, e.fill),
        .stroke = try optClean(allocator, e.stroke),
        .stroke_width = e.stroke_width,
        .corner_radius = e.corner_radius,
        .text_content = try optClean(allocator, e.text_content),
        .text_style = try optClean(allocator, e.text_style),
        .image_url = try optClean(allocator, e.image_url),
        .parent_id = try optClean(allocator, e.parent_id),
        .created_at = try optClean(allocator, e.created_at),
        .updated_at = try optClean(allocator, e.updated_at),
    };
}

/// Clean an optional free-text field: empty becomes null, otherwise the
/// control-char-sanitized copy owned by the caller's arena.
fn optClean(allocator: std.mem.Allocator, s: []const u8) !?[]u8 {
    if (s.len == 0) return null;
    return try sanitizeControlChars(allocator, s);
}
