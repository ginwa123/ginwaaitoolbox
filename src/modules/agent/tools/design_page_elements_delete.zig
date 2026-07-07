// `delete_design_element` LLM tool — removes a design element
// (row + on-disk html file). Idempotent.
//
// Plan: docs/superpowers/plans/2026-07-06-design-fs-rewrite.md
//   (Chunk 3, Tool 3.5)

const std = @import("std");
const schemas = @import("schemas.zig");
const AgentTool = schemas.AgentTool;
const nalarcore = @import("nalarcore");
const sqlite = nalarcore.sqlite;

/// Input structure for delete_design_element.
pub const DeleteDesignElementInput = struct {
    /// Element id. From list_design_elements' `<id>` field (or
    /// set_design_element's `<id>` field).
    element_id: []const u8 = "",
};

/// Top-level tool definition for the LLM.
pub const delete_design_element_tool = AgentTool{
    .type = "function",
    .function = .{
        .name = "delete_design_element",
        .description =
            \\Delete a design element (DB row + on-disk html file). Idempotent — re-issuing with the same id returns `<deleted>false</deleted>`. Use list_design_elements first to find the element id. After delete, the html file at <workspace_item.path>/.nalar/design/<page>/<element>.html is unlinked (best-effort: a stale orphan is still possible if the file was manually `chmod`'d away).
        ,
        .parameters = .{
            .type = "object",
            .properties = &.{
                .{
                    .name = "element_id",
                    .type = "string",
                    .description = "Element id (NOT name). From `list_design_elements`' `<id>` field.",
                },
            },
            .required = &.{ "element_id" },
        },
    },
};

/// Execute the delete_design_element tool.
///
/// Response shape:
///   <delete>
///     <element_id>...</element_id>
///     <deleted>true|false</deleted>
///   </delete>
pub fn executeDeleteDesignElementToString(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    input: DeleteDesignElementInput,
) ![]u8 {
    if (input.element_id.len == 0) {
        return try errorXmlOwned(allocator, "element_id required");
    }

    const deleted = nalarcore.ai_mod.design_model.deleteElement(allocator, db, input.element_id) catch |err| {
        return try errorXmlOwnedFmt(allocator, "DB: deleteElement failed: {s}", .{@errorName(err)});
    };

    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    try buf.appendSlice(allocator, "<delete>");

    const esc_id = try xmlEscape(allocator, input.element_id);
    defer allocator.free(esc_id);
    try buf.print(allocator, "<element_id>{s}</element_id>", .{esc_id});

    try buf.print(allocator, "<deleted>{s}</deleted>", .{if (deleted) "true" else "false"});

    try buf.appendSlice(allocator, "</delete>");
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
        "<delete><error>{s}</error></delete>",
        .{escaped},
    );
}

fn errorXmlOwnedFmt(allocator: std.mem.Allocator, comptime fmt: []const u8, args: anytype) ![]u8 {
    const raw = try std.fmt.allocPrint(allocator, fmt, args);
    defer allocator.free(raw);
    return errorXmlOwned(allocator, raw);
}
