const std = @import("std");
const schemas = @import("schemas.zig");
const ToolProperty = schemas.ToolProperty;
const ToolParameters = schemas.ToolParameters;
const AgentToolFunction = schemas.AgentToolFunction;
const AgentTool = schemas.AgentTool;

pub const TextReplaceInput = struct {
    path: []const u8,
    op: TextReplaceOp,
};

pub const TextReplaceError = error{
    OldStrNotFound,
    OldStrNotUnique,
    PathNotFound,
};

// =============================================================================
// Batch Text Replace Types
// =============================================================================

/// Single replacement operation
pub const TextReplaceOp = struct {
    old_str: []const u8,
    new_str: []const u8,
};

/// Result of text replace operation
pub const TextReplaceResult = struct {
    ok: void,
};

/// Text replace - applies a single replacement in a file
pub fn text_replace(
    allocator: std.mem.Allocator,
    path: []const u8,
    op: TextReplaceOp,
) !TextReplaceResult {
    if (std.mem.eql(u8, path, "")) {
        return TextReplaceError.PathNotFound;
    }

    // Read existing file
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();

    const raw = try file.readToEndAlloc(allocator, std.math.maxInt(usize));
    defer allocator.free(raw);

    // Find first occurrence
    const first = std.mem.indexOf(u8, raw, op.old_str) orelse {
        return TextReplaceError.OldStrNotFound;
    };

    // Check for a second occurrence — must be unique
    if (std.mem.indexOf(u8, raw[first + op.old_str.len..], op.old_str) != null) {
        return TextReplaceError.OldStrNotUnique;
    }

    // Build new content: before + new_str + after
    var content = std.ArrayList(u8).empty;
    errdefer content.deinit(allocator);

    try content.appendSlice(allocator, raw[0..first]);
    try content.appendSlice(allocator, op.new_str);
    try content.appendSlice(allocator, raw[first + op.old_str.len ..]);

    // Write back to file
    const file_write = try std.fs.cwd().createFile(path, .{});
    defer file_write.close();

    try file_write.writeAll(content.items);

    content.deinit(allocator);

    return TextReplaceResult{ .ok = {} };
}

/// Serialize result to XML string
pub fn text_replace_to_string_xml(allocator: std.mem.Allocator, result: TextReplaceResult) []const u8 {
    _ = allocator;
    _ = result;
    return "<success>true</success>";
}

/// Properties for text_replace tool
const text_replace_props: []const ToolProperty = &.{
    .{
        .name = "path",
        .type = "string",
        .description = "Absolute path to the file.",
    },
    .{
        .name = "op",
        .type = "object",
        .description =
        \\Object with exactly two fields:
        \\  - "old_str": string — the exact text to find (must appear exactly once in the file)
        \\  - "new_str": string — the replacement text (use empty string "" to delete)
        ,
    },
};

pub const text_replace_tool: AgentTool = .{
    .type = "function",
    .function = .{
        .name = "text_replace",
        .description =
        \\Replace a string in a file with new content.
        \\
        \\- old_str must match file content exactly (whitespace included).
        \\- old_str must appear exactly once — error if not found or ambiguous.
        \\- If OldStrNotUnique: expand old_str to include surrounding lines for context.
        \\- new_str can be any length, multiline, or empty (empty = delete).
        \\- Read the file first to see its current content.
        ,
        .parameters = .{
            .type = "object",
            .properties = text_replace_props,
            .required = &.{ "path", "op" },
        },
    },
};
