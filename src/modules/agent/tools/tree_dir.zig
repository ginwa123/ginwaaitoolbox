const std = @import("std");
const schemas = @import("schemas.zig");
const AgentTool = schemas.AgentTool;

/// Hidden file mode
pub const HiddenMode = enum {
    exclude,
    include,
    only,
};

/// Input for the tree_dir tool
pub const TreeDirInput = struct {
    /// Root path to start traversing from
    root_path: []const u8,

    /// === Depth control ===
    /// Minimum depth to include (0 = root)
    min_depth: usize = 0,
    /// Maximum depth to traverse (null = no limit)
    max_depth: ?usize = 4,

    /// === Traversal limits (safety) ===
    /// Maximum number of filesystem nodes visited
    max_nodes_visited: usize = 10_000,

    /// Optional timeout for traversal (milliseconds)
    timeout_ms: ?u64 = null,

    /// === Output limits ===
    /// Maximum number of entries returned
    max_results: ?usize = null,

    /// === Filtering ===
    hidden: HiddenMode = .exclude,
    include_files: bool = true,
    include_dirs: bool = true,

    /// Glob patterns to ignore (e.g. "node_modules", "*.log")
    ignore_globs: ?[]const []const u8 = null,

    /// Optional allowlist
    include_globs: ?[]const []const u8 = null,

    /// === Symlink handling ===
    follow_symlinks: bool = false,
    detect_cycles: bool = true,

    /// === Performance ===
    /// Whether to fetch metadata (stat calls = slower)
    include_metadata: bool = false,
};

/// A single entry in the tree
pub const TreeDirEntry = struct {
    name: []const u8,
    path: []const u8,
    is_dir: bool,
    depth: usize,
};

/// Result from tree_dir execution
pub const TreeDirResult = struct {
    entries: std.ArrayListUnmanaged(TreeDirEntry),
    nodes_visited: usize,
    truncated: bool,

    pub fn deinit(self: *TreeDirResult, allocator: std.mem.Allocator) void {
        for (self.entries.items) |*entry| {
            allocator.free(entry.name);
            allocator.free(entry.path);
        }
        self.entries.deinit(allocator);
    }
};

/// Parse tree_dir input from JSON string.
pub fn parseTreeDirInput(allocator: std.mem.Allocator, json_str: []const u8) !TreeDirInput {
    const parsed = try std.json.parseFromSlice(TreeDirInput, allocator, json_str, .{
        .allocate = .alloc_always,
    });
    defer parsed.deinit();
    return parsed.value;
}

