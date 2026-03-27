const std = @import("std");
const schemas = @import("schemas.zig");
const ToolProperty = schemas.ToolProperty;
const ToolParameters = schemas.ToolParameters;
const AgentToolFunction = schemas.AgentToolFunction;
const AgentTool = schemas.AgentTool;
const crypto = @import("std").crypto;
const Sha256 = crypto.hash.sha2.Sha256;

pub const TextReplaceInput = struct {
    path: []const u8,
    old_str: []const u8,
    new_str: []const u8,
    expected_hash: []const u8,
};

pub const TextReplaceResult = struct {
    sha256_after: []u8,

    pub fn deinit(self: TextReplaceResult, allocator: std.mem.Allocator) void {
        allocator.free(self.sha256_after);
    }
};

pub const TextReplaceError = error{
    OldStrNotFound,
    OldStrNotUnique,
    HashMismatch,
};

pub fn text_replace(
    allocator: std.mem.Allocator,
    path: []const u8,
    old_str: []const u8,
    new_str: []const u8,
    expected_hash: []const u8,
) !TextReplaceResult {
    return text_replaceWithHash(allocator, path, old_str, new_str, expected_hash);
}

pub fn text_replaceWithHash(
    allocator: std.mem.Allocator,
    path: []const u8,
    old_str: []const u8,
    new_str: []const u8,
    expected_hash: []const u8,
) !TextReplaceResult {
    // Read existing file
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();

    const raw = try file.readToEndAlloc(allocator, std.math.maxInt(usize));
    defer allocator.free(raw);

    // Compute current hash
    var hash: [32]u8 = undefined;
    Sha256.hash(raw, &hash, .{});
    const sha256_hex = try std.fmt.allocPrint(allocator, "{s}", .{std.fmt.bytesToHex(hash, .lower)});

    // Validate hash - must match
    if (!std.mem.eql(u8, expected_hash, sha256_hex)) {
        allocator.free(sha256_hex);
        return TextReplaceError.HashMismatch;
    }

    // Find first occurrence
    const first = std.mem.indexOf(u8, raw, old_str) orelse {
        // Must free sha256_hex before returning error
        allocator.free(sha256_hex);
        return TextReplaceError.OldStrNotFound;
    };

    // Check for a second occurrence — must be unique
    if (std.mem.indexOf(u8, raw[first + old_str.len ..], old_str) != null) {
        // Must free sha256_hex before returning error
        allocator.free(sha256_hex);
        return TextReplaceError.OldStrNotUnique;
    }

    // Build new file content: before + new_str + after
    var new_content = std.ArrayList(u8).empty;
    errdefer new_content.deinit(allocator);

    try new_content.appendSlice(allocator, raw[0..first]);
    try new_content.appendSlice(allocator, new_str);
    try new_content.appendSlice(allocator, raw[first + old_str.len ..]);

    // Compute hash after edit BEFORE writing/deinit (while new_content is still valid)
    var hash_after: [32]u8 = undefined;
    Sha256.hash(new_content.items, &hash_after, .{});
    const sha256_after = try std.fmt.allocPrint(allocator, "{s}", .{std.fmt.bytesToHex(hash_after, .lower)});

    // Write back to file
    const file_write = try std.fs.cwd().createFile(path, .{});
    defer file_write.close();

    try file_write.writeAll(new_content.items);

    new_content.deinit(allocator);

    // Free sha256_hex before returning - we only needed it for validation
    allocator.free(sha256_hex);

    return TextReplaceResult{
        .sha256_after = sha256_after,
    };
}

pub fn textReplaceToStringXML(allocator: std.mem.Allocator, result: TextReplaceResult) ![]const u8 {
    return try std.fmt.allocPrint(allocator,
        \\<sha256_after>{s}</sha256_after>
    , .{
        result.sha256_after,
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
        \\- If OldStrNotUnique: expand old_str to include surrounding lines for context.
        \\- Prefer longer, more specific old_str over minimal matches.
        \\- new_str can be any length, multiline, or empty (empty = delete).
        \\- Always read_file first to confirm the exact string to match.
        \\- Prefer over write_file for editing existing files.
        \\- Pass expected_hash from read_file result to prevent blind edits.
        \\- If file changed since read, edit will be rejected with HashMismatch error.
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
                .{
                    .name = "expected_hash",
                    .type = "string",
                    .description = "SHA256 hash from read_file result. If provided, edit is rejected if file changed.",
                },
            },
            .required = &.{ "path", "old_str", "new_str", "expected_hash" },
        },
    },
};

test {
    _ = @import("text_replace_test.zig");
    _ = @import("text_replace_hash_tests.zig");
}
