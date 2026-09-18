const std = @import("std");
const posix = std.posix;
const schemas = @import("schemas.zig");
const BashInput = schemas.BashInput;
const ToolProperty = schemas.ToolProperty;
const ToolParameters = schemas.ToolParameters;
const AgentToolFunction = schemas.AgentToolFunction;
const AgentTool = schemas.AgentTool;

pub const ReadFileResult = struct {
    content: []u8,
    total_lines: usize,
    start_line: usize,
    end_line: usize,

    pub fn deinit(self: ReadFileResult, allocator: std.mem.Allocator) void {
        allocator.free(self.content);
    }
};

pub const ReadFileOptions = struct {
    offset: ?usize = null, // line number to start from (0-indexed)
    limit: ?usize = null, // max number of lines to return
};

pub fn readFile(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    opts: ReadFileOptions,
) !ReadFileResult {
    const file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer std.Io.File.close(file, io);

    const raw = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, std.Io.Limit.limited(std.math.maxInt(usize)));
    defer allocator.free(raw);

    // count lines
    var total_lines: usize = 0;
    for (raw) |c| {
        if (c == '\n') total_lines += 1;
    }
    // handle no trailing newline
    if (raw.len > 0 and raw[raw.len - 1] != '\n') total_lines += 1;

    const offset = opts.offset orelse 0;
    const limit = opts.limit orelse total_lines;

    if (offset >= total_lines and total_lines > 0) {
        return error.OffsetOutOfRange;
    }

    // collect lines in [offset, offset+limit)
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);

    var line_idx: usize = 0;
    var line_start: usize = 0;
    var captured: usize = 0;
    var end_line: usize = offset;

    for (raw, 0..) |c, i| {
        if (c == '\n' or i == raw.len - 1) {
            const line_end = if (c == '\n') i + 1 else i + 1;
            if (line_idx >= offset and captured < limit) {
                // Raw content only — no per-line number prefix. Callers derive
                // absolute 1-indexed line numbers as start_line + 1 + index.
                try out.appendSlice(allocator, raw[line_start..line_end]);
                captured += 1;
                end_line = line_idx;
            }
            line_idx += 1;
            line_start = line_end;
            if (captured >= limit) break;
        }
    }

    return ReadFileResult{
        .content = try out.toOwnedSlice(allocator),
        .total_lines = total_lines,
        .start_line = offset,
        .end_line = end_line,
    };
}

/// JSON payload for a successful read: mirrors the old `<path>` /
/// `<content>` / `<total_lines>` / `<start_line>` / `<end_line>` tags 1:1.
/// `content` is raw file text — `<`/`&` need no escaping in JSON.
pub const ReadFileJSON = struct {
    path: []const u8,
    content: []const u8,
    total_lines: usize,
    start_line: usize,
    end_line: usize,
};

pub fn toJSONSuccess(allocator: std.mem.Allocator, result: ReadFileResult, path: []const u8) ![]u8 {
    return try std.json.Stringify.valueAlloc(allocator, ReadFileJSON{
        .path = path,
        .content = result.content,
        .total_lines = result.total_lines,
        .start_line = result.start_line,
        .end_line = result.end_line,
    }, .{});
}

pub const read_file_tool_system_prompt =
    \\## Read File Tool — Behavior
    \\Use `read_file` to read file contents by absolute path.
    \\- For large files, use `offset` + `limit` to paginate (500 lines per page). Check `total_lines` first.
    \\- Content is raw (no per-line number prefixes). Derive absolute 1-indexed line numbers as `start_line + 1 + index`.
    \\- Never guess offsets — read sequentially.
    \\
;

pub const read_file_tool = AgentTool{
    .type = "function",
    .function = .{
        .name = "read_file",
        .description =
        \\Read a file by path. Returns content, total_lines, start_line, end_line.
        \\
        \\- Omit offset and limit to read the whole file.
        \\- Use offset + limit to paginate large files (recommended page: 500 lines).
        \\- Never guess offsets — check total_lines from a prior call first.
        \\- Content is raw without line-number prefixes; absolute 1-indexed line numbers are start_line + 1 + index.
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
                    .name = "offset",
                    .type = "number",
                    .description = "Line to start from (0-indexed). Default: 0.",
                },
                .{
                    .name = "limit",
                    .type = "number",
                    .description = "Max lines to return. Default: entire file.",
                },
            },
            .required = &.{"path"},
        },
        .system_prompt = read_file_tool_system_prompt,
    },
};

// ─── Raw-content contract tests ─────────────────────────────────────────
// Content is raw (no per-line number prefixes). Positioning comes from
// start_line/end_line/total_lines; absolute 1-indexed line numbers are
// start_line + 1 + index.

test "read_file returns raw content without line-number prefixes" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "raw.txt", .data = "alpha\nbeta\ngamma\n" });
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(std.testing.io, &path_buf);
    const abs = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..n], "raw.txt" });
    defer std.testing.allocator.free(abs);

    var result = try readFile(std.testing.allocator, std.testing.io, abs, .{});
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("alpha\nbeta\ngamma\n", result.content);
    try std.testing.expectEqual(@as(usize, 3), result.total_lines);
    try std.testing.expectEqual(@as(usize, 0), result.start_line);
    try std.testing.expectEqual(@as(usize, 2), result.end_line);
}

test "read_file paginated slice is raw with correct start/end lines" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "page.txt", .data = "l1\nl2\nl3\nl4\n" });
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(std.testing.io, &path_buf);
    const abs = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..n], "page.txt" });
    defer std.testing.allocator.free(abs);

    var result = try readFile(std.testing.allocator, std.testing.io, abs, .{ .offset = 1, .limit = 2 });
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("l2\nl3\n", result.content);
    try std.testing.expectEqual(@as(usize, 4), result.total_lines);
    try std.testing.expectEqual(@as(usize, 1), result.start_line);
    try std.testing.expectEqual(@as(usize, 2), result.end_line);
}

test "toJSONSuccess payload carries raw content and line range" {
    const content = try std.testing.allocator.dupe(u8, "foo\nbar\n");
    const result = ReadFileResult{ .content = content, .total_lines = 2, .start_line = 0, .end_line = 1 };
    defer result.deinit(std.testing.allocator);

    const payload = try toJSONSuccess(std.testing.allocator, result, "/x.txt");
    defer std.testing.allocator.free(payload);

    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, payload, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;
    try std.testing.expectEqualStrings("/x.txt", obj.get("path").?.string);
    try std.testing.expectEqualStrings("foo\nbar\n", obj.get("content").?.string);
    try std.testing.expectEqual(@as(i64, 2), obj.get("total_lines").?.integer);
    try std.testing.expectEqual(@as(i64, 0), obj.get("start_line").?.integer);
    try std.testing.expectEqual(@as(i64, 1), obj.get("end_line").?.integer);
}
