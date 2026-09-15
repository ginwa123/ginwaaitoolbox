//! LLM tool: `preview_design_page` — render a design page as an SVG
//! preview so the agent can SEE it.
//!
//! Takes `page_id` (required) and an optional `scale` (default 1.0, max 4.0).
//! Generates an SVG that renders every element on the page using their
//! design coordinates + visual properties, then wraps the metadata in a
//! `<show_preview>` envelope (legacy envelope name kept for wire compat;
//! content_type="html").
//!
//! Per-element rendering:
//!   - `rectangle` → `<rect>` with fill, stroke, corner_radius, rotation
//!   - `ellipse`   → `<ellipse>` with cx, cy, rx, ry
//!   - `text`      → `<text>` with text_content (y = baseline = y + height)
//!   - `image`     → `<image>` with href from image_url
//!   - `frame`/`group` → `<g>` container; children render inside via
//!     recursive descent
//!
//! Plan: docs/superpowers/plans/2026-08-06-ai-agent-design-context-tool.md (Chunk 2)

const std = @import("std");
const schemas = @import("schemas.zig");
const AgentTool = schemas.AgentTool;
const nalarcore = @import("nalarcore");
const sqlite = nalarcore.sqlite;
const design_model = nalarcore.ai_mod.design_model;

/// Hex alphabet for the random suffix of the preview id (kept local —
/// tool files are self-contained per project convention).
const HEX_DIGITS = "0123456789abcdef";

/// Maximum scale the agent can request. Caps the SVG's pixel dimensions
/// so a malicious or well-meaning LLM can't request a 1000x page scaled to
/// 100,000 px and OOM the side panel renderer.
pub const MAX_SCALE: f64 = 4.0;

/// Input structure for `preview_design_page` tool.
pub const PreviewDesignPageInput = struct {
    /// The design page to render. Required.
    page_id: []const u8 = "",
    /// Scale factor applied to the SVG viewBox AND every element
    /// coordinate. Default 1.0 (1:1 with the design viewport). Max 4.0.
    /// Use 0.5 for a "see the whole page at a glance" preview, 1.0 for
    /// the design viewport, 2.0 for "zoomed in to inspect details".
    scale: f64 = 1.0,
};

/// Top-level tool definition for the LLM.
pub const preview_design_page_tool_system_prompt =
    \\## Preview Design Page Tool — Behavior
    \\Use `preview_design_page` to render a design page as SVG in the side panel.
    \\- Provide `page_id` and optional `scale`. Use to visually verify layout after edits.
    \\
;

pub const preview_design_page_tool = AgentTool{
    .type = "function",
    .function = .{
        .name = "preview_design_page",
        .description =
            \\Render a design page as an SVG in the side panel so the agent can SEE the design (the "screenshot" tool). Pass `page_id` (required) and an optional `scale` (default 1.0, max 4.0).
            \\
            \\Each element renders as the matching SVG shape:
            \\  - `rectangle` → `<rect>` with fill, stroke, corner_radius, rotation
            \\  - `ellipse`   → `<ellipse>` with cx, cy, rx, ry
            \\  - `text`      → `<text>` with x, y (baseline = y + height), text_content
            \\  - `image`     → `<image>` with href from image_url
            \\  - `frame`/`group` → `<g>` container; children render inside
            \\
            \\Groups/frames nest recursively — a group inside a frame renders inside the frame's `<g>`, etc.
            \\
            \\Returns a `<show_preview>` envelope (legacy name, content_type="html") carrying the preview_id so the transcript can reference the render.
        ,
        .parameters = .{
            .type = "object",
            .properties = &.{
                .{
                    .name = "page_id",
                    .type = "string",
                    .description = "The design page id to render. Find it from `get_design_context` output, or use `set_design_page` first to create one.",
                },
                .{
                    .name = "scale",
                    .type = "number",
                    .description = "Scale factor applied to the SVG viewBox and every element coordinate. Default 1.0 (matches the design viewport). Range: 0.1 to 4.0. Use smaller values to fit a large page, larger values to zoom in.",
                },
            },
            .required = &.{ "page_id" },
        },
        .system_prompt = preview_design_page_tool_system_prompt,
    },
};

// ─── XML / SVG helpers (local — project convention is per-file duplication) ────

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

    try xml.appendSlice(allocator, "<show_preview><error>");
    const escaped = try xmlEscape(allocator, error_msg);
    defer allocator.free(escaped);
    try xml.appendSlice(allocator, escaped);
    try xml.appendSlice(allocator, "</error></show_preview>");
    return try xml.toOwnedSlice(allocator);
}

