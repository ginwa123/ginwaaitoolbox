// `move_design_element` LLM tool — low-latency x/y update for
// drag-move. HTML file is untouched.
//
// Plan: docs/superpowers/plans/2026-07-06-design-fs-rewrite.md
//   (Chunk 3, Tool 3.3)

const std = @import("std");
const schemas = @import("schemas.zig");
const AgentTool = schemas.AgentTool;
const nalarcore = @import("nalarcore");
const sqlite = nalarcore.sqlite;

/// Input structure for move_design_element.
pub const MoveDesignElementInput = struct {
    /// Element id. From set_design_element's `<id>` field (or
    /// list_design_elements).
    element_id: []const u8 = "",
    /// New X position.
    x: ?i64 = null,
    /// New Y position.
    y: ?i64 = null,
};

/// Top-level tool definition for the LLM. Description explains
/// the drag-move use case (geometry-only, no html or file IO).
pub const move_design_element_tool = AgentTool{
    .type = "function",
    .function = .{
        .name = "move_design_element",
        .description =
            \\Update an element's x/y position (used during drag-to-move). Updates the x and y columns only — does NOT rewrite the html file or change z_index/width/height. For size changes use set_design_element (PUT) or the dedicated resize handlers.
            \\
            \\The element_id comes from set_design_element's `<id>` field (or list_design_elements' `<id>`). x and y are absolute pixel positions on the parent design page (NOT relative deltas — pass the final coordinates).
        ,
        .parameters = .{
            .type = "object",
            .properties = &.{
                .{
                    .name = "element_id",
                    .type = "string",
                    .description = "Element id (NOT name). From `set_design_element`'s `<id>` field or `list_design_elements`.",
                },
                .{
                    .name = "x",
                    .type = "integer",
                    .description = "New X position in pixels. Absolute, not relative.",
                },
                .{
                    .name = "y",
                    .type = "integer",
                    .description = "New Y position in pixels. Absolute, not relative.",
                },
            },
            .required = &.{ "element_id", "x", "y" },
        },
    },
};

/// Execute the move_design_element tool. Returns an XML string.
pub fn executeMoveDesignElementToString(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    input: MoveDesignElementInput,
) ![]u8 {
    if (input.element_id.len == 0) {
        return try errorXmlOwned(allocator, "element_id required");
    }
    if (input.x == null) {
        return try errorXmlOwned(allocator, "x required");
    }
    if (input.y == null) {
        return try errorXmlOwned(allocator, "y required");
    }

    nalarcore.ai_mod.design_model.moveElement(
        allocator,
        db,
        input.element_id,
        input.x.?,
        input.y.?,
    ) catch |err| {
        return try errorXmlOwnedFmt(allocator, "DB: moveElement failed: {s}", .{@errorName(err)});
    };

    return try successXml(allocator, input.element_id, input.x.?, input.y.?);
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
        "<move><error>{s}</error></move>",
        .{escaped},
    );
}

fn errorXmlOwnedFmt(allocator: std.mem.Allocator, comptime fmt: []const u8, args: anytype) ![]u8 {
    const raw = try std.fmt.allocPrint(allocator, fmt, args);
    defer allocator.free(raw);
    return errorXmlOwned(allocator, raw);
}

fn successXml(allocator: std.mem.Allocator, element_id: []const u8, x: i64, y: i64) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    try buf.appendSlice(allocator, "<move>");

    const esc_id = try xmlEscape(allocator, element_id);
    defer allocator.free(esc_id);
    try buf.print(allocator, "<id>{s}</id>", .{esc_id});

    var x_buf: [32]u8 = undefined;
    const x_str = std.fmt.bufPrint(&x_buf, "{d}", .{x}) catch "0";
    try buf.print(allocator, "<x>{s}</x>", .{x_str});

    var y_buf: [32]u8 = undefined;
    const y_str = std.fmt.bufPrint(&y_buf, "{d}", .{y}) catch "0";
    try buf.print(allocator, "<y>{s}</y>", .{y_str});

    try buf.appendSlice(allocator, "</move>");
    return buf.toOwnedSlice(allocator);
}
