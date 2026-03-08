const std = @import("std");
const ToolProperty = @import("models.zig").ToolProperty;
const ToolParameters = @import("models.zig").ToolParameters;
const AgentToolFunction = @import("models.zig").AgentToolFunction;
const AgentTool = @import("models.zig").AgentTool;

pub const WriteFileInput = struct {
    path: []const u8,
    content: []const u8,
    start_line: ?usize = null,
    end_line: ?usize = null,
};

pub const WriteFileResult = struct {
    path: []u8,
    bytes_written: usize,
    lines_written: usize,
    total_lines: usize,

    pub fn deinit(self: WriteFileResult, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
    }
};

pub const WriteFileOptions = struct {
    content: []const u8,
    start_line: ?usize = null,
    end_line: ?usize = null,
};

pub fn write_file(
    allocator: std.mem.Allocator,
    path: []const u8,
    opts: WriteFileOptions,
) !WriteFileResult {
    // If start_line and end_line are provided, do line replacement
    if (opts.start_line != null and opts.end_line != null) {
        return try write_file_replace_lines(allocator, path, opts);
    }
    
    // Otherwise, overwrite entire file
    return try write_file_overwrite(allocator, path, opts);
}

fn write_file_overwrite(
    allocator: std.mem.Allocator,
    path: []const u8,
    opts: WriteFileOptions,
) !WriteFileResult {
    const file = std.fs.cwd().createFile(path, .{}) catch |err| {
        if (err == error.FileNotFound) {
            // Try to create parent directories
            var path_copy = try allocator.dupe(u8, path);
            defer allocator.free(path_copy);
            
            // Find the directory part
            const last_slash = std.mem.lastIndexOf(u8, path_copy, "/");
            if (last_slash) |idx| {
                const dir_path = path_copy[0..idx];
                try std.fs.cwd().makeDir(dir_path);
                const file = try std.fs.cwd().createFile(path, .{});
                defer file.close();
                
                try file.writeAll(opts.content);
                
                const lines_written = countLines(opts.content);
                return WriteFileResult{
                    .path = try allocator.dupe(u8, path),
                    .bytes_written = opts.content.len,
                    .lines_written = lines_written,
                    .total_lines = lines_written,
                };
            }
        }
        return err;
    };
    defer file.close();

    try file.writeAll(opts.content);

    const lines_written = countLines(opts.content);

    return WriteFileResult{
        .path = try allocator.dupe(u8, path),
        .bytes_written = opts.content.len,
        .lines_written = lines_written,
        .total_lines = lines_written,
    };
}

fn write_file_replace_lines(
    allocator: std.mem.Allocator,
    path: []const u8,
    opts: WriteFileOptions,
) !WriteFileResult {
    const start_line = opts.start_line.?;
    const end_line = opts.end_line.?;
    
    if (start_line > end_line) {
        return error.InvalidRange;
    }
    
    // Read existing file
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();
    
    const raw = try file.readToEndAlloc(allocator, std.math.maxInt(usize));
    defer allocator.free(raw);
    
    // Collect all lines (including newline characters)
    var lines = std.ArrayList([]u8).empty;
    errdefer {
        for (lines.items) |line| allocator.free(line);
        lines.deinit(allocator);
    }
    
    var start_idx: usize = 0;
    var i: usize = 0;
    while (i < raw.len) : (i += 1) {
        if (raw[i] == '\n') {
            // Include the newline character
            const line_content = raw[start_idx..(i + 1)];
            try lines.append(allocator, try allocator.dupe(u8, line_content));
            start_idx = i + 1;
        }
    }
    // Handle last line (may or may not have newline)
    if (start_idx < raw.len) {
        const line_content = raw[start_idx..raw.len];
        try lines.append(allocator, try allocator.dupe(u8, line_content));
    }
    
    // Validate line range
    if (start_line >= lines.items.len or end_line >= lines.items.len) {
        return error.LineRangeOutOfBounds;
    }
    
    // Build new content
    var new_content = std.ArrayList(u8).empty;
    defer new_content.deinit(allocator);
    
    // Add lines before the range
    for (0..start_line) |j| {
        try new_content.appendSlice(allocator, lines.items[j]);
    }
    
    // Add replacement content (ensure it ends with newline if original did)
    try new_content.appendSlice(allocator, opts.content);
    // If replacement doesn't end with newline but original last replaced line did, add newline
    const last_replaced_has_newline = lines.items[end_line].len > 0 and lines.items[end_line][lines.items[end_line].len - 1] == '\n';
    const replacement_has_newline = opts.content.len > 0 and opts.content[opts.content.len - 1] == '\n';
    if (last_replaced_has_newline and !replacement_has_newline) {
        try new_content.appendSlice(allocator, "\n");
    }
    
    // Add lines after the range
    for ((end_line + 1)..lines.items.len) |j| {
        try new_content.appendSlice(allocator, lines.items[j]);
    }
    
    // Free the lines we duplicated
    for (lines.items) |line| allocator.free(line);
    lines.deinit(allocator);
    
    // Write back to file
    const file_write = try std.fs.cwd().createFile(path, .{});
    defer file_write.close();
    
    try file_write.writeAll(new_content.items);
    
    // Count lines in result
    const total_lines = countLines(new_content.items);
    
    return WriteFileResult{
        .path = try allocator.dupe(u8, path),
        .bytes_written = new_content.items.len,
        .lines_written = 1,
        .total_lines = total_lines,
    };
}

fn countLines(content: []const u8) usize {
    var count: usize = 0;
    for (content) |c| {
        if (c == '\n') count += 1;
    }
    if (content.len > 0 and content[content.len - 1] != '\n') {
        count += 1;
    }
    return count;
}

pub fn writeFileToString(allocator: std.mem.Allocator, result: WriteFileResult) ![]const u8 {
    return try std.fmt.allocPrint(allocator,
        \\<path>{s}</path>
        \\<bytes_written>{d}</bytes_written>
        \\<lines_written>{d}</lines_written>
        \\<total_lines>{d}</total_lines>
    , .{
        result.path,
        result.bytes_written,
        result.lines_written,
        result.total_lines,
    });
}

pub const writeFileTool = AgentTool{
    .type = "function",
    .function = .{
        .name = "write_file",
        .description =
        \\Write content to a file.
        \\
        \\- Omit start_line and end_line to overwrite the entire file.
        \\- Use start_line + end_line to replace a specific block.
        \\- Always read_file first to find the correct line range.
        ,
        .parameters = .{
            .type = "object",
            .properties = &.{
                .{
                    .name = "path",
                    .type = "string",
                    .description = "Absolute or relative path to the file.",
                },
                .{
                    .name = "content",
                    .type = "string",
                    .description = "Content to write.",
                },
                .{
                    .name = "start_line",
                    .type = "number",
                    .description = "First line to replace (0-indexed). Default: overwrite whole file.",
                },
                .{
                    .name = "end_line",
                    .type = "number",
                    .description = "Last line to replace (0-indexed, inclusive).",
                },
            },
            .required = &.{ "path", "content" },
        },
    },
};

test {
    _ = @import("write_file_test.zig");
}