/// Generate a unique preview id of the form `pv_<unix_ms>_<6 hex>`.
/// Self-contained copy of the id scheme the deleted `show_preview` tool
/// used, so this tool no longer depends on it. Caller owns the slice.
fn generatePreviewId(allocator: std.mem.Allocator, io: std.Io) ![]u8 {
    const ts = std.Io.Clock.now(.real, io);
    const unix_ms = ts.toMilliseconds();
    var random_bytes: [3]u8 = undefined;
    io.random(&random_bytes);
    var hex: [6]u8 = undefined;
    for (random_bytes, 0..) |b, i| {
        hex[i * 2] = HEX_DIGITS[b >> 4];
        hex[i * 2 + 1] = HEX_DIGITS[b & 0xF];
    }
    return std.fmt.allocPrint(allocator, "pv_{d}_{s}", .{ unix_ms, &hex });
}

/// Build the success envelope `<show_preview><status>shown</status>...`.
/// Self-contained copy of the envelope the deleted `show_preview` tool
/// used (tag name kept for wire compat). Caller owns the slice.
fn successEnvelope(
    allocator: std.mem.Allocator,
    preview_id: []const u8,
    content_type: []const u8,
    content_length: usize,
) ![]u8 {
    var xml: std.ArrayList(u8) = .empty;
    errdefer xml.deinit(allocator);
    try xml.appendSlice(allocator, "<show_preview>");
    try xml.appendSlice(allocator, "<status>shown</status>");
    const eid = try xmlEscape(allocator, preview_id);
    defer allocator.free(eid);
    try xml.appendSlice(allocator, "<preview_id>");
    try xml.appendSlice(allocator, eid);
    try xml.appendSlice(allocator, "</preview_id>");
    const ect = try xmlEscape(allocator, content_type);
    defer allocator.free(ect);
    try xml.appendSlice(allocator, "<content_type>");
    try xml.appendSlice(allocator, ect);
    try xml.appendSlice(allocator, "</content_type>");
    var len_buf: [32]u8 = undefined;
    const len_str = std.fmt.bufPrint(&len_buf, "{d}", .{content_length}) catch unreachable;
    try xml.appendSlice(allocator, "<content_length>");
    try xml.appendSlice(allocator, len_str);
    try xml.appendSlice(allocator, "</content_length>");
    try xml.appendSlice(allocator, "</show_preview>");
    return try xml.toOwnedSlice(allocator);
}

// ─── Build SVG ───────────────────────────────────────────────────────────

/// Render the page's elements as a self-contained SVG document.
///
/// `scale` is applied to the viewBox AND every coordinate. The page
/// background is a white rectangle so the SVG renders on a non-transparent
/// background (matches what the design canvas looks like in the UI).
fn buildSvg(
    allocator: std.mem.Allocator,
    page: design_model.DesignPage,
    elements: []const design_model.DesignElement,
    scale: f64,
) ![]u8 {
    var svg: std.ArrayList(u8) = .empty;
    errdefer svg.deinit(allocator);

    const w = @as(i64, @intFromFloat(@as(f64, @floatFromInt(page.width)) * scale));
    const h = @as(i64, @intFromFloat(@as(f64, @floatFromInt(page.height)) * scale));

    try svg.appendSlice(allocator,
        \\<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0
    );
    var wbuf: [32]u8 = undefined;
    try svg.appendSlice(allocator, std.fmt.bufPrint(&wbuf, "{d}", .{w}) catch "0");
    try svg.appendSlice(allocator, " ");
    var hbuf: [32]u8 = undefined;
    try svg.appendSlice(allocator, std.fmt.bufPrint(&hbuf, "{d}", .{h}) catch "0");
    try svg.appendSlice(allocator, "\" width=\"");
    try svg.appendSlice(allocator, std.fmt.bufPrint(&wbuf, "{d}", .{w}) catch "0");
    try svg.appendSlice(allocator, "\" height=\"");
    try svg.appendSlice(allocator, std.fmt.bufPrint(&hbuf, "{d}", .{h}) catch "0");
    try svg.appendSlice(allocator, "\" preserveAspectRatio=\"xMidYMid meet\">");

    // White page background
    try svg.appendSlice(allocator, "<rect x=\"0\" y=\"0\" width=\"");
    try svg.appendSlice(allocator, std.fmt.bufPrint(&wbuf, "{d}", .{w}) catch "0");
    try svg.appendSlice(allocator, "\" height=\"");
    try svg.appendSlice(allocator, std.fmt.bufPrint(&hbuf, "{d}", .{h}) catch "0");
    try svg.appendSlice(allocator, "\" fill=\"#ffffff\" />");

    // Find top-level elements (parent_id empty) and render in z_index/position order.
    // Each top-level may recursively render its children inside its <g>.
    for (elements) |e| {
        if (e.parent_id.len > 0) continue; // belongs to a parent — skip at top level
        try renderElement(allocator, &svg, e, elements, scale, 0);
    }

    try svg.appendSlice(allocator, "</svg>");
    return try svg.toOwnedSlice(allocator);
}

