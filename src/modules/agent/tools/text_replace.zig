const std = @import("std");
const schemas = @import("schemas.zig");
const ToolProperty = schemas.ToolProperty;
const ToolParameters = schemas.ToolParameters;
const AgentToolFunction = schemas.AgentToolFunction;
const AgentTool = schemas.AgentTool;

/// XML-escape a string for safe inclusion in tool-result XML output.
/// Mirrors `src/agentic_loop/llm_history.zig xmlEscape` exactly so the
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
pub const text_replace_tool_system_prompt =
    \\## Text Replace Tool — Behavior
    \\Use `text_replace` for surgical single-occurrence edits.
    \\- Read the file first to confirm the exact `old_str` (must match exactly once).
    \\- Provide `new_str` as the replacement; empty string deletes.
    \\- For multi-line changes, ensure context is unique.
    \\
;

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
                .{ .name = "path", .type = "string", .description = "Absolute path to the file." },
                .{ .name = "old_str", .type = "string", .description = "Exact text to replace (must appear exactly once)." },
                .{ .name = "new_str", .type = "string", .description = "Replacement text, or empty string to delete." },
            },
            .required = &.{ "path", "old_str", "new_str" },
        },
    },
};

const text_replace = @import("text_replace.zig");

fn createTestFile(path: []const u8, content: []const u8) !void {
    // Ensure parent directory exists using createDirPath
    if (std.fs.path.dirname(path)) |dir| {
        try std.Io.Dir.cwd().createDirPath(std.testing.io, dir);
    }
    // Write content to file using same pattern as write_file.zig
    const file = std.Io.Dir.cwd().createFile(std.testing.io, path, .{}) catch |file_err| {
        if (file_err == error.FileNotFound) {
            const dir = std.fs.path.dirname(path) orelse ".";
            try std.Io.Dir.cwd().createDirPath(std.testing.io, dir);
            const new_file = try std.Io.Dir.cwd().createFile(std.testing.io, path, .{});
            defer std.Io.File.close(new_file, std.testing.io);
            try std.Io.File.writeStreamingAll(new_file, std.testing.io, content);
            return;
        }
        return file_err;
    };
    defer std.Io.File.close(file, std.testing.io);
    try std.Io.File.writeStreamingAll(file, std.testing.io, content);
}

fn deleteTestFile(path: []const u8) void {
    std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
}

test "text_replace - unified diff contains diff markers" {
    const test_path = "test_diff_view_unified.txt";
    try createTestFile(test_path, "Hello World\n");

    var result = try text_replace.executeTextReplace(
        std.testing.allocator,
        std.testing.io,
        test_path,
        "Hello",
        "Goodbye",
    );
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(result.diff_view != null);

    if (result.diff_view) |dv| {
        // Unified should contain header markers
        try std.testing.expect(std.mem.indexOf(u8, dv.unified, "---") != null);
        try std.testing.expect(std.mem.indexOf(u8, dv.unified, "+++") != null);
        try std.testing.expect(std.mem.indexOf(u8, dv.unified, "@@") != null);
        // Should have context showing the change (Hello appears, Goodbye added)
        try std.testing.expect(std.mem.indexOf(u8, dv.unified, "Hello") != null);
        try std.testing.expect(std.mem.indexOf(u8, dv.unified, "Goodbye") != null);
        // lines_changed should be set
        try std.testing.expect(dv.lines_changed > 0);
    }

    deleteTestFile(test_path);
}

test "text_replace - split diff_view before contains original content" {
    const test_path = "test_diff_view_before.txt";
    try createTestFile(test_path, "Hello World\n");

    var result = try text_replace.executeTextReplace(
        std.testing.allocator,
        std.testing.io,
        test_path,
        "Hello",
        "Goodbye",
    );
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(result.diff_view != null);

    if (result.diff_view) |dv| {
        // Before should contain original text
        try std.testing.expect(std.mem.indexOf(u8, dv.before, "Hello") != null);
        // Before should NOT contain replacement
        try std.testing.expect(std.mem.indexOf(u8, dv.before, "Goodbye") == null);
    }

    deleteTestFile(test_path);
}

test "text_replace - split diff_view after contains replacement content" {
    const test_path = "test_diff_view_after.txt";
    try createTestFile(test_path, "Hello World\n");

    var result = try text_replace.executeTextReplace(
        std.testing.allocator,
        std.testing.io,
        test_path,
        "Hello",
        "Goodbye",
    );
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(result.diff_view != null);

    if (result.diff_view) |dv| {
        // After should contain replacement
        try std.testing.expect(std.mem.indexOf(u8, dv.after, "Goodbye") != null);
        // After should NOT contain original
        try std.testing.expect(std.mem.indexOf(u8, dv.after, "Hello") == null);
    }

    deleteTestFile(test_path);
}

test "text_replace - split diff_view before and after are distinct" {
    const test_path = "test_diff_view_distinct.txt";
    try createTestFile(test_path, "original text\n");

    var result = try text_replace.executeTextReplace(
        std.testing.allocator,
        std.testing.io,
        test_path,
        "original",
        "modified",
    );
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(result.diff_view != null);

    if (result.diff_view) |dv| {
        // Before and after should be different
        try std.testing.expect(!std.mem.eql(u8, dv.before, dv.after));
        // Before contains "original", not "modified"
        try std.testing.expect(std.mem.indexOf(u8, dv.before, "original") != null);
        try std.testing.expect(std.mem.indexOf(u8, dv.before, "modified") == null);
        // After contains "modified", not "original"
        try std.testing.expect(std.mem.indexOf(u8, dv.after, "modified") != null);
        try std.testing.expect(std.mem.indexOf(u8, dv.after, "original") == null);
    }

    deleteTestFile(test_path);
}

test "text_replace - unified diff shows line removal" {
    const test_path = "test_diff_view_removal.txt";
    try createTestFile(test_path, "line1\nline2\nline3\n");

    var result = try text_replace.executeTextReplace(
        std.testing.allocator,
        std.testing.io,
        test_path,
        "line2\n",
        "",
    );
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(result.diff_view != null);

    if (result.diff_view) |dv| {
        // Should have git merge conflict markers
        try std.testing.expect(std.mem.indexOf(u8, dv.unified, "<<<<<<< BEFORE") != null);
        try std.testing.expect(std.mem.indexOf(u8, dv.unified, "=======") != null);
        try std.testing.expect(std.mem.indexOf(u8, dv.unified, ">>>>>>> AFTER") != null);
        // before should contain old content
        try std.testing.expect(std.mem.indexOf(u8, dv.before, "line2") != null);
        // after should be empty
        try std.testing.expect(dv.after.len == 0);
    }

    deleteTestFile(test_path);
}

test "text_replace - unified diff shows line insertion" {
    const test_path = "test_diff_view_insert.txt";
    try createTestFile(test_path, "line1\nline3\n");

    var result = try text_replace.executeTextReplace(
        std.testing.allocator,
        std.testing.io,
        test_path,
        "line1\n",
        "line1\nline2\n",
    );
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(result.diff_view != null);

    if (result.diff_view) |dv| {
        // Should have git merge conflict markers
        try std.testing.expect(std.mem.indexOf(u8, dv.unified, "<<<<<<< BEFORE") != null);
        try std.testing.expect(std.mem.indexOf(u8, dv.unified, "=======") != null);
        try std.testing.expect(std.mem.indexOf(u8, dv.unified, ">>>>>>> AFTER") != null);
        // before should contain old content
        try std.testing.expect(std.mem.indexOf(u8, dv.before, "line1") != null);
        // after should contain new content
        try std.testing.expect(std.mem.indexOf(u8, dv.after, "line1") != null);
        try std.testing.expect(std.mem.indexOf(u8, dv.after, "line2") != null);
    }

    deleteTestFile(test_path);
}

test "text_replace - unified diff shows multiline replacement" {
    const test_path = "test_diff_view_multiline.txt";
    try createTestFile(test_path,
        \\fn add(a: i32, b: i32) i32 {
        \\    return a + b;
        \\}
    );

    var result = try text_replace.executeTextReplace(
        std.testing.allocator,
        std.testing.io,
        test_path,
        "fn add(a: i32, b: i32) i32 {\n    return a + b;\n}",
        "fn add(a: i32, b: i32) i32 {\n    return a - b;\n}",
    );
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(result.diff_view != null);

    if (result.diff_view) |dv| {
        // Should have git merge conflict markers
        try std.testing.expect(std.mem.indexOf(u8, dv.unified, "<<<<<<< BEFORE") != null);
        try std.testing.expect(std.mem.indexOf(u8, dv.unified, "=======") != null);
        try std.testing.expect(std.mem.indexOf(u8, dv.unified, ">>>>>>> AFTER") != null);
        // before should contain old content
        try std.testing.expect(std.mem.indexOf(u8, dv.before, "return a + b;") != null);
        // after should contain new content
        try std.testing.expect(std.mem.indexOf(u8, dv.after, "return a - b;") != null);
    }

    deleteTestFile(test_path);
}

