const std = @import("std");
const ToolProperty = @import("models.zig").ToolProperty;
const ToolParameters = @import("models.zig").ToolParameters;
const AgentToolFunction = @import("models.zig").AgentToolFunction;
const AgentTool = @import("models.zig").AgentTool;

pub const TextReplaceInput = struct {
    path: []const u8,
    old_str: []const u8,
    new_str: []const u8,
};

pub const TextReplaceResult = struct {
    path: []u8,
    old_str: []u8,
    new_str: []u8,
    replaced_at_byte: usize,

    pub fn deinit(self: TextReplaceResult, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        allocator.free(self.old_str);
        allocator.free(self.new_str);
    }
};

pub const TextReplaceError = error{
    OldStrNotFound,
    OldStrNotUnique,
};

pub fn text_replace(
    allocator: std.mem.Allocator,
    path: []const u8,
    old_str: []const u8,
    new_str: []const u8,
) !TextReplaceResult {
    // Read existing file
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();

    const raw = try file.readToEndAlloc(allocator, std.math.maxInt(usize));
    defer allocator.free(raw);

    // Find first occurrence
    const first = std.mem.indexOf(u8, raw, old_str) orelse {
        return TextReplaceError.OldStrNotFound;
    };

    // Check for a second occurrence — must be unique
    if (std.mem.indexOf(u8, raw[first + old_str.len ..], old_str) != null) {
        return TextReplaceError.OldStrNotUnique;
    }

    // Build new file content: before + new_str + after
    var new_content = std.ArrayList(u8).empty;
    errdefer new_content.deinit(allocator);

    try new_content.appendSlice(allocator, raw[0..first]);
    try new_content.appendSlice(allocator, new_str);
    try new_content.appendSlice(allocator, raw[first + old_str.len ..]);

    // Write back to file
    const file_write = try std.fs.cwd().createFile(path, .{});
    defer file_write.close();

    try file_write.writeAll(new_content.items);

    new_content.deinit(allocator);

    return TextReplaceResult{
        .path = try allocator.dupe(u8, path),
        .old_str = try allocator.dupe(u8, old_str),
        .new_str = try allocator.dupe(u8, new_str),
        .replaced_at_byte = first,
    };
}

pub fn textReplaceToString(allocator: std.mem.Allocator, result: TextReplaceResult) ![]const u8 {
    return try std.fmt.allocPrint(allocator,
        \\<path>{s}</path>
        \\<replaced_at_byte>{d}</replaced_at_byte>
        \\<old_str>{s}</old_str>
        \\<new_str>{s}</new_str>
    , .{
        result.path,
        result.replaced_at_byte,
        result.old_str,
        result.new_str,
    });
}

pub const textReplaceTool = AgentTool{
    .type = "function",
    .function = .{
        .name = "text_replace",
        .description =
        \\Replace a unique string in a file with new content.
        \\
        \\- old_str must match file content exactly (whitespace included).
        \\- old_str must appear exactly once — error if not found or ambiguous.
        \\- new_str can be any length, multiline, or empty (empty = delete).
        \\- Always read_file first to confirm the exact string to match.
        \\- Prefer over write_file for editing existing files.
        ,
        .parameters = .{
            .type = "object",
            .properties = &.{
                .{
                    .name = "path",
                    .type = "string",
                    .description = "Absolute path to the file.",
                },
                .{
                    .name = "old_str",
                    .type = "string",
                    .description = "Exact string to find. Must appear exactly once.",
                },
                .{
                    .name = "new_str",
                    .type = "string",
                    .description = "Replacement string. Can be shorter, longer, multiline, or empty to delete.",
                },
            },
            .required = &.{ "path", "old_str", "new_str" },
        },
    },
};