fn renderElement(
    allocator: std.mem.Allocator,
    svg: *std.ArrayList(u8),
    e: design_model.DesignElement,
    all_elements: []const design_model.DesignElement,
    scale: f64,
    depth: usize,
) !void {
    // Guard against pathological nesting (shouldn't happen — cycle preflight
    //     rejects cycles — but defensive).
    if (depth > 32) return;

    // Convert design coords to scaled SVG coords
    const x = @as(i64, @intFromFloat(@as(f64, @floatFromInt(e.x)) * scale));
    const y = @as(i64, @intFromFloat(@as(f64, @floatFromInt(e.y)) * scale));
    const w = @as(i64, @intFromFloat(@as(f64, @floatFromInt(e.width)) * scale));
    const h = @as(i64, @intFromFloat(@as(f64, @floatFromInt(e.height)) * scale));

    // Containers (frame, group) wrap their children in a <g>
    const is_container = std.mem.eql(u8, e.elem_type, "frame") or
        std.mem.eql(u8, e.elem_type, "group");

    if (is_container) {
        try svg.appendSlice(allocator, "<g");
        try appendBoundsAttrs(svg, allocator, x, y, w, h);
        try appendFillStroke(svg, allocator, e, scale);
        if (e.opacity != 1.0) try appendOpacity(svg, allocator, e.opacity);
        try svg.appendSlice(allocator, ">");

        // Render children (parent_id == this element's id)
        const child_id_buf = try std.fmt.allocPrint(allocator, "elem_{s}", .{e.name});
        defer allocator.free(child_id_buf);
        for (all_elements) |child| {
            if (!std.mem.eql(u8, child.parent_id, e.id)) continue;
            try renderElement(allocator, svg, child, all_elements, scale, depth + 1);
        }

        try svg.appendSlice(allocator, "</g>");
        return;
    }

    // Leaf types
    if (std.mem.eql(u8, e.elem_type, "rectangle")) {
        try svg.appendSlice(allocator, "<rect");
        try appendBoundsAttrs(svg, allocator, x, y, w, h);
        if (e.corner_radius > 0) {
            const cr = @as(i64, @intFromFloat(@as(f64, @floatFromInt(e.corner_radius)) * scale));
            var crbuf: [32]u8 = undefined;
            try svg.appendSlice(allocator, " rx=\"");
            try svg.appendSlice(allocator, std.fmt.bufPrint(&crbuf, "{d}", .{cr}) catch "0");
            try svg.appendSlice(allocator, "\"");
        }
        try appendFillStroke(svg, allocator, e, scale);
        if (e.opacity != 1.0) try appendOpacity(svg, allocator, e.opacity);
        if (e.rotation != 0.0) try appendRotation(svg, allocator, e.x, e.y, h, e.rotation, scale);
        try svg.appendSlice(allocator, " />");
    } else if (std.mem.eql(u8, e.elem_type, "ellipse")) {
        const cx = x + @divTrunc(w, 2);
        const cy = y + @divTrunc(h, 2);
        const rx = @divTrunc(w, 2);
        const ry = @divTrunc(h, 2);
        try svg.appendSlice(allocator, "<ellipse");
        var buf: [32]u8 = undefined;
        try svg.appendSlice(allocator, " cx=\"");
        try svg.appendSlice(allocator, std.fmt.bufPrint(&buf, "{d}", .{cx}) catch "0");
        try svg.appendSlice(allocator, "\" cy=\"");
        try svg.appendSlice(allocator, std.fmt.bufPrint(&buf, "{d}", .{cy}) catch "0");
        try svg.appendSlice(allocator, "\" rx=\"");
        try svg.appendSlice(allocator, std.fmt.bufPrint(&buf, "{d}", .{rx}) catch "0");
        try svg.appendSlice(allocator, "\" ry=\"");
        try svg.appendSlice(allocator, std.fmt.bufPrint(&buf, "{d}", .{ry}) catch "0");
        try svg.appendSlice(allocator, "\"");
        try appendFillStroke(svg, allocator, e, scale);
        if (e.opacity != 1.0) try appendOpacity(svg, allocator, e.opacity);
        try svg.appendSlice(allocator, " />");
    } else if (std.mem.eql(u8, e.elem_type, "text")) {
        // Render Y baseline as y + height (so the text sits INSIDE the bbox)
        const baseline = y + h;
        try svg.appendSlice(allocator, "<text");
        var buf: [32]u8 = undefined;
        try svg.appendSlice(allocator, " x=\"");
        try svg.appendSlice(allocator, std.fmt.bufPrint(&buf, "{d}", .{x}) catch "0");
        try svg.appendSlice(allocator, "\" y=\"");
        try svg.appendSlice(allocator, std.fmt.bufPrint(&buf, "{d}", .{baseline}) catch "0");
        try svg.appendSlice(allocator, "\" font-family=\"sans-serif\"");
        // SVG font size scales with bbox height; min 8 to keep small text legible
        const font_size = @max(@as(i64, 8), h);
        try svg.appendSlice(allocator, " font-size=\"");
        try svg.appendSlice(allocator, std.fmt.bufPrint(&buf, "{d}", .{font_size}) catch "0");
        try svg.appendSlice(allocator, "\"");
        if (e.fill.len > 0) {
            const v = try xmlEscape(allocator, e.fill);
            defer allocator.free(v);
            try svg.appendSlice(allocator, " fill=\"");
            try svg.appendSlice(allocator, v);
            try svg.appendSlice(allocator, "\"");
        } else {
            try svg.appendSlice(allocator, " fill=\"#000000\"");
        }
        if (e.opacity != 1.0) try appendOpacity(svg, allocator, e.opacity);
        try svg.appendSlice(allocator, ">");
        if (e.text_content.len > 0) {
            const v = try xmlEscape(allocator, e.text_content);
            defer allocator.free(v);
            try svg.appendSlice(allocator, v);
        }
        try svg.appendSlice(allocator, "</text>");
    } else if (std.mem.eql(u8, e.elem_type, "image")) {
        try svg.appendSlice(allocator, "<image");
        try appendBoundsAttrs(svg, allocator, x, y, w, h);
        if (e.image_url.len > 0) {
            const v = try xmlEscape(allocator, e.image_url);
            defer allocator.free(v);
            try svg.appendSlice(allocator, " href=\"");
            try svg.appendSlice(allocator, v);
            try svg.appendSlice(allocator, "\"");
        }
        if (e.opacity != 1.0) try appendOpacity(svg, allocator, e.opacity);
        try svg.appendSlice(allocator, " />");
    } else {
        // Unknown type — render as a labeled outlined rectangle so the agent
        // sees SOMETHING instead of nothing. Avoids silent drops.
        try svg.appendSlice(allocator, "<rect");
        try appendBoundsAttrs(svg, allocator, x, y, w, h);
        try svg.appendSlice(allocator, " fill=\"#eeeeee\" stroke=\"#999999\"");
        try svg.appendSlice(allocator, " />");
    }
}

