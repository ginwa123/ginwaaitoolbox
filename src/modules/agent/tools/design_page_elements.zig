// `set_design_element` LLM tool — creates (or updates) a positioned
// html element on a design page. The html is written to disk at
// `<workspace_item.path>/.nalar/design/<page_name>/<element_sanitized>.html`.
//
// Plan: docs/superpowers/plans/2026-07-06-design-fs-rewrite.md
//   (Chunk 3, Tool 3.2)

const std = @import("std");
const schemas = @import("schemas.zig");
const AgentTool = schemas.AgentTool;
const nalarcore = @import("nalarcore");
const sqlite = nalarcore.sqlite;

/// Input structure for set_design_element.
pub const SetDesignElementInput = struct {
    /// Page id (NOT name). From `set_design_page`'s `<id>` field
    /// (the LLM gets page_id back from the create-page tool; use
    /// `list_design_pages` if the LLM needs to re-discover it).
    page_id: []const u8 = "",
    /// Element name (e.g. "Hero card", "Phone mockup",
    /// "Background"). The on-disk html file is
    /// `<workspace_item.path>/.nalar/design/<page.name>/<sanitized>.html`.
    name: []const u8 = "",
    /// HTML body of the element. Full document — wrapper allowed
    /// or just the snippet (the canvas's iframe adds the wrapper
    /// when rendering). For first-class design work prefer full
    /// `<!doctype html>...</html>` documents.
    html: []const u8 = "",
    /// X position on the page. Default 0.
    x: ?i64 = null,
    /// Y position on the page. Default 0.
    y: ?i64 = null,
    /// Element width in pixels. Default 375 (iPhone-ish).
    width: ?i64 = null,
    /// Element height in pixels. Default 667.
    height: ?i64 = null,
    /// Z-index (drawing order; higher = on top). Use -1 for
    /// background. Default 0.
    z_index: ?i64 = null,
};

/// Top-level tool definition for the LLM.
pub const set_design_element_tool = AgentTool{
    .type = "function",
    .function = .{
        .name = "set_design_element",
        .description =
            \\Create a positioned html element on a design page. Writes the html to disk at <workspace_item.path>/.nalar/design/<page_name>/<element_name>.html. The page must exist first (call set_design_page).
            \\
            \\Workflow: (1) call set_design_page to create the page, (2) call set_design_element to add positioned html snippets, (3) chain move_design_element or delete_design_element as the user drags or removes them. The page_id comes from set_design_page's `<id>` field (or list_design_pages' `<id>` field).
            \\
            \\Common element patterns:
            \\
            \\  - **Background**: name="Background", x=0, y=0, width=page.width, height=page.height, z_index=-1, html="<div style='background:<color>; width:100%; height:100%'></div>".
            \\  - **Phone mockup**: name="Phone mockup", width=375, height=667, html="<div class='phone'>...</div>".
            \\  - **Hero card**: name="Hero card", width=375, height=250, html="<div class='hero'>...</div>".
            \\
            \\The page_id must be the id returned by set_design_page (or fetched via list_design_pages). The element name is sanitized for use in file paths: lowercase, slashes→underscore, leading dots stripped, whitespace→dashes.
        ,
        .parameters = .{
            .type = "object",
            .properties = &.{
                .{
                    .name = "page_id",
                    .type = "string",
                    .description = "Page id (NOT name). From `set_design_page`'s `<id>` field or `list_design_pages`.",
                },
                .{
                    .name = "name",
                    .type = "string",
                    .description = "Element name (e.g. 'Hero card', 'Phone mockup', 'Background'). Sanitized for file paths: lowercase, slashes→underscore, whitespace→dashes.",
                },
                .{
                    .name = "html",
                    .type = "string",
                    .description = "HTML body. Full document (<!doctype html>...</html>) preferred for self-contained rendering.",
                },
                .{
                    .name = "x",
                    .type = "integer",
                    .description = "X position on the page in pixels. Default 0.",
                },
                .{
                    .name = "y",
                    .type = "integer",
                    .description = "Y position on the page in pixels. Default 0.",
                },
                .{
                    .name = "width",
                    .type = "integer",
                    .description = "Element width in pixels. Default 375 (iPhone-ish).",
                },
                .{
                    .name = "height",
                    .type = "integer",
                    .description = "Element height in pixels. Default 667.",
                },
                .{
                    .name = "z_index",
                    .type = "integer",
                    .description = "Drawing order. Higher = on top. Use -1 for background. Default 0.",
                },
            },
            .required = &.{ "page_id", "name", "html" },
        },
    },
};