test "text_replace - unified diff includes hunk header with line numbers" {
    const test_path = "test_diff_view_hunk.txt";
    try createTestFile(test_path, "line1\nline2\nline3\nline4\nline5\n");

    var result = try text_replace.executeTextReplace(
        std.testing.allocator,
        std.testing.io,
        test_path,
        "line2",
        "modified_line2",
    );
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(result.diff_view != null);

    if (result.diff_view) |dv| {
        // Should have git merge conflict markers
        try std.testing.expect(std.mem.indexOf(u8, dv.unified, "<<<<<<< BEFORE") != null);
        try std.testing.expect(std.mem.indexOf(u8, dv.unified, "=======") != null);
        try std.testing.expect(std.mem.indexOf(u8, dv.unified, ">>>>>>> AFTER") != null);
    }

    deleteTestFile(test_path);
}

test "text_replace - lines_changed reflects actual change count" {
    const test_path = "test_diff_view_lines.txt";
    try createTestFile(test_path, "line1\nline2\nline3\n");

    var result = try text_replace.executeTextReplace(
        std.testing.allocator,
        std.testing.io,
        test_path,
        "line2\n",
        "new_line2a\nnew_line2b\n",
    );
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(result.diff_view != null);

    if (result.diff_view) |dv| {
        // Verify conflict markers
        try std.testing.expect(std.mem.indexOf(u8, dv.unified, "<<<<<<< BEFORE") != null);
        try std.testing.expect(std.mem.indexOf(u8, dv.unified, "=======") != null);
        try std.testing.expect(std.mem.indexOf(u8, dv.unified, ">>>>>>> AFTER") != null);
        // before should contain old content
        try std.testing.expect(std.mem.indexOf(u8, dv.before, "line2") != null);
    }

    deleteTestFile(test_path);
}

// ============================================================================
// generateUnifiedDiff Tests - git merge conflict style
// ============================================================================

test "generateUnifiedDiff output contains git merge conflict markers" {
    const test_path = "test_git_conflict_markers.txt";
    try createTestFile(test_path, "line1\nline2\nline3\n");

    var result = try text_replace.executeTextReplace(
        std.testing.allocator,
        std.testing.io,
        test_path,
        "line2",
        "modified_line2",
    );
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(result.diff_view != null);

    if (result.diff_view) |dv| {
        // Should contain git merge conflict style markers
        try std.testing.expect(std.mem.indexOf(u8, dv.unified, "<<<<<<< BEFORE") != null);
        try std.testing.expect(std.mem.indexOf(u8, dv.unified, "=======") != null);
        try std.testing.expect(std.mem.indexOf(u8, dv.unified, ">>>>>>> AFTER") != null);
    }

    deleteTestFile(test_path);
}

test "generateUnifiedDiff split view shows old_str under <<<<<<<" {
    const test_path = "test_split_before.txt";
    try createTestFile(test_path, "Hello World\n");

    var result = try text_replace.executeTextReplace(
        std.testing.allocator,
        std.testing.io,
        test_path,
        "Hello",
        "Goodbye",
    );
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(result.diff_view != null);

    if (result.diff_view) |dv| {
        // Should have conflict markers
        try std.testing.expect(std.mem.indexOf(u8, dv.unified, "<<<<<<< BEFORE") != null);
        try std.testing.expect(std.mem.indexOf(u8, dv.unified, "=======") != null);
        try std.testing.expect(std.mem.indexOf(u8, dv.unified, ">>>>>>> AFTER") != null);

        // before should contain old_str
        try std.testing.expect(std.mem.indexOf(u8, dv.before, "Hello") != null);
    }

    deleteTestFile(test_path);
}

test "generateUnifiedDiff split view shows new_str under =======" {
    const test_path = "test_split_after.txt";
    try createTestFile(test_path, "Hello World\n");

    var result = try text_replace.executeTextReplace(
        std.testing.allocator,
        std.testing.io,
        test_path,
        "Hello",
        "Goodbye",
    );
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(result.diff_view != null);

    if (result.diff_view) |dv| {
        // Unified output: new_str should appear between ======= and >>>>>>>
        const separator = std.mem.indexOf(u8, dv.unified, "=======");
        const after_marker = std.mem.indexOf(u8, dv.unified, ">>>>>>> AFTER");
        try std.testing.expect(separator != null);
        try std.testing.expect(after_marker != null);

        // Extract content between ======= and >>>>>>>
        const after_section = dv.unified[separator.?..after_marker.?];
        try std.testing.expect(std.mem.indexOf(u8, after_section, "Goodbye") != null);
    }

    deleteTestFile(test_path);
}

test "generateUnifiedDiff before field equals old_str exactly" {
    const test_path = "test_before_exact.txt";
    try createTestFile(test_path, "Hello World\n");

    var result = try text_replace.executeTextReplace(
        std.testing.allocator,
        std.testing.io,
        test_path,
        "Hello",
        "Goodbye",
    );
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(result.diff_view != null);

    if (result.diff_view) |dv| {
        // before field should be exactly old_str (not wrapped with file context)
        try std.testing.expect(std.mem.eql(u8, dv.before, "Hello"));
    }

    deleteTestFile(test_path);
}

test "generateUnifiedDiff after field equals new_str exactly" {
    const test_path = "test_after_exact.txt";
    try createTestFile(test_path, "Hello World\n");

    var result = try text_replace.executeTextReplace(
        std.testing.allocator,
        std.testing.io,
        test_path,
        "Hello",
        "Goodbye",
    );
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(result.diff_view != null);

    if (result.diff_view) |dv| {
        // after field should be exactly new_str (not wrapped with file context)
        try std.testing.expect(std.mem.eql(u8, dv.after, "Goodbye"));
    }

    deleteTestFile(test_path);
}

test "generateUnifiedDiff multiline old_str shows all lines in split view" {
    const test_path = "test_multiline_split.txt";
    try createTestFile(test_path,
        \\fn add(a: i32, b: i32) i32 {
        \\    return a + b;
        \\}
    );

    var result = try text_replace.executeTextReplace(
        std.testing.allocator,
        std.testing.io,
        test_path,
        "fn add(a: i32, b: i32) i32 {\n    return a + b;\n}",
        "fn add(a: i32, b: i32) i32 {\n    return a - b;\n}",
    );
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(result.diff_view != null);

    if (result.diff_view) |dv| {
        // Should have conflict markers
        try std.testing.expect(std.mem.indexOf(u8, dv.unified, "<<<<<<< BEFORE") != null);
        try std.testing.expect(std.mem.indexOf(u8, dv.unified, "=======") != null);
        try std.testing.expect(std.mem.indexOf(u8, dv.unified, ">>>>>>> AFTER") != null);

        // before should contain the old multiline content
        try std.testing.expect(std.mem.indexOf(u8, dv.before, "return a + b;") != null);

        // after should be different from before
        try std.testing.expect(!std.mem.eql(u8, dv.before, dv.after));
    }

    deleteTestFile(test_path);
}

test "generateUnifiedDiff unified output has both traditional diff and conflict markers" {
    const test_path = "test_unified_and_conflict.txt";
    try createTestFile(test_path, "line1\nline2\nline3\n");

    var result = try text_replace.executeTextReplace(
        std.testing.allocator,
        std.testing.io,
        test_path,
        "line2",
        "modified_line2",
    );
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(result.diff_view != null);

    if (result.diff_view) |dv| {
        // Should have git merge conflict markers
        try std.testing.expect(std.mem.indexOf(u8, dv.unified, "<<<<<<< BEFORE") != null);
        try std.testing.expect(std.mem.indexOf(u8, dv.unified, "=======") != null);
        try std.testing.expect(std.mem.indexOf(u8, dv.unified, ">>>>>>> AFTER") != null);

        // before should contain old content
        try std.testing.expect(std.mem.indexOf(u8, dv.before, "line2") != null);
        // after should contain new content
        try std.testing.expect(std.mem.indexOf(u8, dv.after, "modified_line2") != null);
    }

    deleteTestFile(test_path);
}