fn appendBoundsAttrs(
    svg: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    x: i64,
    y: i64,
    w: i64,
    h: i64,
) !void {
    var buf: [32]u8 = undefined;
    try svg.appendSlice(allocator, " x=\"");
    try svg.appendSlice(allocator, std.fmt.bufPrint(&buf, "{d}", .{x}) catch "0");
    try svg.appendSlice(allocator, "\" y=\"");
    try svg.appendSlice(allocator, std.fmt.bufPrint(&buf, "{d}", .{y}) catch "0");
    try svg.appendSlice(allocator, "\" width=\"");
    try svg.appendSlice(allocator, std.fmt.bufPrint(&buf, "{d}", .{w}) catch "0");
    try svg.appendSlice(allocator, "\" height=\"");
    try svg.appendSlice(allocator, std.fmt.bufPrint(&buf, "{d}", .{h}) catch "0");
    try svg.appendSlice(allocator, "\"");
}

fn appendFillStroke(
    svg: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    e: design_model.DesignElement,
    scale: f64,
) !void {
    const fill = if (e.fill.len > 0) e.fill else "transparent";
    const fill_escaped = try xmlEscape(allocator, fill);
    defer allocator.free(fill_escaped);
    try svg.appendSlice(allocator, " fill=\"");
    try svg.appendSlice(allocator, fill_escaped);
    try svg.appendSlice(allocator, "\"");

    if (e.stroke.len > 0) {
        const stroke_escaped = try xmlEscape(allocator, e.stroke);
        defer allocator.free(stroke_escaped);
        try svg.appendSlice(allocator, " stroke=\"");
        try svg.appendSlice(allocator, stroke_escaped);
        try svg.appendSlice(allocator, "\"");
        if (e.stroke_width > 0) {
            const sw = @as(i64, @intFromFloat(@as(f64, @floatFromInt(e.stroke_width)) * scale));
            var buf: [32]u8 = undefined;
            try svg.appendSlice(allocator, " stroke-width=\"");
            try svg.appendSlice(allocator, std.fmt.bufPrint(&buf, "{d}", .{sw}) catch "0");
            try svg.appendSlice(allocator, "\"");
        }
    }
}