/// Execute tree_dir traversal using `fd` CLI tool.
pub fn execute_tree_dir(allocator: std.mem.Allocator, input: TreeDirInput) !TreeDirResult {
    // Build argument list for fd
    var args = std.ArrayListUnmanaged([]const u8){};
    errdefer args.deinit(allocator);

    // fd path
    try args.append(allocator, "/usr/sbin/fd");

    // Use type 'all' to include both files and directories
    try args.append(allocator, "--type");
    try args.append(allocator, "all");

    // Max depth
    if (input.max_depth) |depth| {
        try args.append(allocator, "-d");
        try args.append(allocator, try std.fmt.allocPrint(allocator, "{d}", .{depth}));
    }

    // Hidden files option
    switch (input.hidden) {
        .exclude => try args.append(allocator, "--no-hidden"),
        .include => try args.append(allocator, "--hidden"),
        .only => {
            // fd doesn't have --only-hidden, so we use --hidden and filter results
            try args.append(allocator, "--hidden");
        },
    }

    // Follow symlinks
    if (input.follow_symlinks) {
        try args.append(allocator, "-L");
    }

    // Ignore globs
    if (input.ignore_globs) |globs| {
        for (globs) |glob| {
            try args.append(allocator, "--ignore-file");
            try args.append(allocator, glob);
        }
    }

    // Max results
    if (input.max_results) |max| {
        try args.append(allocator, "--max-results");
        try args.append(allocator, try std.fmt.allocPrint(allocator, "{d}", .{max}));
    }

    // Path to search
    try args.append(allocator, ".");
    try args.append(allocator, input.root_path);

    // Run fd
    const result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = args.items,
        .max_output_bytes = 10 * 1024 * 1024, // 10MB max
    });

    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    // Parse results
    var entries = std.ArrayListUnmanaged(TreeDirEntry){};
    errdefer {
        for (entries.items) |entry| {
            allocator.free(entry.name);
            allocator.free(entry.path);
        }
        entries.deinit(allocator);
    }

    // Split stdout by newlines
    var line_start: usize = 0;
    var nodes_visited: usize = 0;
    while (line_start < result.stdout.len and nodes_visited < input.max_nodes_visited) {
        const line_end = std.mem.indexOfScalarPos(u8, result.stdout, line_start, '\n') orelse result.stdout.len;
        if (line_end > line_start) {
            const line = result.stdout[line_start..line_end];
            if (line.len > 0) {
                // Count depth by counting path separators
                const depth = std.mem.count(u8, line, &[_]u8{std.fs.path.sep});

                // Skip if below min_depth
                if (depth >= input.min_depth) {
                    const owned_path = try allocator.dupe(u8, line);
                    const name = std.fs.path.basename(owned_path);
                    const name_copy = try allocator.dupe(u8, name);

                    try entries.append(allocator, .{
                        .name = name_copy,
                        .path = owned_path,
                        .is_dir = false, // fd returns both, but we'll default to file
                        .depth = depth,
                    });
                }
            }
        }
        line_start = line_end + 1;
        nodes_visited += 1;
    }

    const truncated = nodes_visited >= input.max_nodes_visited or line_start < result.stdout.len;

    return TreeDirResult{
        .entries = entries,
        .nodes_visited = nodes_visited,
        .truncated = truncated,
    };
}

/// Format TreeDirResult as tree string
pub fn tree_dir_result_to_string(allocator: std.mem.Allocator, result: TreeDirResult) ![]const u8 {
    var output = std.ArrayList(u8).empty;
    errdefer output.deinit(allocator);

    const writer = output.writer(allocator);

    for (result.entries.items) |entry| {
        // Add indentation based on depth
        for (0..entry.depth) |_| {
            try writer.writeAll("  ");
        }

        // Add tree connector
        if (entry.depth > 0) {
            try writer.writeAll("├── ");
        }

        // Write entry name
        try writer.writeAll(entry.name);

        // Add directory marker
        if (entry.is_dir) {
            try writer.writeAll("/");
        }

        try writer.writeByte('\n');
    }

    // Add truncation message if needed
    if (result.truncated) {
        try writer.print("\n[Output truncated: visited {d} nodes]", .{result.nodes_visited});
    }

    return try output.toOwnedSlice(allocator);
}

/// OpenAI-compatible tree_dir tool definition.
pub const tree_dir_tool = AgentTool{
    .type = "function",
    .function = .{
        .name = "tree_dir",
        .description =
        \\Display directory structure as a tree.
        \\Traverses a directory recursively and returns its structure.
        \\Useful for understanding project layout and file organization.
        ,
        .parameters = .{
            .type = "object",
            .properties = &.{
                .{
                    .name = "root_path",
                    .type = "string",
                    .description = "Root path to start traversing from.",
                },
                .{
                    .name = "max_depth",
                    .type = "number",
                    .description = "Maximum depth to traverse. Default: 4.",
                },
                .{
                    .name = "max_results",
                    .type = "number",
                    .description = "Maximum number of entries to return. Default: unlimited.",
                },
                .{
                    .name = "hidden",
                    .type = "string",
                    .description = "Hidden file mode: 'exclude', 'include', or 'only'. Default: 'exclude'.",
                },
                .{
                    .name = "ignore_globs",
                    .type = "array",
                    .description = "Array of glob patterns to ignore (e.g. ['node_modules', '*.log']). Default: null.",
                },
            },
            .required = &.{ "root_path" },
        },
    },
};