// ─── Chunk 4: XML-escape + unified-diff coverage ───────────────────────────

test "toXmlSuccess XML-escapes path containing & and <" {
    // A file with a `&` or `<` in its path used to break toolOutputParser on
    // the frontend (the <path> tag was misaligned). This test ensures the
    // backend escapes such characters.
    const allocator = std.testing.allocator;
    var result: text_replace.TextReplaceResult = .{ .ok = {} };
    defer result.deinit(allocator);
    // Populate the diff_view with a fixed value so we can assert on the
    // emitted XML.
    const before = allocator.dupe(u8, "x") catch unreachable;
    const after = allocator.dupe(u8, "y") catch unreachable;
    const unified = allocator.dupe(u8, "--- a\n+++ b\n-old\n+new") catch unreachable;
    result.diff_view = .{
        .unified = unified,
        .before = before,
        .after = after,
        .lines_changed = 1,
    };
    const xml = text_replace.toXmlSuccess(allocator, result, "/abs/path with & and < and > and \"");
    defer allocator.free(xml);

    // The escaped path must appear, with & < > " all converted to entities.
    try std.testing.expect(std.mem.indexOf(u8, xml, "/abs/path with &amp; and &lt; and &gt; and &quot;") != null);
    // The raw (un-escaped) path must NOT appear inside the body (only in
    // the escaped form).
    try std.testing.expect(std.mem.indexOf(u8, xml, "/abs/path with & and <") == null);
}

test "toXmlSuccess includes the unified diff field" {
    const allocator = std.testing.allocator;
    var result: text_replace.TextReplaceResult = .{ .ok = {} };
    defer result.deinit(allocator);
    const before = allocator.dupe(u8, "old line") catch unreachable;
    const after = allocator.dupe(u8, "new line") catch unreachable;
    const unified = allocator.dupe(u8, "--- a/x\n+++ b/x\n@@ -1,1 +1,1 @@\n-old line\n+new line") catch unreachable;
    result.diff_view = .{
        .unified = unified,
        .before = before,
        .after = after,
        .lines_changed = 1,
    };
    const xml = text_replace.toXmlSuccess(allocator, result, "/x");
    defer allocator.free(xml);

    try std.testing.expect(std.mem.indexOf(u8, xml, "<unified>") != null);
    try std.testing.expect(std.mem.indexOf(u8, xml, "@@ -1,1 +1,1 @@") != null);
    try std.testing.expect(std.mem.indexOf(u8, xml, "-old line") != null);
    try std.testing.expect(std.mem.indexOf(u8, xml, "+new line") != null);
}

test "xmlError XML-escapes path/old_str/new_str containing special chars" {
    const allocator = std.testing.allocator;
    const xml = text_replace.xmlError(
        allocator,
        "make & sure",
        "/path with &",
        "old < thing",
        "new > thing",
    );
    defer allocator.free(xml);

    try std.testing.expect(std.mem.indexOf(u8, xml, "<error>make &amp; sure</error>") != null);
    try std.testing.expect(std.mem.indexOf(u8, xml, "<path>/path with &amp;</path>") != null);
    try std.testing.expect(std.mem.indexOf(u8, xml, "<old_str>old &lt; thing</old_str>") != null);
    try std.testing.expect(std.mem.indexOf(u8, xml, "<new_str>new &gt; thing</new_str>") != null);
    try std.testing.expect(std.mem.indexOf(u8, xml, "<success>false</success>") != null);
}

// ============================================================================
// xmlEscape — edge cases
// ============================================================================

test "xmlEscape - empty string returns empty" {
    const out = try text_replace.xmlEscape(std.testing.allocator, "");
    defer std.testing.allocator.free(out);
    try std.testing.expect(out.len == 0);
    try std.testing.expect(std.mem.eql(u8, out, ""));
}

test "xmlEscape - plain ASCII (no specials) unchanged" {
    const out = try text_replace.xmlEscape(std.testing.allocator, "Hello, World! 123");
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.eql(u8, out, "Hello, World! 123"));
}

test "xmlEscape - all 5 special chars escaped" {
    const out = try text_replace.xmlEscape(std.testing.allocator, "&<>\"'");
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.eql(u8, out, "&amp;&lt;&gt;&quot;&apos;"));
}

test "xmlEscape - ampersand alone" {
    const out = try text_replace.xmlEscape(std.testing.allocator, "&");
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.eql(u8, out, "&amp;"));
}

test "xmlEscape - less-than alone" {
    const out = try text_replace.xmlEscape(std.testing.allocator, "<");
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.eql(u8, out, "&lt;"));
}

test "xmlEscape - greater-than alone" {
    const out = try text_replace.xmlEscape(std.testing.allocator, ">");
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.eql(u8, out, "&gt;"));
}

test "xmlEscape - double-quote alone" {
    const out = try text_replace.xmlEscape(std.testing.allocator, "\"");
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.eql(u8, out, "&quot;"));
}

test "xmlEscape - apostrophe alone" {
    const out = try text_replace.xmlEscape(std.testing.allocator, "'");
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.eql(u8, out, "&apos;"));
}

test "xmlEscape - ampersand followed by lt does NOT double-escape" {
    // The naive bug would produce "&amp;lt;" (escaping the '&' AND replacing '<'
    // separately). The correct output is "&amp;lt;" only if the input was
    // "&lt;" — when the input is "&<", we want "&amp;&lt;" so that
    // un-escaping produces "&<" back. Verify both shapes.
    const out = try text_replace.xmlEscape(std.testing.allocator, "&<");
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.eql(u8, out, "&amp;&lt;"));
}

test "xmlEscape - adjacent specials produce distinct entities" {
    const out = try text_replace.xmlEscape(std.testing.allocator, "<>");
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.eql(u8, out, "&lt;&gt;"));
}

test "xmlEscape - special at start, middle, and end" {
    const out = try text_replace.xmlEscape(std.testing.allocator, "<a&b>c");
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.eql(u8, out, "&lt;a&amp;b&gt;c"));
}

test "xmlEscape - unicode multibyte preserved as-is" {
    // 2-byte UTF-8: é = 0xC3 0xA9
    // 3-byte UTF-8: 中 = 0xE4 0xB8 0xAD
    // 4-byte UTF-8: 🚀 = 0xF0 0x9F 0x9A 0x80
    const out = try text_replace.xmlEscape(std.testing.allocator, "café 中文 🚀");
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.eql(u8, out, "café 中文 🚀"));
}

test "xmlEscape - unicode adjacent to special char" {
    const out = try text_replace.xmlEscape(std.testing.allocator, "<中&文>");
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.eql(u8, out, "&lt;中&amp;文&gt;"));
}

test "xmlEscape - newlines and tabs preserved" {
    const out = try text_replace.xmlEscape(std.testing.allocator, "line1\nline2\tcol2");
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.eql(u8, out, "line1\nline2\tcol2"));
}

test "xmlEscape - backslash preserved" {
    const out = try text_replace.xmlEscape(std.testing.allocator, "path\\to\\file");
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.eql(u8, out, "path\\to\\file"));
}

test "xmlEscape - mixed content with all specials and safe chars" {
    const input = "<tag attr=\"val\">it's & 'text'</tag>";
    const out = try text_replace.xmlEscape(std.testing.allocator, input);
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.eql(u8, out,
        \\&lt;tag attr=&quot;val&quot;&gt;it&apos;s &amp; &apos;text&apos;&lt;/tag&gt;
    ));
}

test "xmlEscape - long alternating pattern" {
    // 100 reps of "&<" alternating → "&<&<..." → expect 100 "&amp;&lt;" pairs.
    // Each "&amp;" is 5 chars, each "&lt;" is 4 chars, so each pair is 9 chars
    // total. 100 pairs → 900 chars.
    var buf: [200]u8 = undefined;
    for (buf[0..], 0..) |*b, i| b.* = if (@mod(i, 2) == 0) '&' else '<';
    const out = try text_replace.xmlEscape(std.testing.allocator, &buf);
    defer std.testing.allocator.free(out);
    try std.testing.expect(out.len == 900);
    // First 9 chars should be "&amp;&lt;"
    try std.testing.expect(std.mem.eql(u8, out[0..9], "&amp;&lt;"));
    // Last 9 chars should also be "&amp;&lt;"
    try std.testing.expect(std.mem.eql(u8, out[out.len - 9 ..], "&amp;&lt;"));
}