fn appendOpacity(
    svg: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    opacity: f64,
) !void {
    var buf: [64]u8 = undefined;
    try svg.appendSlice(allocator, " opacity=\"");
    try svg.appendSlice(allocator, std.fmt.bufPrint(&buf, "{d:.6}", .{opacity}) catch "0");
    try svg.appendSlice(allocator, "\"");
}

fn appendRotation(
    svg: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    cx: i64,
    cy: i64,
    h: i64,
    rotation: f64,
    scale: f64,
) !void {
    // SVG rotation: rotate(angle, cx, cy), where (cx, cy) is the bbox
    // center in the parent coord space.
    const center_x = @as(i64, @intFromFloat(@as(f64, @floatFromInt(cx)) * scale));
    const center_y = @as(i64, @intFromFloat(@as(f64, @floatFromInt(cy)) * scale)) +
        @divTrunc(@as(i64, @intFromFloat(@as(f64, @floatFromInt(h)) * scale)), 2);
    var buf: [64]u8 = undefined;
    const deg = rotation * 180.0 / std.math.pi;
    try svg.appendSlice(allocator, " transform=\"rotate(");
    try svg.appendSlice(allocator, std.fmt.bufPrint(&buf, "{d:.6}", .{deg}) catch "0");
    try svg.appendSlice(allocator, ", ");
    try svg.appendSlice(allocator, std.fmt.bufPrint(&buf, "{d}", .{center_x}) catch "0");
    try svg.appendSlice(allocator, ", ");
    try svg.appendSlice(allocator, std.fmt.bufPrint(&buf, "{d}", .{center_y}) catch "0");
    try svg.appendSlice(allocator, ")\"");
}

// ─── Execute ─────────────────────────────────────────────────────────────

/// Execute `preview_design_page`.
///
/// Returns a `<show_preview>` envelope (legacy tag name, kept for wire
/// compat):
///   - success: `<show_preview><status>shown</status>...</show_preview>`
///   - error:   `<show_preview><error>...</error></show_preview>`
///
/// `out_preview_id` receives the generated preview id (heap-owned; caller
/// MUST free). Always populated, even on error, so the caller can log the
/// failed attempt.
pub fn executePreviewDesignPageToString(
    allocator: std.mem.Allocator,
    io: std.Io,
    db: *sqlite.SqliteBackend,
    input: PreviewDesignPageInput,
    out_preview_id: *[]u8,
) ![]u8 {
    // Generate the preview id first (always allocated, even on error,
    // so the caller can correlate).
    const preview_id = try generatePreviewId(allocator, io);
    out_preview_id.* = preview_id;

    // Validate scale
    if (input.scale < 0.1 or input.scale > MAX_SCALE) {
        const msg = try std.fmt.allocPrint(
            allocator,
            "scale must be between 0.1 and {d:.1} (got {d:.4})",
            .{ MAX_SCALE, input.scale },
        );
        defer allocator.free(msg);
        return try errorEnvelope(allocator, msg);
    }

    // Validate page_id
    if (input.page_id.len == 0) {
        return try errorEnvelope(allocator, "page_id is required");
    }

    // Fetch the page + elements
    var bundle = design_model.getPageWithElements(allocator, db, input.page_id) catch |err| {
        const msg = try std.fmt.allocPrint(
            allocator,
            "page_id '{s}' not found: {s}",
            .{ input.page_id, @errorName(err) },
        );
        defer allocator.free(msg);
        return try errorEnvelope(allocator, msg);
    };
    defer bundle.deinit(allocator);

    // Build the SVG
    const svg_content = try buildSvg(allocator, bundle.page, bundle.elements, input.scale);
    defer allocator.free(svg_content);

    // Sanitize the SVG HTML content (defensive — invalid UTF-8 would break
    // the iframe's parser). The preview's content_type is "html" so the
    // sandboxed iframe renders it directly.
    const sanitized = try @import("helpers").sanitize.sanitizeUtf8(allocator, svg_content);
    defer allocator.free(sanitized);

    // Wrap in the `<show_preview>` envelope (legacy tag name, kept for
    // wire compat with existing transcripts).
    return try successEnvelope(
        allocator,
        preview_id,
        "html",
        sanitized.len,
    );
}