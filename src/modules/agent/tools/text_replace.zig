const std = @import("std");
const schemas = @import("schemas.zig");
const ToolProperty = schemas.ToolProperty;
const ToolParameters = schemas.ToolParameters;
const AgentToolFunction = schemas.AgentToolFunction;
const AgentTool = schemas.AgentTool;

/// XML-escape a string for safe inclusion in tool-result XML output.
/// Mirrors `src/ai_workflow/tui/agentic_loop/llm_history.zig xmlEscape` exactly so the
/// frontend's `unwrapToolOutput` can safely un-escape (& -> &amp; first
/// during decoding to avoid double-decoding).
/// Local definition (rather than importing the canonical one) keeps
/// `text_replace.zig` free of cross-module dependencies.
pub fn xmlEscape(allocator: std.mem.Allocator, s: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    for (s) |c| {
        switch (c) {
            '&' => try out.appendSlice(allocator, "&amp;"),
            '<' => try out.appendSlice(allocator, "&lt;"),
            '>' => try out.appendSlice(allocator, "&gt;"),
            '"' => try out.appendSlice(allocator, "&quot;"),
            '\'' => try out.appendSlice(allocator, "&apos;"),
            else => try out.append(allocator, c),
        }
    }
    return out.toOwnedSlice(allocator);
}

pub const TextReplaceInput = struct {
    path: []const u8,
    old_str: []const u8,
    new_str: []const u8,
};