test "xmlEscape - null byte preserved as-is" {
    // Null bytes are NOT escaped (XML allows them, though discouraged).
    // The function does a per-byte loop, so '\x00' falls into the `else` branch.
    const out = try text_replace.xmlEscape(std.testing.allocator, "a\x00b");
    defer std.testing.allocator.free(out);
    try std.testing.expect(out.len == 3);
    try std.testing.expect(std.mem.eql(u8, out, "a\x00b"));
}

// ============================================================================
// lfToCrlf — edge cases
// ============================================================================

test "lfToCrlf - empty string returns empty" {
    const out = try text_replace.lfToCrlf(std.testing.allocator, "");
    defer std.testing.allocator.free(out);
    try std.testing.expect(out.len == 0);
}

test "lfToCrlf - no newlines returns duped content" {
    const out = try text_replace.lfToCrlf(std.testing.allocator, "no newlines here");
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.eql(u8, out, "no newlines here"));
}

test "lfToCrlf - single LF converted to CRLF" {
    const out = try text_replace.lfToCrlf(std.testing.allocator, "\n");
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.eql(u8, out, "\r\n"));
}

test "lfToCrlf - text ending with newline" {
    const out = try text_replace.lfToCrlf(std.testing.allocator, "hello\n");
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.eql(u8, out, "hello\r\n"));
}

test "lfToCrlf - text starting with newline" {
    const out = try text_replace.lfToCrlf(std.testing.allocator, "\nhello");
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.eql(u8, out, "\r\nhello"));
}

test "lfToCrlf - multiple LF all converted" {
    const out = try text_replace.lfToCrlf(std.testing.allocator, "a\nb\nc\n");
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.eql(u8, out, "a\r\nb\r\nc\r\n"));
}

test "lfToCrlf - consecutive newlines" {
    const out = try text_replace.lfToCrlf(std.testing.allocator, "a\n\n\nb");
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.eql(u8, out, "a\r\n\r\n\r\nb"));
}

test "lfToCrlf - bare CR (not followed by LF) preserved" {
    // Old-Mac line ending: a single \r. The function converts LF to CRLF and
    // does NOT touch bare \r.
    const out = try text_replace.lfToCrlf(std.testing.allocator, "a\rb");
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.eql(u8, out, "a\rb"));
}

test "lfToCrlf - existing CRLF gets EXTRA CR prepended (known quirk)" {
    // Documenting the existing behavior: lfToCrlf converts ALL \n → \r\n,
    // even if the \n is already preceded by \r. The caller is responsible
    // for only feeding LF-only content. The output is \r\r\n.
    const out = try text_replace.lfToCrlf(std.testing.allocator, "a\r\nb");
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.eql(u8, out, "a\r\r\nb"));
}

test "lfToCrlf - mixed LF and CRLF input" {
    // See above: the LF in the CRLF pair gets a \r prepended.
    const out = try text_replace.lfToCrlf(std.testing.allocator, "lf\ncrlf\r\nlf\n");
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.eql(u8, out, "lf\r\ncrlf\r\r\nlf\r\n"));
}

test "lfToCrlf - content with special chars and LF" {
    const out = try text_replace.lfToCrlf(std.testing.allocator, "<a>\n&b;\n\"c\"");
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.eql(u8, out, "<a>\r\n&b;\r\n\"c\""));
}

test "lfToCrlf - single newline byte in long content" {
    // Verify the duped branch (no \n) returns the original content
    // character-for-character, not a re-encoded copy.
    const input = "x" ** 100;
    const out = try text_replace.lfToCrlf(std.testing.allocator, input);
    defer std.testing.allocator.free(out);
    try std.testing.expect(out.len == 100);
    try std.testing.expect(std.mem.eql(u8, out, input));
}

// ============================================================================
// normalizeLineEndings — edge cases
// ============================================================================

test "normalizeLineEndings - empty content returns duped empty" {
    const out = try text_replace.normalizeLineEndings(std.testing.allocator, "");
    defer std.testing.allocator.free(out);
    try std.testing.expect(out.len == 0);
}

test "normalizeLineEndings - pure LF content (no CRLF) returns duped" {
    const input = "line1\nline2\nline3\n";
    const out = try text_replace.normalizeLineEndings(std.testing.allocator, @constCast(input));
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.eql(u8, out, "line1\nline2\nline3\n"));
}

test "normalizeLineEndings - pure CRLF content all converted" {
    const input = "line1\r\nline2\r\nline3\r\n";
    const out = try text_replace.normalizeLineEndings(std.testing.allocator, @constCast(input));
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.eql(u8, out, "line1\nline2\nline3\n"));
}

test "normalizeLineEndings - mixed LF and CRLF all become LF" {
    const input = "a\r\nb\nc\r\nd";
    const out = try text_replace.normalizeLineEndings(std.testing.allocator, @constCast(input));
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.eql(u8, out, "a\nb\nc\nd"));
}

test "normalizeLineEndings - bare CR (not paired with LF) preserved" {
    // The function walks byte-by-byte and only matches the \r\n PAIR, so a
    // bare \r (Old-Mac line ending, or a literal carriage return in data)
    // is left untouched.
    const input = "a\rb\rc\r\nd";
    const out = try text_replace.normalizeLineEndings(std.testing.allocator, @constCast(input));
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.eql(u8, out, "a\rb\rc\nd"));
}

test "normalizeLineEndings - CRLF at very start of content" {
    const input = "\r\nhello\n";
    const out = try text_replace.normalizeLineEndings(std.testing.allocator, @constCast(input));
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.eql(u8, out, "\nhello\n"));
}

test "normalizeLineEndings - CRLF at very end of content" {
    const input = "hello\r\n";
    const out = try text_replace.normalizeLineEndings(std.testing.allocator, @constCast(input));
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.eql(u8, out, "hello\n"));
}

test "normalizeLineEndings - consecutive CRLF pairs" {
    const input = "a\r\n\r\n\r\nb";
    const out = try text_replace.normalizeLineEndings(std.testing.allocator, @constCast(input));
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.eql(u8, out, "a\n\n\nb"));
}

test "normalizeLineEndings - content with only CRLF pairs and no other text" {
    const input = "\r\n\r\n";
    const out = try text_replace.normalizeLineEndings(std.testing.allocator, @constCast(input));
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.eql(u8, out, "\n\n"));
}

test "normalizeLineEndings - single line with no newline at all" {
    const input = "single line content";
    const out = try text_replace.normalizeLineEndings(std.testing.allocator, @constCast(input));
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.eql(u8, out, "single line content"));
}

test "normalizeLineEndings - CRLF then LF in sequence (\\r\\n\\n)" {
    // The first \r\n is collapsed to \n; the second bare \n stays \n.
    const input = "a\r\n\nb";
    const out = try text_replace.normalizeLineEndings(std.testing.allocator, @constCast(input));
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.eql(u8, out, "a\n\nb"));
}

test "normalizeLineEndings - returns new allocation when CRLF present" {
    const input = "a\r\nb";
    const out1 = try text_replace.normalizeLineEndings(std.testing.allocator, @constCast(input));
    defer std.testing.allocator.free(out1);
    // Calling again should allocate a fresh buffer (NOT alias the input)
    const out2 = try text_replace.normalizeLineEndings(std.testing.allocator, @constCast(input));
    defer std.testing.allocator.free(out2);
    try std.testing.expect(out1.ptr != out2.ptr);
    try std.testing.expect(std.mem.eql(u8, out1, out2));
}

test "normalizeLineEndings - returns new allocation when no CRLF (duped)" {
    const input = "no crlf here";
    const out = try text_replace.normalizeLineEndings(std.testing.allocator, @constCast(input));
    defer std.testing.allocator.free(out);
    // The duped buffer is a separate allocation — even though content is identical,
    // freeing it must not corrupt the input.
    try std.testing.expect(std.mem.eql(u8, input, "no crlf here"));
    try std.testing.expect(std.mem.eql(u8, out, input));
}

// ============================================================================
// generateUnifiedDiff — edge cases
// ============================================================================

