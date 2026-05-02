const std = @import("std");
const schemas = @import("schemas.zig");
const ToolProperty = schemas.ToolProperty;
const ToolParameters = schemas.ToolParameters;
const AgentToolFunction = schemas.AgentToolFunction;
const AgentTool = schemas.AgentTool;

pub const TextReplaceInput = struct {
    path: []const u8,
    old_str: []const u8,
    new_str: []const u8,
};

pub const TextReplaceError = error{
    OldStrNotFound,
    OldStrNotUnique,
    PathNotFound,
};

// Diagnostic info returned alongside errors to help users fix issues
pub const TextReplaceDiagnostic = struct {
    // How many lines differed
    line_count: usize,
    // Number of trailing spaces difference (if whitespace mismatch)
    trailing_space_diff: ?usize = null,
    // True if file had CRLF and input used LF
    had_crlf: bool = false,
};

// =============================================================================
// Batch Text Replace Types
// =============================================================================

/// Result of text replace operation
pub const TextReplaceResult = struct {
    ok: void,
};

/// Normalize CRLF (\r\n) to LF (\n), always returns a new allocation
fn normalizeLineEndings(allocator: std.mem.Allocator, content: []u8) ![]u8 {
    if (std.mem.indexOf(u8, content, "\r\n") == null) {
        // No CRLF found — still allocate so caller always owns the result
        return try allocator.dupe(u8, content);
    }

    // CRLF found — allocate new buffer and filter
    var result = std.ArrayList(u8).empty;
    errdefer result.deinit(allocator);

    var i: usize = 0;
    while (i < content.len) {
        if (i < content.len - 1 and content[i] == '\r' and content[i + 1] == '\n') {
            // Convert CRLF to LF
            try result.append(allocator, '\n');
            i += 2;
        } else {
            try result.append(allocator, content[i]);
            i += 1;
        }
    }

    return try result.toOwnedSlice(allocator);
}

/// Strip trailing whitespace from each line, returns new allocation if needed
fn stripTrailingWhitespace(allocator: std.mem.Allocator, content: []u8, had_crlf: bool) ![]u8 {
    const newline_char: u8 = if (had_crlf) '\r' else '\n';
    const newline: []const u8 = if (had_crlf) "\r\n" else "\n";

    // Check if any line has trailing whitespace
    var has_trailing = false;
    var line_start: usize = 0;
    for (content, 0..) |byte, idx| {
        if (byte == newline_char or (had_crlf and byte == '\n' and idx > 0 and content[idx - 1] == '\r')) {
            // Check line before this newline
            var line_end = idx;
            if (had_crlf and byte == '\n' and idx > 0 and content[idx - 1] == '\r') {
                line_end = idx - 1; // Don't include \r in line
            }
            while (line_end > line_start and (content[line_end - 1] == ' ' or content[line_end - 1] == '\t')) {
                line_end -= 1;
            }
            if (line_end < idx) {
                has_trailing = true;
            }
            line_start = idx + 1;
            if (had_crlf and byte == '\n') {
                line_start += 1;
            }
        }
    }

    if (!has_trailing) {
        return content; // No trailing whitespace found
    }

    // Build new content without trailing whitespace
    var result = std.ArrayList(u8).empty;
    errdefer result.deinit(allocator);

    line_start = 0;
    for (content, 0..) |byte, idx| {
        if (byte == newline_char or (had_crlf and byte == '\n' and idx > 0 and content[idx - 1] == '\r')) {
            // Copy line (up to first trailing whitespace)
            var line_end = idx;
            if (had_crlf and byte == '\n' and idx > 0 and content[idx - 1] == '\r') {
                try result.appendSlice(allocator, content[line_start..line_end]);
                try result.appendSlice(allocator, newline);
                line_start = idx + 1;
                continue;
            }
            while (line_end > line_start and (content[line_end - 1] == ' ' or content[line_end - 1] == '\t')) {
                line_end -= 1;
            }
            try result.appendSlice(allocator, content[line_start..line_end]);
            try result.appendSlice(allocator, newline);
            line_start = idx + 1;
        }
    }

    return try result.toOwnedSlice(allocator);
}

