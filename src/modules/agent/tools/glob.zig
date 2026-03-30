const std = @import("std");
const schemas = @import("schemas.zig");
const AgentTool = schemas.AgentTool;

/// Filter for file types when searching.
pub const GlobTypeFilter = enum {
    file,
    directory,
    symlink,
    socket,
    pipe,
    executable,
    empty,

    /// Convert to fd CLI argument
    pub fn toFdArg(self: GlobTypeFilter) []const u8 {
        return switch (self) {
            .file => "f",
            .directory => "d",
            .symlink => "l",
            .socket => "s",
            .pipe => "p",
            .executable => "x",
            .empty => "e",
        };
    }
};

/// Input for the glob tool.
pub const GlobInput = struct {
    /// Glob pattern to match (e.g., "*.zig", "**/*.txt")
    pattern: []const u8,
    /// Directory path to search in
    path: []const u8,
    /// Whether to include hidden files (starts with .)
    include_hidden: bool = false,
    /// Maximum number of results to return
    max_results: ?usize = null,
    /// Filter by file type
    type_filter: ?GlobTypeFilter = null,
    /// Skip the first N results (for pagination). Default: 0.
    offset: ?usize = null,
};

/// A single glob match result.
pub const GlobMatch = struct {
    /// The matched file/directory path
    path: []const u8,
};

/// Result from executing a glob search.
pub const GlobResult = struct {
    matches: std.ArrayList(GlobMatch),

    /// Free all allocated memory.
    pub fn deinit(self: *GlobResult, allocator: std.mem.Allocator) void {
        for (self.matches.items) |m| {
            allocator.free(m.path);
        }
        self.matches.deinit(allocator);
    }
};

/// Execute a glob search using the `fd` CLI tool.
///
/// Uses `/usr/sbin/fd` with the following options:
/// - `--glob` for glob patterns
/// - `-H` or `--no-hidden` for hidden files
/// - `-t <type>` for type filtering
/// - `--max-results` for limiting results
///
/// Note: `offset` is applied after fetching results, since fd doesn't support offset natively.
pub fn executeGlob(allocator: std.mem.Allocator, input: GlobInput) !GlobResult {
    const offset = input.offset orelse 0;
    const max_results = (input.max_results orelse 100) + offset; // Fetch extra if offset is set

    // Build argument list for fd
    var args = std.ArrayListUnmanaged([]const u8){};
    errdefer args.deinit(allocator);

    // fd path
    try args.append(allocator, "/usr/sbin/fd");

    // Use glob mode for pattern matching
    try args.append(allocator, "--glob");

    // The pattern
    try args.append(allocator, input.pattern);

    // Path to search
    try args.append(allocator, input.path);

    // Hidden files option
    if (input.include_hidden) {
        try args.append(allocator, "--hidden");
    } else {
        try args.append(allocator, "--no-hidden");
    }

    // Type filter
    if (input.type_filter) |filter| {
        try args.append(allocator, "--type");
        try args.append(allocator, filter.toFdArg());
    }

    // Limit results (include offset if set)
    try args.append(allocator, "--max-results");
    try args.append(allocator, try std.fmt.allocPrint(allocator, "{d}", .{max_results}));

    // Run fd
    const result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = args.items,
        .max_output_bytes = 10 * 1024 * 1024, // 10MB max
    });

    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    // Parse results using ArrayListUnmanaged
    var matches = std.ArrayListUnmanaged(GlobMatch){};
    errdefer {
        for (matches.items) |m| {
            allocator.free(m.path);
        }
        matches.deinit(allocator);
    }

    // Split stdout by newlines
    var line_start: usize = 0;
    while (line_start < result.stdout.len) {
        const line_end = std.mem.indexOfScalarPos(u8, result.stdout, line_start, '\n') orelse result.stdout.len;
        if (line_end > line_start) {
            const line = result.stdout[line_start..line_end];
            if (line.len > 0) {
                try matches.append(allocator, .{ .path = undefined }); // placeholder
                // Store the path directly (will be copied below)
                const owned_path = try allocator.dupe(u8, line);
                matches.items[matches.items.len - 1].path = owned_path;
            }
        }
        line_start = line_end + 1;
    }

    // Apply offset: skip first N results
    if (offset > 0 and offset < matches.items.len) {
        const new_len = matches.items.len - offset;
        // Free skipped items
        for (offset..matches.items.len) |i| {
            allocator.free(matches.items[i].path);
        }
        // Shift remaining items to front
        for (0..new_len) |i| {
            matches.items[i] = matches.items[offset + i];
        }
        matches.shrinkRetainingCapacity(new_len);
    } else if (offset >= matches.items.len) {
        // All results were skipped
        for (matches.items) |*m| {
            allocator.free(m.path);
        }
        matches.shrinkRetainingCapacity(0);
    }

    // Trim to max_results if we have more than needed
    if (matches.items.len > (input.max_results orelse 100)) {
        for (matches.items[(input.max_results orelse 100)..]) |*m| {
            allocator.free(m.path);
        }
        matches.shrinkRetainingCapacity(input.max_results orelse 100);
    }

    return GlobResult{ .matches = matches };
}

/// Convert GlobResult to XML string format with <f> tags.
/// Returns a warning message if no matches are found.
pub fn globResultToString(allocator: std.mem.Allocator, result: GlobResult) ![]const u8 {
    var output = std.ArrayList(u8).empty;
    errdefer output.deinit(allocator);

    for (result.matches.items) |m| {
        const match_xml = try std.fmt.allocPrint(allocator,
            \\<f>{s}</f>
        , .{m.path});
        try output.appendSlice(allocator, match_xml);
        allocator.free(match_xml);
    }

    // Return a warning if no matches found
    if (output.items.len == 0) {
        return try std.fmt.allocPrint(allocator, "<warning>No files found matching the glob pattern.</warning>", .{});
    }

    return try output.toOwnedSlice(allocator);
}

/// OpenAI-compatible glob tool definition.
pub const globTool = AgentTool{
    .type = "function",
    .function = .{
        .name = "glob",
        .description =
        \\Find files matching a glob pattern using the fd CLI.
        \\Returns: <f>path</f> for each match.
        \\
        \\- Use this to find files by name patterns (e.g., "*.zig", "**/*.md")
        \\- Complements the 'search' tool which searches file contents
        \\- Supports hidden file filtering and file type filtering
        ,
        .parameters = .{
            .type = "object",
            .properties = &.{
                .{
                    .name = "pattern",
                    .type = "string",
                    .description = "Glob pattern to match (e.g., '*.zig', '**/*.txt', 'src/**/*').",
                },
                .{
                    .name = "path",
                    .type = "string",
                    .description = "Directory path to search in.",
                },
                .{
                    .name = "include_hidden",
                    .type = "boolean",
                    .description = "Whether to include hidden files (starting with '.'). Default: false.",
                },
                .{
                    .name = "max_results",
                    .type = "number",
                    .description = "Maximum number of results to return. Default: 100.",
                },
                .{
                    .name = "type_filter",
                    .type = "string",
                    .description = "Filter by file type: 'file', 'directory', 'symlink', 'socket', 'pipe', 'executable', 'empty'. Default: all types.",
                },
                .{
                    .name = "offset",
                    .type = "number",
                    .description = "Skip the first N results for pagination. Use with max_results to page through large result sets. Default: 0.",
                },
            },
            .required = &.{ "pattern", "path" },
        },
    },
};