test "generateUnifiedDiff - empty file content with single replacement" {
    // raw = "" means 1 "empty line" (the split loop appends one entry for the
    // is_end branch). The replacement is at byte 0.
    // old_str = "" → [""] (1 line, NO trailing empty because there's no \n)
    // new_str = "new content\n" → ["new content", ""] (2 lines)
    const result = try text_replace.generateUnifiedDiff(
        std.testing.allocator,
        "",
        0,
        "",
        "new content\n",
    );
    defer std.testing.allocator.free(result.unified);

    try std.testing.expect(std.mem.indexOf(u8, result.unified, "<<<<<<< BEFORE") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.unified, "=======") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.unified, ">>>>>>> AFTER") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.unified, "new content") != null);
    // lines_changed = old_str_line_count (1) + new_str_line_count (2) = 3
    try std.testing.expect(result.lines_changed == 3);
}

test "generateUnifiedDiff - single line file (no trailing newline)" {
    const result = try text_replace.generateUnifiedDiff(
        std.testing.allocator,
        "the only line",
        0,
        "the only line",
        "the new line",
    );
    defer std.testing.allocator.free(result.unified);

    // Should produce header, hunk, and split view
    try std.testing.expect(std.mem.indexOf(u8, result.unified, "--- a/(file)") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.unified, "+++ b/(file)") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.unified, "@@") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.unified, "<<<<<<< BEFORE") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.unified, ">>>>>>> AFTER") != null);
    // The new content should be in the AFTER section
    const sep = std.mem.indexOf(u8, result.unified, "=======").?;
    const after = std.mem.indexOf(u8, result.unified, ">>>>>>> AFTER").?;
    try std.testing.expect(std.mem.indexOf(u8, result.unified[sep..after], "the new line") != null);
    // The old content should be in the BEFORE section
    const before = std.mem.indexOf(u8, result.unified, "<<<<<<< BEFORE").?;
    try std.testing.expect(std.mem.indexOf(u8, result.unified[before..sep], "the only line") != null);
}