/// Convert LF to CRLF
fn lfToCrlf(allocator: std.mem.Allocator, content: []const u8) ![]u8 {
    if (std.mem.indexOf(u8, content, "\n") == null) {
        return try allocator.dupe(u8, content);
    }

    var result = std.ArrayList(u8).empty;
    errdefer result.deinit(allocator);

    for (content) |byte| {
        if (byte == '\n') {
            try result.append(allocator, '\r');
        }
        try result.append(allocator, byte);
    }

    return try result.toOwnedSlice(allocator);
}

/// Text replace - applies a single replacement in a file
pub fn executeTextReplace(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    old_str: []const u8,
    new_str: []const u8,
) !TextReplaceResult {
    if (std.mem.eql(u8, path, "")) {
        return TextReplaceError.PathNotFound;
    }

    // Read existing file
    const file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer std.Io.File.close(file, io);

    var raw = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, std.Io.Limit.limited(std.math.maxInt(usize)));
    defer allocator.free(raw);

    // Detect and normalize line endings (CRLF -> LF)
    const had_crlf = std.mem.indexOf(u8, raw, "\r\n") != null;
    if (had_crlf) {
        const normalized = try normalizeLineEndings(allocator, raw);
        allocator.free(raw);
        raw = normalized;
    }

    // Find first occurrence
    const first = std.mem.indexOf(u8, raw, old_str) orelse {
        // Detailed diagnostic for "not found" — attempt to help user understand why
        _ = stripTrailingWhitespace(allocator, raw, had_crlf) catch raw;
        return TextReplaceError.OldStrNotFound;
    };

    // Check for a second occurrence — must be unique
    if (std.mem.indexOf(u8, raw[first + old_str.len ..], old_str) != null) {
        return TextReplaceError.OldStrNotUnique;
    }

    // Build new content: before + new_str + after
    var content = std.ArrayList(u8).empty;
    errdefer content.deinit(allocator);

    try content.appendSlice(allocator, raw[0..first]);

    // If file had CRLF, decide whether to convert new_str:
    // - If old_str ends with \n: old_str provides boundary \n, don't convert new_str
    // - If old_str doesn't end with \n and new_str ends with \n: new_str provides boundary, convert it
    // - If neither ends with \n: boundary comes from file content, don't convert new_str
    const old_str_ends_with_newline = old_str.len > 0 and old_str[old_str.len - 1] == '\n';
    const new_str_ends_with_newline = new_str.len > 0 and new_str[new_str.len - 1] == '\n';

    if (had_crlf and new_str_ends_with_newline and !old_str_ends_with_newline) {
        const new_str_crlf = try lfToCrlf(allocator, new_str);
        defer allocator.free(new_str_crlf);
        try content.appendSlice(allocator, new_str_crlf);
    } else {
        try content.appendSlice(allocator, new_str);
    }

    // Append suffix and normalize its trailing newline to CRLF if needed
    if (had_crlf) {
        const suffix = raw[first + old_str.len ..];
        if (suffix.len > 0 and suffix[suffix.len - 1] == '\n') {
            if (!old_str_ends_with_newline) {
                // old_str doesn't end with \n, so suffix's leading \n is the boundary
                // Don't add extra \r here - the conversion below handles it
                for (suffix) |byte| {
                    if (byte == '\n') {
                        try content.append(allocator, '\r');
                    }
                    try content.append(allocator, byte);
                }
            } else {
                // old_str provides boundary \n, skip suffix's leading \r and its trailing \n
                const skip_leading_cr = suffix.len >= 2 and suffix[0] == '\r';
                const suffix_end_len: usize = if (skip_leading_cr) 2 else 1;
                try content.appendSlice(allocator, suffix[0 .. suffix.len - suffix_end_len]);
                try content.append(allocator, '\r');
                try content.append(allocator, '\n');
            }
        } else {
            try content.appendSlice(allocator, suffix);
        }
    } else {
        try content.appendSlice(allocator, raw[first + old_str.len ..]);
    }

    // Write back to file
    const file_write = try std.Io.Dir.cwd().createFile(io, path, .{});
    defer std.Io.File.close(file_write, io);

    std.Io.File.writeStreamingAll(file_write, io, content.items) catch {
        content.deinit(allocator);
        return error.WriteFailed;
    };

    content.deinit(allocator);

    return TextReplaceResult{ .ok = {} };
}

