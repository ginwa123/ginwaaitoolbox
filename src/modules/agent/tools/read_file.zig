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
                // format: "    1\t" (4-digit padded line number + tab)
                const line_num_len = std.fmt.count("{d:>4}\t", .{line_idx + 1});
                const num_buf = try allocator.alloc(u8, line_num_len);
                defer allocator.free(num_buf);
                const num_str = std.fmt.bufPrint(num_buf, "{d:>4}\t", .{line_idx + 1}) catch unreachable;
                try out.appendSlice(allocator, num_str);
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

pub fn to_xml(allocator: std.mem.Allocator, result: ReadFileResult, path: []const u8) ![]const u8 {
    return try std.fmt.allocPrint(allocator,
        \\<path>{s}</path>
        \\<content>{s}</content>
        \\<total_lines>{d}</total_lines>
        \\<start_line>{d}</start_line>
        \\<end_line>{d}</end_line>
    , .{
        path,
        result.content,
        result.total_lines,
        result.start_line,
        result.end_line,
    });
}

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
        \\- Each line is prefixed with its line number (1-indexed).
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
    },
};