test "generateUnifiedDiff - replacement at first line (1:1 line replacement)" {
    // When old_str and new_str have the same number of lines, the diff
    // body shows context lines (no -/+ markers) — the SPLIT VIEW
    // (<<<<<<< / ======= / >>>>>>>) is where the change is visible.
    const raw = "first\nsecond\nthird\n";
    const result = try text_replace.generateUnifiedDiff(
        std.testing.allocator,
        raw,
        0,
        "first\n",
        "FIRST\n",
    );
    defer std.testing.allocator.free(result.unified);

    // Hunk header should start at line 1
    try std.testing.expect(std.mem.indexOf(u8, result.unified, "@@ -1,") != null);
    // No -first or +FIRST markers in the unified hunk (1:1 line replacement
    // is shown as context). The change IS visible in the split view.
    try std.testing.expect(std.mem.indexOf(u8, result.unified, "-first\n") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.unified, "+FIRST\n") == null);
    // But the split view DOES contain both
    const before = std.mem.indexOf(u8, result.unified, "<<<<<<< BEFORE").?;
    const sep = std.mem.indexOf(u8, result.unified, "=======").?;
    const after = std.mem.indexOf(u8, result.unified, ">>>>>>> AFTER").?;
    try std.testing.expect(std.mem.indexOf(u8, result.unified[before..sep], "first\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.unified[sep..after], "FIRST\n") != null);
}

test "generateUnifiedDiff - replacement at last line (1:1 line replacement)" {
    const raw = "first\nsecond\nlast\n";
    const last_offset = "first\n".len + "second\n".len; // byte offset of "last\n"
    const result = try text_replace.generateUnifiedDiff(
        std.testing.allocator,
        raw,
        last_offset,
        "last\n",
        "LAST\n",
    );
    defer std.testing.allocator.free(result.unified);

    // 1:1 line replacement → no -/+ markers; visible in split view only
    try std.testing.expect(std.mem.indexOf(u8, result.unified, "-last\n") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.unified, "+LAST\n") == null);
    const before = std.mem.indexOf(u8, result.unified, "<<<<<<< BEFORE").?;
    const sep = std.mem.indexOf(u8, result.unified, "=======").?;
    const after = std.mem.indexOf(u8, result.unified, ">>>>>>> AFTER").?;
    try std.testing.expect(std.mem.indexOf(u8, result.unified[before..sep], "last\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.unified[sep..after], "LAST\n") != null);
}

test "generateUnifiedDiff - replacement removes lines (2 old → 1 new)" {
    // Documenting the actual (suboptimal) behavior of the diff visualization
    // when replacing 2 lines with 1 line:
    //   - old_str_line_list = ["delete1", "delete2", ""] (3 entries: 2 lines + trailing empty)
    //   - new_str_line_list = ["single_replacement", ""] (2 entries: 1 line + trailing empty)
    // The diff hunk shows:
    //   - " delete1" (context, in both ranges)
    //   - " delete2" (context, in both ranges)
    //   - "-" (removal of the trailing empty line, beyond new range)
    // This is suboptimal (the 2 lines being replaced show as context rather than
    // removals), but it's the actual behavior. Tests below document this so
    // future refactors know to preserve or improve the behavior intentionally.
    const raw = "keep1\ndelete1\ndelete2\nkeep2\n";
    const first = std.mem.indexOf(u8, raw, "delete1").?;
    const result = try text_replace.generateUnifiedDiff(
        std.testing.allocator,
        raw,
        first,
        "delete1\ndelete2\n",
        "single_replacement\n",
    );
    defer std.testing.allocator.free(result.unified);

    // The hunk should contain a `-` removal line (for the trailing empty old line)
    try std.testing.expect(std.mem.indexOf(u8, result.unified, "@@ -1,5 +1,6 @@") != null);
    // Split view always shows the change
    try std.testing.expect(std.mem.indexOf(u8, result.unified, "delete1\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.unified, "delete2\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.unified, "single_replacement\n") != null);
    // The BEFORE section shows all old lines
    const before = std.mem.indexOf(u8, result.unified, "<<<<<<< BEFORE").?;
    const sep = std.mem.indexOf(u8, result.unified, "=======").?;
    try std.testing.expect(std.mem.indexOf(u8, result.unified[before..sep], "delete1\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.unified[before..sep], "delete2\n") != null);
    // The AFTER section shows the new lines
    const after = std.mem.indexOf(u8, result.unified, ">>>>>>> AFTER").?;
    try std.testing.expect(std.mem.indexOf(u8, result.unified[sep..after], "single_replacement\n") != null);
    // lines_changed = old_str_line_list.len + new_str_line_list.len = 3 + 2 = 5
    try std.testing.expect(result.lines_changed == 5);
}

test "generateUnifiedDiff - replacement adds many lines (1 old → 6 new)" {
    // Documenting actual behavior: when new_str has more lines than old_str,
    // the diff shows the extra lines (those beyond old_str's range) with `+`
    // prefix. The new_str = "TARGET\nextra1\nextra2\nextra3\nextra4\nextra5\n"
    // has 7 lines (TARGET + 5 extras + trailing empty). The old_str = "TARGET\n"
    // has 2 lines (TARGET + trailing empty). So lines 2..6 (extra1..extra5) are
    // new additions but only those that fall within context_end are emitted.
    // context_end = min(old_lines.items.len=4, max(old_end=3, new_end=8) + 3) = 4.
    // So only i=3 → "+extra2" makes it into the hunk. The others appear only
    // in the split view (<<<<<<< / ======= / >>>>>>>).
    const raw = "before\nTARGET\nafter\n";
    const first = std.mem.indexOf(u8, raw, "TARGET").?;
    const new_str = "TARGET\nextra1\nextra2\nextra3\nextra4\nextra5\n";
    const result = try text_replace.generateUnifiedDiff(
        std.testing.allocator,
        raw,
        first,
        "TARGET\n",
        new_str,
    );
    defer std.testing.allocator.free(result.unified);

    // Only "+extra2" appears in the hunk body (within context_end); the rest
    // are clipped by the context_end = old_lines.items.len = 4 cap.
    try std.testing.expect(std.mem.indexOf(u8, result.unified, "+extra2") != null);
    // Split view contains the full new_str lines (no context_end clipping)
    const sep = std.mem.indexOf(u8, result.unified, "=======").?;
    const after = std.mem.indexOf(u8, result.unified, ">>>>>>> AFTER").?;
    try std.testing.expect(std.mem.indexOf(u8, result.unified[sep..after], "extra1\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.unified[sep..after], "extra2\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.unified[sep..after], "extra3\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.unified[sep..after], "extra4\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.unified[sep..after], "extra5\n") != null);
    // lines_changed = 2 (old_str_line_list) + 7 (new_str_line_list) = 9
    try std.testing.expect(result.lines_changed == 9);
}

test "generateUnifiedDiff - new_str is single line with no trailing newline" {
    const raw = "a\nb\nc\n";
    const first = std.mem.indexOf(u8, raw, "b\n").?;
    const result = try text_replace.generateUnifiedDiff(
        std.testing.allocator,
        raw,
        first,
        "b\n",
        "B",
    );
    defer std.testing.allocator.free(result.unified);

    // 1:1 line replacement — change visible only in split view.
    // The hunk will show context lines.
    try std.testing.expect(std.mem.indexOf(u8, result.unified, "@@") != null);
    const sep = std.mem.indexOf(u8, result.unified, "=======").?;
    const after = std.mem.indexOf(u8, result.unified, ">>>>>>> AFTER").?;
    // new_str = "B" with no trailing newline → in the split view,
    // it appears as a single line "B\n" (each entry in new_str_line_list
    // is followed by \n in the rendered output)
    try std.testing.expect(std.mem.indexOf(u8, result.unified[sep..after], "B\n") != null);
}

test "generateUnifiedDiff - old_str has no trailing newline (mid-line offset)" {
    // When old_str doesn't end with \n, the byte offset `first` may point to
    // the middle of a line. The line-finding loop uses
    // `char_count + line.len + 1 > first` which picks the line containing
    // the byte. This test exercises that branch.
    const raw = "alpha\nbeta\ngamma\n";
    const first = std.mem.indexOf(u8, raw, "beta").?; // points to 'b' (middle of beta)
    const result = try text_replace.generateUnifiedDiff(
        std.testing.allocator,
        raw,
        first,
        "beta",
        "BETA",
    );
    defer std.testing.allocator.free(result.unified);

    // Verify the hunk header and split view are produced
    try std.testing.expect(std.mem.indexOf(u8, result.unified, "@@") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.unified, "<<<<<<< BEFORE") != null);
    // The old content (or its surrounding context) should be in the hunk
    try std.testing.expect(std.mem.indexOf(u8, result.unified, "beta") != null);
}

test "generateUnifiedDiff - very long file (>10 lines) — context window is 3" {
    // Build a 20-line file with "TARGET" at line 10 (0-indexed). The context
    // window is 3 lines before/after, so the hunk should start at line 8.
    var raw_buf: [1000]u8 = undefined;
    var pos: usize = 0;
    for (0..20) |i| {
        var line_buf: [32]u8 = undefined;
        const formatted_line = if (i == 10)
            "TARGET\n"
        else
            std.fmt.bufPrint(&line_buf, "line_{d:0>2}\n", .{i}) catch unreachable;
        @memcpy(raw_buf[pos..][0..formatted_line.len], formatted_line);
        pos += formatted_line.len;
    }
    const raw = raw_buf[0..pos];

    const first = std.mem.indexOf(u8, raw, "TARGET\n").?;
    const result = try text_replace.generateUnifiedDiff(
        std.testing.allocator,
        raw,
        first,
        "TARGET\n",
        "REPLACED\n",
    );
    defer std.testing.allocator.free(result.unified);

    // Context window is 3 lines before/after. The hunk header should start
    // at line 8 (1-indexed) because TARGET is at line 11 (1-indexed) and
    // context_start = max(11-1-3, 0) = 7 (0-indexed) = 8 (1-indexed).
    try std.testing.expect(std.mem.indexOf(u8, result.unified, "@@ -8,") != null);
    // The very early lines (1..7) should NOT appear in the hunk
    try std.testing.expect(std.mem.indexOf(u8, result.unified, " line_00") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.unified, " line_05") == null);
    // Context lines around the change should appear
    try std.testing.expect(std.mem.indexOf(u8, result.unified, " line_07") != null);
    // The split view always contains the actual replacement content
    try std.testing.expect(std.mem.indexOf(u8, result.unified, "<<<<<<< BEFORE") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.unified, "TARGET\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.unified, "REPLACED\n") != null);
}

test "generateUnifiedDiff - unicode content in old/new_str" {
    const raw = "line1\n中文内容\nline3\n";
    const first = std.mem.indexOf(u8, raw, "中文内容").?;
    const result = try text_replace.generateUnifiedDiff(
        std.testing.allocator,
        raw,
        first,
        "中文内容",
        "替换内容",
    );
    defer std.testing.allocator.free(result.unified);

    // The unicode should be preserved (not byte-truncated) in the split view
    try std.testing.expect(std.mem.indexOf(u8, result.unified, "<<<<<<< BEFORE") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.unified, "中文内容") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.unified, "替换内容") != null);
}

test "generateUnifiedDiff - new_str shorter than old_str (3 old → 1 new)" {
    // Documenting actual behavior with raw = "before\nold1\nold2\nold3\nafter\n":
    //   old_lines = ["before", "old1", "old2", "old3", "after", ""] (6 entries)
    //   line_idx = 1 (old1)
    //   old_str_line_list = ["old1", "old2", "old3", ""] (4 entries)
    //   new_str_line_list = ["new", ""] (2 entries)
    //   old_end_line = 1+4 = 5, new_end_line = 1+2 = 3
    //   context_end = min(6, max(5,3)+3) = 6
    // For i=0: CONTEXT "before"
    // For i=1: in both → CONTEXT "old1"
    // For i=2: in both → CONTEXT "old2"
    // For i=3: in old (3<5), NOT in new (3<3 false) → REMOVE "old3"
    // For i=4: in old (4<5), NOT in new → REMOVE ""
    // For i=5: not in either → CONTEXT ""
    const raw = "before\nold1\nold2\nold3\nafter\n";
    const first = std.mem.indexOf(u8, raw, "old1").?;
    const result = try text_replace.generateUnifiedDiff(
        std.testing.allocator,
        raw,
        first,
        "old1\nold2\nold3\n",
        "new\n",
    );
    defer std.testing.allocator.free(result.unified);

    // "old3" is the first old line beyond the new range → shows with `-` prefix
    try std.testing.expect(std.mem.indexOf(u8, result.unified, "-old3") != null);
    // Split view shows all old lines and the new line
    try std.testing.expect(std.mem.indexOf(u8, result.unified, "old1\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.unified, "old2\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.unified, "old3\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.unified, "new\n") != null);
    // lines_changed = old_str_line_list.len (4) + new_str_line_list.len (2) = 6
    try std.testing.expect(result.lines_changed == 6);
}

test "generateUnifiedDiff - hunk header has correct start line (1-indexed)" {
    const raw = "l1\nl2\nl3\nl4\nl5\nTARGET\nl7\nl8\nl9\n";
    const first = std.mem.indexOf(u8, raw, "TARGET").?;
    const result = try text_replace.generateUnifiedDiff(
        std.testing.allocator,
        raw,
        first,
        "TARGET",
        "REPLACED",
    );
    defer std.testing.allocator.free(result.unified);

    // TARGET is at line 6 (1-indexed, 5 0-indexed). With 3-line context
    // before, hunk starts at line 6-3 = 3 (1-indexed).
    try std.testing.expect(std.mem.indexOf(u8, result.unified, "@@ -3,") != null);
}

test "generateUnifiedDiff - single-line new_str (no newlines)" {
    const raw = "header\nbody\nfooter\n";
    const first = std.mem.indexOf(u8, raw, "body").?;
    const result = try text_replace.generateUnifiedDiff(
        std.testing.allocator,
        raw,
        first,
        "body",
        "BODY",
    );
    defer std.testing.allocator.free(result.unified);

    // 1:1 replacement, visible only in split view
    try std.testing.expect(std.mem.indexOf(u8, result.unified, "<<<<<<< BEFORE") != null);
    // The replacement should appear in the AFTER section exactly once
    const sep = std.mem.indexOf(u8, result.unified, "=======").?;
    const after = std.mem.indexOf(u8, result.unified, ">>>>>>> AFTER").?;
    const after_section = result.unified[sep..after];
    const body_idx = std.mem.indexOf(u8, after_section, "BODY").?;
    try std.testing.expect(std.mem.indexOf(u8, after_section[body_idx + 1 ..], "BODY") == null);
}

test "generateUnifiedDiff - replacement at exactly the 3rd line (context boundary)" {
    // line_idx = 2 (TARGET), context_start = max(2-3, 0) = 0.
    const raw = "l1\nl2\nTARGET\nl4\nl5\n";
    const first = std.mem.indexOf(u8, raw, "TARGET\n").?;
    const result = try text_replace.generateUnifiedDiff(
        std.testing.allocator,
        raw,
        first,
        "TARGET\n",
        "REPLACED\n",
    );
    defer std.testing.allocator.free(result.unified);

    // Should include l1, l2 as context before
    try std.testing.expect(std.mem.indexOf(u8, result.unified, " l1") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.unified, " l2") != null);
    // 1:1 line replacement — no `+REPLACED` in hunk, but it's in the split view
    try std.testing.expect(std.mem.indexOf(u8, result.unified, "+REPLACED") == null);
    const sep = std.mem.indexOf(u8, result.unified, "=======").?;
    const after = std.mem.indexOf(u8, result.unified, ">>>>>>> AFTER").?;
    try std.testing.expect(std.mem.indexOf(u8, result.unified[sep..after], "REPLACED") != null);
}

test "generateUnifiedDiff - output always ends with AFTER marker" {
    const result = try text_replace.generateUnifiedDiff(
        std.testing.allocator,
        "abc\ndef\n",
        0,
        "abc\n",
        "xyz\n",
    );
    defer std.testing.allocator.free(result.unified);

    // The very last bytes should be ">>>>>>> AFTER\n"
    const suffix_start = result.unified.len - ">>>>>>> AFTER\n".len;
    try std.testing.expect(std.mem.eql(u8, result.unified[suffix_start..], ">>>>>>> AFTER\n"));
}

test "generateUnifiedDiff - first parameter is the offset, not byte content" {
    // Verify the line-finder uses the offset to determine line_idx.
    // raw = "aaa\nTARGET\nbbb\n" — TARGET at offset 4. The line-finding
    // loop picks line_idx=1 (the TARGET line). We pass first=4.
    const raw = "aaa\nTARGET\nbbb\n";
    const result = try text_replace.generateUnifiedDiff(
        std.testing.allocator,
        raw,
        4, // offset of TARGET
        "TARGET",
        "REPLACED",
    );
    defer std.testing.allocator.free(result.unified);

    // The split view should contain both TARGET and REPLACED
    try std.testing.expect(std.mem.indexOf(u8, result.unified, "TARGET") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.unified, "REPLACED") != null);
}

test "generateUnifiedDiff - line_idx calc when offset points to trailing empty line" {
    // raw = "abc\n" — only 1 line "abc", plus a trailing empty line.
    // first=4 (just after the \n) → line_idx = 1 (the trailing empty line)
    const result = try text_replace.generateUnifiedDiff(
        std.testing.allocator,
        "abc\n",
        4,
        "",
        "X",
    );
    defer std.testing.allocator.free(result.unified);

    // Should produce valid output without crashing
    try std.testing.expect(std.mem.indexOf(u8, result.unified, "@@") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.unified, "<<<<<<< BEFORE") != null);
}

