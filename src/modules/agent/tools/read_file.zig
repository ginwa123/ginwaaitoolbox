const std = @import("std");
const posix = std.posix;
const schemas = @import("schemas.zig");
const BashInput = schemas.BashInput;
const ToolProperty = schemas.ToolProperty;
const ToolParameters = schemas.ToolParameters;
const AgentToolFunction = schemas.AgentToolFunction;
const AgentTool = schemas.AgentTool;
const crypto = @import("std").crypto;
const Sha256 = crypto.hash.sha2.Sha256;

pub const ReadFileResult = struct {
    content: []u8,
    sha256: []u8,
    total_lines: usize,
    start_line: usize,
    end_line: usize,

    pub fn deinit(self: ReadFileResult, allocator: std.mem.Allocator) void {
        allocator.free(self.content);
        allocator.free(self.sha256);
    }
};

pub const ReadFileOptions = struct {
    offset: ?usize = null, // line number to start from (0-indexed)
    limit: ?usize = null, // max number of lines to return
    show_line_numbers: ?bool = null, // whether to prefix each line with line number
    hash_only: ?bool = null, // NEW: if true, only compute hash without reading content
};

pub fn read_file(
    allocator: std.mem.Allocator,
    path: []const u8,
    opts: ReadFileOptions,
) !ReadFileResult {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();

    // If hash_only is true, compute hash from file without loading full content
    if (opts.hash_only orelse false) {
        var hash: [32]u8 = undefined;

        // Read file in chunks to hash without full memory allocation
        var chunk_buf: [8192]u8 = undefined;
        var hasher = Sha256.init(.{});

        while (true) {
            const bytes_read = try file.read(&chunk_buf);
            if (bytes_read == 0) break;
            hasher.update(chunk_buf[0..bytes_read]);
        }

        hasher.final(&hash);
        const sha256_hex = try std.fmt.allocPrint(allocator, "{s}", .{std.fmt.bytesToHex(hash, .lower)});

        return ReadFileResult{
            .content = &.{},
            .sha256 = sha256_hex,
            .total_lines = 0,
            .start_line = 0,
            .end_line = 0,
        };
    }

    const raw = try file.readToEndAlloc(allocator, std.math.maxInt(usize));
    defer allocator.free(raw);

    // Compute SHA256 hash of the raw content
    var hash: [32]u8 = undefined;
    Sha256.hash(raw, &hash, .{});

    // Convert hash to hex string
    const sha256_hex = try std.fmt.allocPrint(allocator, "{s}", .{std.fmt.bytesToHex(hash, .lower)});

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

    const show_line_numbers = opts.show_line_numbers orelse false;

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
                if (show_line_numbers) {
                    // format: "    1\t" (4-digit padded line number + tab)
                    const line_num_len = std.fmt.count("{d:>4}\t", .{line_idx + 1});
                    const num_buf = try allocator.alloc(u8, line_num_len);
                    defer allocator.free(num_buf);
                    const num_str = std.fmt.bufPrint(num_buf, "{d:>4}\t", .{line_idx + 1}) catch unreachable;
                    try out.appendSlice(allocator, num_str);
                }
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
        .sha256 = sha256_hex,
        .total_lines = total_lines,
        .start_line = offset,
        .end_line = end_line,
    };
}

pub fn readFileToString(allocator: std.mem.Allocator, result: ReadFileResult) ![]const u8 {
    return try std.fmt.allocPrint(allocator,
        \\<content>{s}</content>
        \\<sha256>{s}</sha256>
        \\<total_lines>{d}</total_lines>
        \\<start_line>{d}</start_line>
        \\<end_line>{d}</end_line>
    , .{
        result.content,
        result.sha256,
        result.total_lines,
        result.start_line,
        result.end_line,
    });
}

pub const readFileTool = AgentTool{
    .type = "function",
    .function = .{
        .name = "read_file",
        .description =
        \\Read a file by path. Returns content, sha256, total_lines, start_line, end_line.
        \\
        \\- Omit offset and limit to read the whole file.
        \\- Use offset + limit to paginate large files (recommended page: 500 lines).
        \\- Never guess offsets — check total_lines from a prior call first.
        \\- Set show_line_numbers to true to prefix each line with its line number.
        \\- Set hash_only to true to only compute hash without reading full content.
        \\- Returns SHA256 hash of file content - save this for text_replace to prevent blind edits.
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
                .{
                    .name = "show_line_numbers",
                    .type = "boolean",
                    .description = "Whether to prefix each line with its line number, line number start from 1. Default: false.",
                },
                .{
                    .name = "hash_only",
                    .type = "boolean",
                    .description = "If true, only compute and return SHA256 hash without reading file content. Default: false.",
                },
            },
            .required = &.{"path"},
        },
    },
};