pub const TextReplaceError = error{
    OldStrNotFound,
    OldStrNotUnique,
    PathNotFound,
    WriteFailed,
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

/// Result of text replace operation with diff view
pub const TextReplaceResult = struct {
    ok: void,
    /// Diff view showing before/after changes
    diff_view: ?DiffView = null,

    pub fn deinit(self: *TextReplaceResult, allocator: std.mem.Allocator) void {
        if (self.diff_view) |*dv| {
            dv.deinit(allocator);
        }
    }
};

/// Diff view showing before and after content (git-style split view)
pub const DiffView = struct {
    /// Unified diff format showing the change with +/-/space prefixes
    unified: []const u8,
    /// Content before the change (for split view)
    before: []const u8,
    /// Content after the change (for split view)
    after: []const u8,
    /// Number of lines changed (added + removed)
    lines_changed: usize,

    pub fn deinit(self: *DiffView, allocator: std.mem.Allocator) void {
        allocator.free(self.unified);
        allocator.free(self.before);
        allocator.free(self.after);
    }
};

/// Normalize CRLF (\r\n) to LF (\n), always returns a new allocation
pub fn normalizeLineEndings(allocator: std.mem.Allocator, content: []u8) ![]u8 {
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
pub fn lfToCrlf(allocator: std.mem.Allocator, content: []const u8) ![]u8 {
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

/// Generate unified diff format showing the change with git merge conflict style
/// Output includes both traditional unified diff AND split view with conflict markers:
///
/// ```diff
/// --- a/(file)
/// +++ b/(file)
/// @@ -start,count +start,count @@
///  context line
/// -removed line
/// +added line
/// ```
///
/// And then the split view:
///
/// ```txt
/// <<<<<<< BEFORE
/// old content
/// =======
/// new content
/// >>>>>>> AFTER
/// ```
pub fn generateUnifiedDiff(
    allocator: std.mem.Allocator,
    raw: []const u8,
    first: usize,
    old_str: []const u8,
    new_str: []const u8,
) !struct { unified: []const u8, lines_changed: usize } {
    // Split into lines
    var old_lines = std.ArrayList([]const u8).empty;
    defer old_lines.deinit(allocator);
    var new_lines = std.ArrayList([]const u8).empty;
    defer new_lines.deinit(allocator);

    var start: usize = 0;
    var i: usize = 0;
    while (i <= raw.len) : (i += 1) {
        const is_end = i == raw.len;
        const is_newline = i < raw.len and raw[i] == '\n';
        if (is_end or is_newline) {
            const end = if (is_newline) i else raw.len;
            const line = raw[start..end];
            try old_lines.append(allocator, line);
            try new_lines.append(allocator, line);
            start = i + 1;
        }
    }

    // Find which line the replacement starts on
    var line_idx: usize = 0;
    var char_count: usize = 0;
    while (line_idx < old_lines.items.len) {
        const line = old_lines.items[line_idx];
        if (char_count + line.len + 1 > first) break;
        char_count += line.len + 1; // +1 for newline
        line_idx += 1;
    }

    var old_str_line_list = std.ArrayList([]const u8).empty;
    defer old_str_line_list.deinit(allocator);
    start = 0;
    i = 0;
    while (i <= old_str.len) : (i += 1) {
        const is_end = i == old_str.len;
        const is_newline = i < old_str.len and old_str[i] == '\n';
        if (is_end or is_newline) {
            const end = if (is_newline) i else old_str.len;
            try old_str_line_list.append(allocator, old_str[start..end]);
            start = i + 1;
        }
    }

    // Split new_str into its lines
    var new_str_line_list = std.ArrayList([]const u8).empty;
    defer new_str_line_list.deinit(allocator);
    start = 0;
    i = 0;
    while (i <= new_str.len) : (i += 1) {
        const is_end = i == new_str.len;
        const is_newline = i < new_str.len and new_str[i] == '\n';
        if (is_end or is_newline) {
            const end = if (is_newline) i else new_str.len;
            try new_str_line_list.append(allocator, new_str[start..end]);
            start = i + 1;
        }
    }

    // Build unified diff output
    var diff = std.ArrayList(u8).empty;
    defer diff.deinit(allocator);

    // Determine context lines (3 before/after)
    const context_start: usize = if (line_idx >= 3) line_idx - 3 else 0;
    const old_end_line = line_idx + old_str_line_list.items.len;
    const new_end_line = line_idx + new_str_line_list.items.len;
    const context_end: usize = @min(old_lines.items.len, @max(old_end_line, new_end_line) + 3);

    // Write traditional unified diff header
    try diff.appendSlice(allocator, "--- a/(file)\n");
    try diff.appendSlice(allocator, "+++ b/(file)\n");

    // Write hunk header: @@ -start,count +start,count @@
    const old_count = context_end - context_start;
    const line_diff = if (new_str_line_list.items.len >= old_str_line_list.items.len)
        new_str_line_list.items.len - old_str_line_list.items.len
    else
        old_str_line_list.items.len - new_str_line_list.items.len;
    const new_count = context_end - context_start + line_diff;

    var hunk_buf: [64]u8 = undefined;
    const hunk = try std.fmt.bufPrint(&hunk_buf, "@@ -{d},{d} +{d},{d} @@\n", .{
        context_start + 1,
        old_count,
        context_start + 1,
        new_count,
    });
    try diff.appendSlice(allocator, hunk);

    // Write context + change lines
    var out_line_idx: usize = context_start;
    while (out_line_idx < context_end) : (out_line_idx += 1) {
        const is_in_old_range = out_line_idx >= line_idx and out_line_idx < old_end_line;
        const is_in_new_range = out_line_idx >= line_idx and out_line_idx < new_end_line;

        if (is_in_old_range and !is_in_new_range) {
            // Line removed
            try diff.append(allocator, '-');
            try diff.appendSlice(allocator, old_str_line_list.items[out_line_idx - line_idx]);
            try diff.append(allocator, '\n');
        } else if (!is_in_old_range and is_in_new_range) {
            // Line added
            try diff.append(allocator, '+');
            try diff.appendSlice(allocator, new_str_line_list.items[out_line_idx - line_idx]);
            try diff.append(allocator, '\n');
        } else {
            // Context line
            try diff.append(allocator, ' ');
            try diff.appendSlice(allocator, old_lines.items[out_line_idx]);
            try diff.append(allocator, '\n');
        }
    }

    // Append separator between unified diff and split view
    try diff.appendSlice(allocator, "\n");

    // Write git merge conflict style split view
    try diff.appendSlice(allocator, "<<<<<<< BEFORE\n");
    for (old_str_line_list.items) |line| {
        try diff.appendSlice(allocator, line);
        try diff.append(allocator, '\n');
    }
    try diff.appendSlice(allocator, "=======\n");
    for (new_str_line_list.items) |line| {
        try diff.appendSlice(allocator, line);
        try diff.append(allocator, '\n');
    }
    try diff.appendSlice(allocator, ">>>>>>> AFTER\n");

    const unified = try diff.toOwnedSlice(allocator);
    const lines_changed = old_str_line_list.items.len + new_str_line_list.items.len;

    return .{ .unified = unified, .lines_changed = lines_changed };
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

    // Generate unified diff view showing the change
    const diff_result = try generateUnifiedDiff(allocator, raw, first, old_str, new_str);
    errdefer allocator.free(diff_result.unified);

    // Create diff view with before/after content showing ONLY the changed region
    // (like git merge conflict: <<<<<<< BEFORE / ======= / >>>>>>> AFTER)
    // before = just old_str (what was removed)
    // after = just new_str (what was added)
    const before_content = try allocator.dupe(u8, old_str);
    errdefer allocator.free(before_content);

    // Build after content for diff view: just new_str
    const after_content = try allocator.dupe(u8, new_str);
    errdefer allocator.free(after_content);

    // Create diff view
    const diff_view = DiffView{
        .unified = diff_result.unified,
        .before = before_content,
        .after = after_content,
        .lines_changed = diff_result.lines_changed,
    };

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

    return TextReplaceResult{ .ok = {}, .diff_view = diff_view };
}

/// Create a minimal XML error output (no success field, just error + original args)
pub fn xmlError(allocator: std.mem.Allocator, err_msg: []const u8, path: []const u8, old_str: []const u8, new_str: []const u8) []const u8 {
    // XML-escape every user-controlled field. Otherwise a `&` or `<` in the
    // path / old_str / new_str silently corrupts the parsed XML on the
    // frontend (the `toolOutputParser.extractTag` will misalign).
    const escaped_err = xmlEscape(allocator, err_msg) catch "<success>false</success><error>UnknownError</error>";
    defer allocator.free(escaped_err);
    const escaped_path = xmlEscape(allocator, path) catch "<success>false</success><error>UnknownError</error>";
    defer allocator.free(escaped_path);
    const escaped_old = xmlEscape(allocator, old_str) catch "<success>false</success><error>UnknownError</error>";
    defer allocator.free(escaped_old);
    const escaped_new = xmlEscape(allocator, new_str) catch "<success>false</success><error>UnknownError</error>";
    defer allocator.free(escaped_new);
    return std.fmt.allocPrint(allocator,
        \\<error>{s}</error>
        \\<path>{s}</path>
        \\<old_str>{s}</old_str>
        \\<new_str>{s}</new_str>
        \\<success>false</success>
    , .{ escaped_err, escaped_path, escaped_old, escaped_new }) catch "<success>false</success><error>UnknownError</error>";
}

/// Serialize result to XML string with diff view (split + unified)
pub fn toXmlSuccess(allocator: std.mem.Allocator, result: TextReplaceResult, path: []const u8) []const u8 {
    const dv = result.diff_view;
    const unified = if (dv) |d| d.unified else "";
    const before = if (dv) |d| d.before else "";
    const after = if (dv) |d| d.after else "";
    const lines_changed = if (dv) |d| d.lines_changed else 0;

    // XML-escape every user-controlled field. Without this, a `&`, `<`, or
    // `>` in the path / before / after content would silently corrupt the
    // parsed XML on the frontend.
    const escaped_path = xmlEscape(allocator, path) catch "<success>true</success><path>Unknown</path>";
    defer allocator.free(escaped_path);
    const escaped_unified = xmlEscape(allocator, unified) catch "<success>true</success><path>Unknown</path>";
    defer allocator.free(escaped_unified);
    const escaped_before = xmlEscape(allocator, before) catch "<success>true</success><path>Unknown</path>";
    defer allocator.free(escaped_before);
    const escaped_after = xmlEscape(allocator, after) catch "<success>true</success><path>Unknown</path>";
    defer allocator.free(escaped_after);

    return std.fmt.allocPrint(allocator,
        \\<success>true</success>
        \\<path>{s}</path>
        \\<diff_view>
        \\<unified>{s}</unified>
        \\<before>{s}</before>
        \\<after>{s}</after>
        \\<lines_changed>{d}</lines_changed>
        \\</diff_view>
    , .{ escaped_path, escaped_unified, escaped_before, escaped_after, lines_changed }) catch "<success>true</success><path>Unknown</path>";
}

pub fn toXmlError(allocator: std.mem.Allocator, result: anyerror, path: []const u8, old_str: []const u8) []const u8 {
    _ = old_str;
    const error_msg = switch (result) {
        error.OldStrNotFound => std.fmt.allocPrint(allocator, "Make sure the text exists exactly once in the file.", .{}) catch return "<success>false</success><error>UnknownError</error>",
        error.OldStrNotUnique => std.fmt.allocPrint(allocator, "There are multiple occurrences of the text in the file. Expand old_str to include more context to make it unique.", .{}) catch return "<success>false</success><error>UnknownError</error>",
        error.PathNotFound => std.fmt.allocPrint(allocator, "File '{s}' not found. Check if the path is correct.", .{path}) catch return "<success>false</success><error>UnknownError</error>",
        error.WriteFailed => std.fmt.allocPrint(allocator, "Failed to write to file '{s}'.", .{path}) catch return "<success>false</success><error>UnknownError</error>",
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
pub const text_replace_tool: AgentTool = .{
    .type = "function",
    .function = .{
        .name = "text_replace",
        .description =
        \\Replace a string in a file. old_str must match exactly once;
        \\expand context if ambiguous. new_str can be empty to delete.
        \\Read the file first to confirm current content.
        ,
        .parameters = .{
            .type = "object",
            .properties = &.{
                .{ .name = "path", .type = "string", .description =
                    \\`path`: file path, RELATIVE to the session's cwd only
                    \\(absolute paths are rejected — security policy). Use a
                    \\relative path like `\"src/main.zig\"` (NOT
                    \\`\"/home/you/proj/src/main.zig\"`).
                    , },
                .{ .name = "old_str", .type = "string", .description = "Exact text to replace (must appear exactly once)." },
                .{ .name = "new_str", .type = "string", .description = "Replacement text, or empty string to delete." },
            },
            .required = &.{ "path", "old_str", "new_str" },
        },
    },
};