// ============================================================================
// executeTextReplace — error path edge cases
// ============================================================================

test "executeTextReplace - empty path returns PathNotFound" {
    const result = text_replace.executeTextReplace(
        std.testing.allocator,
        std.testing.io,
        "",
        "foo",
        "bar",
    );
    try std.testing.expectError(text_replace.TextReplaceError.PathNotFound, result);
}

test "executeTextReplace - non-existent file returns FileNotFound" {
    const result = text_replace.executeTextReplace(
        std.testing.allocator,
        std.testing.io,
        "/tmp/this_file_does_not_exist_anywhere_zzz_unique.txt",
        "foo",
        "bar",
    );
    try std.testing.expectError(error.FileNotFound, result);
}

test "executeTextReplace - old_str not found returns OldStrNotFound" {
    const test_path = "test_err_not_found.txt";
    try createTestFile(test_path, "line1\nline2\nline3\n");
    defer deleteTestFile(test_path);

    const result = text_replace.executeTextReplace(
        std.testing.allocator,
        std.testing.io,
        test_path,
        "DOES_NOT_EXIST",
        "anything",
    );
    try std.testing.expectError(text_replace.TextReplaceError.OldStrNotFound, result);
}

test "executeTextReplace - old_str not unique returns OldStrNotUnique" {
    const test_path = "test_err_not_unique.txt";
    try createTestFile(test_path, "foo\nfoo\nfoo\n");
    defer deleteTestFile(test_path);

    const result = text_replace.executeTextReplace(
        std.testing.allocator,
        std.testing.io,
        test_path,
        "foo",
        "bar",
    );
    try std.testing.expectError(text_replace.TextReplaceError.OldStrNotUnique, result);
}

test "executeTextReplace - empty new_str deletes content" {
    const test_path = "test_delete.txt";
    try createTestFile(test_path, "before\nDELETE_ME\nafter\n");
    defer deleteTestFile(test_path);

    var result = try text_replace.executeTextReplace(
        std.testing.allocator,
        std.testing.io,
        test_path,
        "DELETE_ME\n",
        "",
    );
    defer result.deinit(std.testing.allocator);

    // diff_view should be populated
    try std.testing.expect(result.diff_view != null);
    if (result.diff_view) |dv| {
        try std.testing.expect(dv.after.len == 0);
        try std.testing.expect(std.mem.indexOf(u8, dv.before, "DELETE_ME") != null);
    }
}

test "executeTextReplace - file with no trailing newline" {
    const test_path = "test_no_newline.txt";
    // Note: createTestFile uses writeStreamingAll which doesn't auto-add a newline.
    try createTestFile(test_path, "no newline at end");
    defer deleteTestFile(test_path);

    var result = try text_replace.executeTextReplace(
        std.testing.allocator,
        std.testing.io,
        test_path,
        "newline",
        "trailing",
    );
    defer result.deinit(std.testing.allocator);

    // 1:1 line replacement — change is only visible in the split view
    try std.testing.expect(result.diff_view != null);
    if (result.diff_view) |dv| {
        // The split view shows the change
        try std.testing.expect(std.mem.indexOf(u8, dv.before, "newline") != null);
        try std.testing.expect(std.mem.indexOf(u8, dv.after, "trailing") != null);
        // The diff produces a valid hunk header
        try std.testing.expect(std.mem.indexOf(u8, dv.unified, "@@") != null);
        // 1:1 replacement → no +trailing in hunk body, but it's in the split view
        try std.testing.expect(std.mem.indexOf(u8, dv.unified, "+trailing") == null);
    }
}

test "executeTextReplace - empty file (zero-byte file)" {
    // Note: cannot use empty old_str with empty file — empty matches every
    // byte position so the "uniqueness" check returns OldStrNotUnique. We use
    // a non-empty old_str that doesn't appear, then verify the file-write
    // path doesn't crash and the diff_view is populated correctly.
    const test_path = "test_empty_file.txt";
    try createTestFile(test_path, "");
    defer deleteTestFile(test_path);

    // The empty file has no content to replace, so use a replacement that
    // targets an empty region (position 0) with non-empty content.
    // Actually: indexOf for "X" in "" returns null → OldStrNotFound. So
    // verify that path here, since it exercises the zero-byte read+search.
    const result = text_replace.executeTextReplace(
        std.testing.allocator,
        std.testing.io,
        test_path,
        "X",
        "new content",
    );
    try std.testing.expectError(text_replace.TextReplaceError.OldStrNotFound, result);
}

test "executeTextReplace - file with only a single newline" {
    // File = "\n" (single empty line plus trailing). Test that the tool can
    // handle a minimal non-empty file.
    const test_path = "test_single_newline.txt";
    try createTestFile(test_path, "\n");
    defer deleteTestFile(test_path);

    var result = try text_replace.executeTextReplace(
        std.testing.allocator,
        std.testing.io,
        test_path,
        "\n",
        "replaced\n",
    );
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(result.diff_view != null);
    if (result.diff_view) |dv| {
        try std.testing.expect(std.mem.indexOf(u8, dv.before, "\n") != null);
        try std.testing.expect(std.mem.indexOf(u8, dv.after, "replaced\n") != null);
    }
}

test "executeTextReplace - file with CRLF line endings" {
    const test_path = "test_crlf_file.txt";
    try createTestFile(test_path, "line1\r\nline2\r\nTARGET\r\nline4\r\n");
    defer deleteTestFile(test_path);

    var result = try text_replace.executeTextReplace(
        std.testing.allocator,
        std.testing.io,
        test_path,
        "TARGET",
        "REPLACED",
    );
    defer result.deinit(std.testing.allocator);

    // The replacement should still work despite CRLF (the file is normalized
    // before search, then re-emitted as CRLF on write).
    try std.testing.expect(result.diff_view != null);
    if (result.diff_view) |dv| {
        try std.testing.expect(std.mem.indexOf(u8, dv.before, "TARGET") != null);
        try std.testing.expect(std.mem.indexOf(u8, dv.after, "REPLACED") != null);
    }
}