/// Execute the set_design_element tool. Returns an XML string.
///
/// Response shape:
///   <element>
///     <id>...</id>
///     <page_id>...</page_id>
///     <file_path>...</file_path>
///     ...
///   </element>
///
/// Errors (encoded as XML):
///   - missing page_id / name / html
///   - page_id not found
///   - workspace item has no path
///   - DB failure
pub fn executeSetDesignElementToString(
    allocator: std.mem.Allocator,
    io: std.Io,
    db: *sqlite.SqliteBackend,
    input: SetDesignElementInput,
) ![]u8 {
    if (input.page_id.len == 0) {
        return try errorXmlOwned(allocator, "page_id required");
    }
    if (input.name.len == 0) {
        return try errorXmlOwned(allocator, "name required");
    }
    if (input.html.len == 0) {
        return try errorXmlOwned(allocator, "html required");
    }

    const x = input.x orelse 0;
    const y = input.y orelse 0;
    const width = input.width orelse 375;
    const height = input.height orelse 667;
    const z_index = input.z_index orelse 0;

    const new_id = nalarcore.ai_mod.design_model.addElement(
        allocator,
        io,
        db,
        input.page_id,
        input.name,
        input.html,
        x,
        y,
        width,
        height,
        z_index,
    ) catch |err| {
        return try errorXmlOwnedFmt(allocator, "DB: addElement failed: {s}", .{@errorName(err)});
    };
    defer allocator.free(new_id);

    // Re-fetch so the response carries file_path + position.
    const element = nalarcore.ai_mod.design_model.getElement(allocator, io, db, new_id) catch |err| {
        return try errorXmlOwnedFmt(allocator, "DB: getElement failed: {s}", .{@errorName(err)});
    };
    defer nalarcore.ai_mod.design_model.freeElementFull(allocator, element);

    return try elementToXml(allocator, element);
}

// ─── Helpers ──────────────────────────────────────────────────────────

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

fn errorXmlOwned(allocator: std.mem.Allocator, message: []const u8) ![]u8 {
    const escaped = try xmlEscape(allocator, message);
    defer allocator.free(escaped);
    return std.fmt.allocPrint(allocator,
        "<element><error>{s}</error></element>",
        .{escaped},
    );
}

fn errorXmlOwnedFmt(allocator: std.mem.Allocator, comptime fmt: []const u8, args: anytype) ![]u8 {
    const raw = try std.fmt.allocPrint(allocator, fmt, args);
    defer allocator.free(raw);
    return errorXmlOwned(allocator, raw);
}

fn elementToXml(
    allocator: std.mem.Allocator,
    element: nalarcore.ai_mod.design_model.DesignPageElementFull,
) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    try buf.appendSlice(allocator, "<element>");

    const esc_id = try xmlEscape(allocator, element.id);
    defer allocator.free(esc_id);
    try buf.print(allocator, "<id>{s}</id>", .{esc_id});

    const esc_pid = try xmlEscape(allocator, element.page_id);
    defer allocator.free(esc_pid);
    try buf.print(allocator, "<page_id>{s}</page_id>", .{esc_pid});

    const esc_fp = try xmlEscape(allocator, element.file_path);
    defer allocator.free(esc_fp);
    try buf.print(allocator, "<file_path>{s}</file_path>", .{esc_fp});

    const esc_name = try xmlEscape(allocator, element.name);
    defer allocator.free(esc_name);
    try buf.print(allocator, "<name>{s}</name>", .{esc_name});

    var x_buf: [32]u8 = undefined;
    const x_str = std.fmt.bufPrint(&x_buf, "{d}", .{element.x}) catch "0";
    try buf.print(allocator, "<x>{s}</x>", .{x_str});

    var y_buf: [32]u8 = undefined;
    const y_str = std.fmt.bufPrint(&y_buf, "{d}", .{element.y}) catch "0";
    try buf.print(allocator, "<y>{s}</y>", .{y_str});

    var width_buf: [32]u8 = undefined;
    const width_str = std.fmt.bufPrint(&width_buf, "{d}", .{element.width}) catch "0";
    try buf.print(allocator, "<width>{s}</width>", .{width_str});

    var height_buf: [32]u8 = undefined;
    const height_str = std.fmt.bufPrint(&height_buf, "{d}", .{element.height}) catch "0";
    try buf.print(allocator, "<height>{s}</height>", .{height_str});

    var z_buf: [32]u8 = undefined;
    const z_str = std.fmt.bufPrint(&z_buf, "{d}", .{element.z_index}) catch "0";
    try buf.print(allocator, "<z_index>{s}</z_index>", .{z_str});

    var pos_buf: [32]u8 = undefined;
    const pos_str = std.fmt.bufPrint(&pos_buf, "{d}", .{element.position}) catch "0";
    try buf.print(allocator, "<position>{s}</position>", .{pos_str});

    try buf.appendSlice(allocator, "</element>");
    return buf.toOwnedSlice(allocator);
}
