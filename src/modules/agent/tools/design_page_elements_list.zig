// `list_design_elements` LLM tool — list elements of a design
// page (metadata only, no html). Used by the LLM to discover
// element ids before chain-calling set_design_element /
// move_design_element / delete_design_element.
//
// Plan: docs/superpowers/plans/2026-07-06-design-fs-rewrite.md
//   (Chunk 3, Tool 3.4)

const std = @import("std");
const schemas = @import("schemas.zig");
const AgentTool = schemas.AgentTool;
const nalarcore = @import("nalarcore");
const sqlite = nalarcore.sqlite;

/// Input structure for list_design_elements.
pub const ListDesignElementsInput = struct {
    /// Page id. From `set_design_page`'s `<id>` field or
    /// `list_design_pages` (chunk 2 chunk 3 ListDesignPages tool).
    page_id: []const u8 = "",
};

/// Top-level tool definition for the LLM.
pub const list_design_elements_tool = AgentTool{
    .type = "function",
    .function = .{
        .name = "list_design_elements",
        .description =
            \\List the html elements of a design page (metadata only — name, x, y, width, height, z_index, file_path). The html body is read on demand by the desktop frontend (it's at <workspace_item.path>/.nalar/design/<page>/<element>.html — you can also read it via the read_file tool).
            \\
            \\Use this to discover element ids before calling move_design_element or delete_design_element. Returns one `<element>` block per element, ordered by z_index ASC, position ASC.
        ,
        .parameters = .{
            .type = "object",
            .properties = &.{
                .{
                    .name = "page_id",
                    .type = "string",
                    .description = "Page id (NOT name). From `set_design_page`'s `<id>` field or `list_design_pages`.",
                },
            },
            .required = &.{ "page_id" },
        },
    },
};

/// Execute the list_design_elements tool. Returns an XML string.
///
/// Response shape:
///   <elements count="N">
///     <element>
///       <id>...</id>
///       <name>...</name>
///       <file_path>...</file_path>
///       <x>...</x><y>...</y><width>...</width><height>...</height>
///       <z_index>...</z_index><position>...</position>
///     </element>
///     ...
///   </elements>
pub fn executeListDesignElementsToString(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    input: ListDesignElementsInput,
) ![]u8 {
    if (input.page_id.len == 0) {
        return try errorXmlOwned(allocator, "page_id required");
    }

    const elements = nalarcore.ai_mod.design_model.listElements(allocator, db, input.page_id) catch |err| {
        return try errorXmlOwnedFmt(allocator, "DB: listElements failed: {s}", .{@errorName(err)});
    };
    defer nalarcore.ai_mod.design_model.freeElements(allocator, elements);

    return try toXml(allocator, elements);
}

fn toXml(
    allocator: std.mem.Allocator,
    elements: []nalarcore.ai_mod.design_model.DesignPageElement,
) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    var count_buf: [32]u8 = undefined;
    const count_str = std.fmt.bufPrint(&count_buf, "{d}", .{elements.len}) catch "0";
    try buf.print(allocator, "<elements count=\"{s}\">", .{count_str});

    for (elements) |el| {
        try buf.appendSlice(allocator, "<element>");

        const esc_id = try xmlEscape(allocator, el.id);
        defer allocator.free(esc_id);
        try buf.print(allocator, "<id>{s}</id>", .{esc_id});

        const esc_name = try xmlEscape(allocator, el.name);
        defer allocator.free(esc_name);
        try buf.print(allocator, "<name>{s}</name>", .{esc_name});

        const esc_fp = try xmlEscape(allocator, el.file_path);
        defer allocator.free(esc_fp);
        try buf.print(allocator, "<file_path>{s}</file_path>", .{esc_fp});

        var x_buf: [32]u8 = undefined;
        const x_str = std.fmt.bufPrint(&x_buf, "{d}", .{el.x}) catch "0";
        try buf.print(allocator, "<x>{s}</x>", .{x_str});

        var y_buf: [32]u8 = undefined;
        const y_str = std.fmt.bufPrint(&y_buf, "{d}", .{el.y}) catch "0";
        try buf.print(allocator, "<y>{s}</y>", .{y_str});

        var w_buf: [32]u8 = undefined;
        const w_str = std.fmt.bufPrint(&w_buf, "{d}", .{el.width}) catch "0";
        try buf.print(allocator, "<width>{s}</width>", .{w_str});

        var h_buf: [32]u8 = undefined;
        const h_str = std.fmt.bufPrint(&h_buf, "{d}", .{el.height}) catch "0";
        try buf.print(allocator, "<height>{s}</height>", .{h_str});

        var z_buf: [32]u8 = undefined;
        const z_str = std.fmt.bufPrint(&z_buf, "{d}", .{el.z_index}) catch "0";
        try buf.print(allocator, "<z_index>{s}</z_index>", .{z_str});

        var p_buf: [32]u8 = undefined;
        const p_str = std.fmt.bufPrint(&p_buf, "{d}", .{el.position}) catch "0";
        try buf.print(allocator, "<position>{s}</position>", .{p_str});

        try buf.appendSlice(allocator, "</element>");
    }

    try buf.appendSlice(allocator, "</elements>");
    return buf.toOwnedSlice(allocator);
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
        "<elements><error>{s}</error></elements>",
        .{escaped},
    );
}

fn errorXmlOwnedFmt(allocator: std.mem.Allocator, comptime fmt: []const u8, args: anytype) ![]u8 {
    const raw = try std.fmt.allocPrint(allocator, fmt, args);
    defer allocator.free(raw);
    return errorXmlOwned(allocator, raw);
}