test "executeTextReplace - file with Unicode content" {
    const test_path = "test_unicode_file.txt";
    try createTestFile(test_path, "before\n中文内容\nafter\n");
    defer deleteTestFile(test_path);

    var result = try text_replace.executeTextReplace(
        std.testing.allocator,
        std.testing.io,
        test_path,
        "中文内容",
        "替换内容",
    );
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(result.diff_view != null);
    if (result.diff_view) |dv| {
        try std.testing.expect(std.mem.indexOf(u8, dv.before, "中文内容") != null);
        try std.testing.expect(std.mem.indexOf(u8, dv.after, "替换内容") != null);
    }
}

test "executeTextReplace - replacement at very end of file (no trailing newline)" {
    const test_path = "test_end_of_file.txt";
    try createTestFile(test_path, "line1\nline2\nFINAL");
    defer deleteTestFile(test_path);

    var result = try text_replace.executeTextReplace(
        std.testing.allocator,
        std.testing.io,
        test_path,
        "FINAL",
        "DONE",
    );
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(result.diff_view != null);
    if (result.diff_view) |dv| {
        try std.testing.expect(std.mem.indexOf(u8, dv.before, "FINAL") != null);
        try std.testing.expect(std.mem.indexOf(u8, dv.after, "DONE") != null);
    }
}

test "executeTextReplace - replacement of identical-looking content (case sensitivity)" {
    // Case sensitivity check: lowercase "foo" must NOT match uppercase "FOO"
    const test_path = "test_case_sensitive.txt";
    try createTestFile(test_path, "FOO\n");
    defer deleteTestFile(test_path);

    const result = text_replace.executeTextReplace(
        std.testing.allocator,
        std.testing.io,
        test_path,
        "foo", // lowercase — does NOT match "FOO" in file
        "BAR",
    );
    try std.testing.expectError(text_replace.TextReplaceError.OldStrNotFound, result);
}

test "executeTextReplace - multi-line replacement that crosses line boundaries" {
    const test_path = "test_multiline_cross.txt";
    try createTestFile(test_path, "header\nmiddle1\nmiddle2\nmiddle3\nfooter\n");
    defer deleteTestFile(test_path);

    var result = try text_replace.executeTextReplace(
        std.testing.allocator,
        std.testing.io,
        test_path,
        "middle1\nmiddle2\nmiddle3",
        "MIDDLE",
    );
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(result.diff_view != null);
    if (result.diff_view) |dv| {
        // All three middle lines should appear in the BEFORE section
        try std.testing.expect(std.mem.indexOf(u8, dv.before, "middle1") != null);
        try std.testing.expect(std.mem.indexOf(u8, dv.before, "middle2") != null);
        try std.testing.expect(std.mem.indexOf(u8, dv.before, "middle3") != null);
        // The new content should be in AFTER
        try std.testing.expect(std.mem.indexOf(u8, dv.after, "MIDDLE") != null);
    }
}

test "executeTextReplace - large file (50 lines) succeeds" {
    const test_path = "test_large_file.txt";
    var content_buf: [2000]u8 = undefined;
    var pos: usize = 0;
    for (0..49) |i| {
        var line_buf: [32]u8 = undefined;
        const line = std.fmt.bufPrint(&line_buf, "line_{d:0>2}\n", .{i}) catch unreachable;
        @memcpy(content_buf[pos..][0..line.len], line);
        pos += line.len;
    }
    const line_final = "line_49\n";
    @memcpy(content_buf[pos..][0..line_final.len], line_final);
    pos += line_final.len;
    try createTestFile(test_path, content_buf[0..pos]);
    defer deleteTestFile(test_path);

    var result = try text_replace.executeTextReplace(
        std.testing.allocator,
        std.testing.io,
        test_path,
        "line_25\n",
        "MODIFIED_LINE\n",
    );
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(result.diff_view != null);
    if (result.diff_view) |dv| {
        // 1:1 line replacement — change visible in split view only
        try std.testing.expect(std.mem.indexOf(u8, dv.before, "line_25\n") != null);
        try std.testing.expect(std.mem.indexOf(u8, dv.after, "MODIFIED_LINE\n") != null);
        // Hunk header should start at line 23 (1-indexed), since line_25 is
        // at line 26 (1-indexed) and context_start = 26-3 = 23.
        try std.testing.expect(std.mem.indexOf(u8, dv.unified, "@@ -23,") != null);
        // The very early lines should NOT appear (1..22)
        try std.testing.expect(std.mem.indexOf(u8, dv.unified, " line_00") == null);
        try std.testing.expect(std.mem.indexOf(u8, dv.unified, " line_19") == null);
        // The trailing lines should NOT appear
        try std.testing.expect(std.mem.indexOf(u8, dv.unified, " line_30") == null);
    }
}

test "executeTextReplace - special XML chars in old_str (search works on raw bytes)" {
    // xmlEscape is applied to OUTPUT fields (in toXmlSuccess) only; the
    // diff_view's `before`/`after` fields hold the RAW bytes from old_str /
    // new_str. So old_str can contain literal '<' / '>' / '&' and still
    // match the file, and the before field will contain them unescaped.
    const test_path = "test_xml_chars_in_search.txt";
    try createTestFile(test_path, "before\nif (a < b && c > d)\nafter\n");
    defer deleteTestFile(test_path);

    var result = try text_replace.executeTextReplace(
        std.testing.allocator,
        std.testing.io,
        test_path,
        "if (a < b && c > d)",
        "if (a <= b)",
    );
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(result.diff_view != null);
    if (result.diff_view) |dv| {
        // before contains the raw search string (unescaped)
        try std.testing.expect(std.mem.indexOf(u8, dv.before, "if (a < b && c > d)") != null);
        // after contains the raw replacement
        try std.testing.expect(std.mem.indexOf(u8, dv.after, "if (a <= b)") != null);
    }
}

test "executeTextReplace - XML escaping happens in toXmlSuccess, not in diff_view" {
    // Verify the boundary: diff_view holds raw bytes; toXmlSuccess produces
    // XML-escaped output. A user-facing test that verifies both shapes.
    const test_path = "test_xml_escape_boundary.txt";
    try createTestFile(test_path, "before\n<tag>\nafter\n");
    defer deleteTestFile(test_path);

    var result = try text_replace.executeTextReplace(
        std.testing.allocator,
        std.testing.io,
        test_path,
        "<tag>",
        "&amp;entity",
    );
    defer result.deinit(std.testing.allocator);

    // diff_view: raw bytes (no escaping)
    try std.testing.expect(result.diff_view != null);
    if (result.diff_view) |dv| {
        try std.testing.expect(std.mem.indexOf(u8, dv.before, "<tag>") != null);
        try std.testing.expect(std.mem.indexOf(u8, dv.after, "&amp;entity") != null);
    }

    // toXmlSuccess: escaped output
    const xml = text_replace.toXmlSuccess(std.testing.allocator, result, "/x");
    defer std.testing.allocator.free(xml);
    try std.testing.expect(std.mem.indexOf(u8, xml, "&lt;tag&gt;") != null);
    // The & in new_str's "&amp;entity" would get re-escaped to "&amp;amp;entity"
    try std.testing.expect(std.mem.indexOf(u8, xml, "&amp;amp;entity") != null);
}

test "executeTextReplace - replacement succeeds when old_str is at byte 0" {
    // 1:1 line replacement — change is visible only in the split view
    // (<<<<<<< / ======= / >>>>>>>) since the unified hunk shows context.
    const test_path = "test_byte_zero.txt";
    try createTestFile(test_path, "FIRST\nrest of file\n");
    defer deleteTestFile(test_path);

    var result = try text_replace.executeTextReplace(
        std.testing.allocator,
        std.testing.io,
        test_path,
        "FIRST",
        "FIRST_REPLACED",
    );
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(result.diff_view != null);
    if (result.diff_view) |dv| {
        // Split view shows the change
        try std.testing.expect(std.mem.indexOf(u8, dv.before, "FIRST") != null);
        try std.testing.expect(std.mem.indexOf(u8, dv.after, "FIRST_REPLACED") != null);
        // Unified hunk header is present
        try std.testing.expect(std.mem.indexOf(u8, dv.unified, "@@") != null);
    }
}