/// Create a minimal XML error output (no success field, just error + original args)
pub fn xmlError(allocator: std.mem.Allocator, err_msg: []const u8, path: []const u8, old_str: []const u8, new_str: []const u8) []const u8 {
    return std.fmt.allocPrint(allocator,
        \\<error>{s}</error>
        \\<path>{s}</path>
        \\<old_str>{s}</old_str>
        \\<new_str>{s}</new_str>
        \\<success>false</success>
    , .{ err_msg, path, old_str, new_str }) catch "<success>false</success><error>UnknownError</error>";
}

/// Serialize result to XML string
pub fn toXmlSuccess(allocator: std.mem.Allocator, result: TextReplaceResult, path: []const u8) []const u8 {
    _ = result;
    return std.fmt.allocPrint(allocator, "<success>true</success><path>{s}</path>", .{path}) catch "<success>true</success><path>Unknown</path>";
}

pub fn toXmlError(allocator: std.mem.Allocator, result: anyerror, path: []const u8, old_str: []const u8) []const u8 {
    const error_msg = switch (result) {
        error.OldStrNotFound => std.fmt.allocPrint(allocator, "Text '{s}' not found in file '{s}'. Make sure the text exists exactly once in the file.", .{ old_str, path }) catch return "<success>false</success><error>UnknownError</error>",
        error.OldStrNotUnique => std.fmt.allocPrint(allocator, "Text '{s}' appears multiple times in file '{s}'. Expand old_str to include more context to make it unique.", .{ old_str, path }) catch return "<success>false</success><error>UnknownError</error>",
        error.PathNotFound => std.fmt.allocPrint(allocator, "File '{s}' not found. Check if the path is correct.", .{path}) catch return "<success>false</success><error>UnknownError</error>",
        else => std.fmt.allocPrint(allocator, "Unexpected error: {s}", .{@errorName(result)}) catch return "<success>false</success><error>UnknownError</error>",
    };
    const output = std.fmt.allocPrint(allocator, "<success>false</success><error>{s}</error>", .{error_msg}) catch {
        allocator.free(error_msg);
        return "<success>false</success><error>UnknownError</error>";
    };
    allocator.free(error_msg);
    return output;
}

/// Properties for text_replace tool
const text_replace_props: []const ToolProperty = &.{
    .{
        .name = "path",
        .type = "string",
        .description = "Absolute path to the file.",
    },
    .{
        .name = "old_str",
        .type = "string",
        .description = "The exact text to find (must appear exactly once in the file).",
    },
    .{
        .name = "new_str",
        .type = "string",
        .description = "The replacement text (use empty string to delete).",
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
            .required = &.{ "path", "old_str", "new_str" },
        },
    },
};

// ============================================================================
// Test Compatibility Aliases
// ============================================================================

/// Alias for executeTextReplace (snake_case name used by tests)
/// Takes individual parameters instead of TextReplaceInput struct
pub fn text_replace(allocator: std.mem.Allocator, path: []const u8, old_str: []const u8, new_str: []const u8) !void {
    _ = try executeTextReplace(allocator, path, old_str, new_str);
}
