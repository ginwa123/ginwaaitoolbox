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
    ops: []const TextReplaceOp,
    expected_hash: []const u8,
};

pub const TextReplaceError = error{
    OldStrNotFound,
    OldStrNotUnique,
    HashMismatch,
    PathNotFound,
    HashNotFound,
};

// =============================================================================
// Batch Text Replace Types
// =============================================================================

/// Single replacement operation for batch processing
pub const TextReplaceOp = struct {
    old_str: []const u8,
    new_str: []const u8,
};

/// Result of batch text replace operation
pub const TextReplaceBatchResult = struct {
    sha256_after: []u8,

    pub fn deinit(self: TextReplaceBatchResult, allocator: std.mem.Allocator) void {
        allocator.free(self.sha256_after);
    }
};

/// Batch text replace - applies multiple replacements in a single file
/// Returns the sha256 hash of the file after all replacements
/// Validates expected_hash to ensure file hasn't changed before applying
pub fn text_replace_batch(
    allocator: std.mem.Allocator,
    path: []const u8,
    ops: []const TextReplaceOp,
    expected_hash: []const u8,
) !TextReplaceBatchResult {
    if (std.mem.eql(u8, path, "")) {
        return TextReplaceError.PathNotFound;
    }

    if (std.mem.eql(u8, expected_hash, "")) {
        return TextReplaceError.HashNotFound;
    }

    // Read existing file
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();

    const raw = try file.readToEndAlloc(allocator, std.math.maxInt(usize));
    defer allocator.free(raw);

    // Validate expected_hash to ensure file hasn't changed
    var current_hash: [32]u8 = undefined;
    Sha256.hash(raw, &current_hash, .{});
    const current_hash_hex = std.fmt.bytesToHex(current_hash, .lower);
    if (!std.mem.eql(u8, expected_hash, &current_hash_hex)) {
        return TextReplaceError.HashMismatch;
    }

    // Start with original content
    var content = std.ArrayList(u8).empty;
    errdefer content.deinit(allocator);
    try content.appendSlice(allocator, raw);

    // Apply each replacement
    for (ops) |op| {
        // Find first occurrence
        const first = std.mem.indexOf(u8, content.items, op.old_str) orelse {
            return TextReplaceError.OldStrNotFound;
        };

        // Check for a second occurrence — must be unique
        if (std.mem.indexOf(u8, content.items[first + op.old_str.len ..], op.old_str) != null) {
            return TextReplaceError.OldStrNotUnique;
        }

        // Build new content: before + new_str + after
        var new_content = std.ArrayList(u8).empty;
        errdefer new_content.deinit(allocator);

        try new_content.appendSlice(allocator, content.items[0..first]);
        try new_content.appendSlice(allocator, op.new_str);
        try new_content.appendSlice(allocator, content.items[first + op.old_str.len ..]);

        content.deinit(allocator);
        content = new_content;
    }

    // Compute hash after all edits
    var hash_after: [32]u8 = undefined;
    Sha256.hash(content.items, &hash_after, .{});
    const sha256_after = try std.fmt.allocPrint(allocator, "{s}", .{std.fmt.bytesToHex(hash_after, .lower)});

    // Write back to file
    const file_write = try std.fs.cwd().createFile(path, .{});
    defer file_write.close();

    try file_write.writeAll(content.items);

    content.deinit(allocator);

    return TextReplaceBatchResult{
        .sha256_after = sha256_after,
    };
}

/// Serialize batch result to XML string
pub fn text_replace_batch_to_string_xml(allocator: std.mem.Allocator, result: TextReplaceBatchResult) ![]const u8 {
    return try std.fmt.allocPrint(allocator,
        \\<sha256_after>{s}</sha256_after>
    , .{
        result.sha256_after,
    });
}

/// Properties for text_replace tool (built using List at compile time)
const text_replace_props: []const ToolProperty = &.{
    .{
        .name = "path",
        .type = "string",
        .description = "Absolute path to the file.",
    },
    .{
        .name = "ops",
        .type = "array",
        .description =
        \\Array of replacement operations. Each element must be an object with exactly two fields:
        \\  - "old_str": string — the exact text to find (must appear exactly once in the file)
        \\  - "new_str": string — the replacement text (use empty string "" to delete)
        \\Both field names are snake_case. Do NOT use camelCase (e.g. newStr is invalid).
        ,
    },
    .{
        .name = "expected_hash",
        .type = "string",
        .description = "SHA256 hash from read_file result. Edit is rejected with HashMismatch if file changed since last read.",
    },
};

pub const text_replace_tool: AgentTool = .{
    .type = "function",
    .function = .{
        .name = "text_replace",
        .description =
        \\Replace one or more strings in a file with new content.
        \\
        \\- Each old_str must match file content exactly (whitespace included).
        \\- Each old_str must appear exactly once — error if not found or ambiguous.
        \\- If OldStrNotUnique: expand old_str to include surrounding lines for context.
        \\- new_str can be any length, multiline, or empty (empty = delete).
        \\- Pass expected_hash from read_file result to prevent blind edits.
        \\- If file changed since read, edit will be rejected with HashMismatch error.
        \\expected_hash (REQUIRED): SHA256 from read_file.
        \\You MUST call read_file first and copy its sha256 field here.
        \\Omitting this or passing empty string will always fail with an error.
        ,
        .parameters = .{
            .type = "object",
            .properties = text_replace_props,
            .required = &.{ "path", "ops", "expected_hash" },
        },
    },
};
