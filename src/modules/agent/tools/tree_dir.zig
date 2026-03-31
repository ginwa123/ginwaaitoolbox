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
    /// Maximum depth to traverse (null = no limit)
    max_depth: ?usize = 4,

    /// === Output limits ===
    /// Maximum number of entries returned
    max_results: ?usize = null,

    /// === Filtering ===
    hidden: HiddenMode = .exclude,

    /// Glob patterns to ignore (e.g. "node_modules", "*.log")
    ignore_globs: ?[]const []const u8 = null,
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
    total_entries: usize,

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

/// Execute tree_dir traversal using `fd` and `stat` CLI tools.
/// 
/// Strategy:
/// 1. Use `fd` to list all entries (files and directories)
/// 2. For each entry, use `stat` to determine if it's a directory
/// 3. Calculate depth from root_path
/// 4. Filter by max_depth
pub fn execute_tree_dir(allocator: std.mem.Allocator, input: TreeDirInput) !TreeDirResult {
    // Step 1: Get list of all entries using fd
    var fd_args = std.ArrayListUnmanaged([]const u8){};
    errdefer fd_args.deinit(allocator);

    try fd_args.append(allocator, "/usr/sbin/fd");

    // List everything (files and dirs) - fd doesn't support both types at once
    // We'll list all entries and check type with stat
    try fd_args.append(allocator, "--glob");
    try fd_args.append(allocator, "*");

    // Hidden files option
    switch (input.hidden) {
        .exclude => try fd_args.append(allocator, "--no-hidden"),
        .include => try fd_args.append(allocator, "--hidden"),
        .only => {
            // fd doesn't have --only-hidden, so we use --hidden and filter results
            try fd_args.append(allocator, "--hidden");
        },
    }

    // Ignore globs
    if (input.ignore_globs) |globs| {
        for (globs) |glob| {
            try fd_args.append(allocator, "--ignore-file");
            try fd_args.append(allocator, glob);
        }
    }

    // Search from root_path
    try fd_args.append(allocator, input.root_path);

    // Run fd
    const fd_result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = fd_args.items,
        .max_output_bytes = 50 * 1024 * 1024, // 50MB max for large dirs
    });

    defer allocator.free(fd_result.stdout);
    defer allocator.free(fd_result.stderr);

    // Parse results
    var entries = std.ArrayListUnmanaged(TreeDirEntry){};
    errdefer {
        for (entries.items) |entry| {
            allocator.free(entry.name);
            allocator.free(entry.path);
        }
        entries.deinit(allocator);
    }

    // Split stdout by newlines and process each path
    var line_start: usize = 0;
    var total_entries: usize = 0;
    while (line_start < fd_result.stdout.len) {
        const line_end = std.mem.indexOfScalarPos(u8, fd_result.stdout, line_start, '\n') orelse fd_result.stdout.len;
        if (line_end > line_start) {
            const line = fd_result.stdout[line_start..line_end];
            if (line.len > 0) {
                total_entries += 1;

                // Calculate depth relative to root_path
                // Remove root_path prefix to get relative path
                const rel_path = if (std.mem.startsWith(u8, line, input.root_path))
                    line[input.root_path.len..]
                else
                    line;

                // Strip leading separator
                const clean_rel = if (rel_path.len > 0 and rel_path[0] == std.fs.path.sep)
                    rel_path[1..]
                else
                    rel_path;

                const depth = std.mem.count(u8, clean_rel, &[_]u8{std.fs.path.sep});

                // Skip if beyond max_depth (only count dirs in depth calculation)
                if (input.max_depth == null or depth <= input.max_depth.?) {
                    // Check if it's a directory using stat
                    const is_dir = try checkIsDirectory(line);

                    const owned_path = try allocator.dupe(u8, line);
                    const name = std.fs.path.basename(owned_path);
                    const name_copy = try allocator.dupe(u8, name);

                    try entries.append(allocator, .{
                        .name = name_copy,
                        .path = owned_path,
                        .is_dir = is_dir,
                        .depth = depth,
                    });
                }
            }
        }
        line_start = line_end + 1;

        // Check max_results limit (only count if we're adding)
        if (input.max_results) |max| {
            if (entries.items.len >= max) break;
        }
    }

    return TreeDirResult{
        .entries = entries,
        .total_entries = total_entries,
    };
}

/// Check if a path is a directory using stat command
fn checkIsDirectory(path: []const u8) !bool {
    var stat_args = [_][]const u8{ "/usr/bin/stat", "-c", "%F", path };

    const result = std.process.Child.run(.{
        .allocator = std.heap.page_allocator,
        .argv = &stat_args,
        .max_output_bytes = 256,
    }) catch return false;

    defer {
        std.heap.page_allocator.free(result.stdout);
        std.heap.page_allocator.free(result.stderr);
    }

    // Check if output contains "directory"
    return std.mem.containsAtLeast(u8, result.stdout, 1, "directory");
}

/// Format TreeDirResult as tree string
pub fn tree_dir_result_to_string(allocator: std.mem.Allocator, result: TreeDirResult) ![]const u8 {
    var output = std.ArrayList(u8).empty;
    errdefer output.deinit(allocator);

    const writer = output.writer(allocator);

    for (result.entries.items) |entry| {
        // Add indentation based on depth
        for (0..entry.depth) |_| {
            try writer.writeAll("│   ");
        }

        // Add tree connector
        if (entry.depth > 0) {
            try writer.writeAll("├── ");
        }

        // Write entry name
        try writer.writeAll(entry.name);

        // Add directory marker
        if (entry.is_dir) {
            try writer.writeByte('/');
        }

        try writer.writeByte('\n');
    }

    // Add summary
    try writer.print("\n({d} entries)", .{result.total_entries});

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
