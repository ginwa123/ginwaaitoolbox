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
    err: ?[]const u8,

    pub fn deinit(self: *TreeDirResult, allocator: std.mem.Allocator) void {
        for (self.entries.items) |*entry| {
            allocator.free(entry.name);
            allocator.free(entry.path);
        }
        self.entries.deinit(allocator);
        if (self.err) |e| allocator.free(e);
    }
};

/// Parse tree_dir input from JSON string.
/// Returns an owned TreeDirInput with duplicated strings to avoid use-after-free.
pub fn parseTreeDirInput(allocator: std.mem.Allocator, json_str: []const u8) !TreeDirInput {
    const parsed = try std.json.parseFromSlice(TreeDirInput, allocator, json_str, .{
        .allocate = .alloc_always,
    });
    defer parsed.deinit();

    // Duplicate strings to avoid use-after-free when parsed is deinit'd
    const root_path_dup = try allocator.dupe(u8, parsed.value.root_path);
    errdefer allocator.free(root_path_dup);

    var ignore_globs_dup: ?[]const []const u8 = null;
    if (parsed.value.ignore_globs) |globs| {
        const globs_dup = try allocator.alloc([]const u8, globs.len);
        errdefer {
            for (globs_dup[0..]) |g| allocator.free(g);
            allocator.free(globs_dup);
        }
        for (globs, 0..) |g, i| {
            globs_dup[i] = try allocator.dupe(u8, g);
        }
        ignore_globs_dup = globs_dup;
    }

    return TreeDirInput{
        .root_path = root_path_dup,
        .max_depth = parsed.value.max_depth,
        .max_results = parsed.value.max_results,
        .hidden = parsed.value.hidden,
        .ignore_globs = ignore_globs_dup,
    };
}

/// Free resources in TreeDirInput (call after parseTreeDirInput if not passed to execute_tree_dir).
pub fn freeTreeDirInput(allocator: std.mem.Allocator, input: *TreeDirInput) void {
    allocator.free(input.root_path);
    if (input.ignore_globs) |globs| {
        for (globs) |g| allocator.free(g);
        allocator.free(globs);
    }
}

/// Execute tree_dir traversal using `fd` CLI tool.
pub fn execute_tree_dir(allocator: std.mem.Allocator, input: TreeDirInput) !TreeDirResult {
    // Get list of all entries using fd
    var fd_args = std.ArrayListUnmanaged([]const u8){};
    defer fd_args.deinit(allocator);

    try fd_args.append(allocator, "/usr/sbin/fd");
    try fd_args.append(allocator, "--glob");
    try fd_args.append(allocator, "*");

    // Hidden files option
    switch (input.hidden) {
        .exclude => try fd_args.append(allocator, "--no-hidden"),
        .include => try fd_args.append(allocator, "--hidden"),
        .only => try fd_args.append(allocator, "--hidden"),
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
        .max_output_bytes = 50 * 1024 * 1024,
    });

    defer allocator.free(fd_result.stdout);
    defer allocator.free(fd_result.stderr);

    // Check for fd errors - fd outputs errors to stdout with "[fd error]" prefix
    // Also check stderr and exit code for robustness
    const has_fd_error = std.mem.containsAtLeast(u8, fd_result.stdout, 1, "[fd error]");
    const has_stderr_error = fd_result.stderr.len > 0;
    if (has_fd_error or has_stderr_error) {
        const err_msg = if (has_fd_error) fd_result.stdout else fd_result.stderr;
        return TreeDirResult{
            .entries = .{},
            .total_entries = 0,
            .err = try allocator.dupe(u8, err_msg),
        };
    }

    // Parse stdout to get list of paths
    var paths = std.ArrayListUnmanaged([]const u8){};
    defer {
        for (paths.items) |p| allocator.free(p);
        paths.deinit(allocator);
    }

    var line_start: usize = 0;
    while (line_start < fd_result.stdout.len) {
        const line_end = std.mem.indexOfScalarPos(u8, fd_result.stdout, line_start, '\n') orelse fd_result.stdout.len;
        if (line_end > line_start) {
            const line = fd_result.stdout[line_start..line_end];
            if (line.len > 0) {
                const owned = try allocator.dupe(u8, line);
                errdefer allocator.free(owned);
                try paths.append(allocator, owned);
            }
        }
        line_start = line_end + 1;
    }

    const total_entries = paths.items.len;

    // Parse results
    var entries = std.ArrayListUnmanaged(TreeDirEntry){};
    errdefer {
        for (entries.items) |entry| {
            allocator.free(entry.name);
            allocator.free(entry.path);
        }
        entries.deinit(allocator);
    }

    // Process each path
    for (paths.items) |path| {
        // Calculate depth relative to root_path
        const rel_path = if (std.mem.startsWith(u8, path, input.root_path))
            path[input.root_path.len..]
        else
            path;

        // Strip leading separator
        const clean_rel = if (rel_path.len > 0 and rel_path[0] == std.fs.path.sep)
            rel_path[1..]
        else
            rel_path;

        const depth = std.mem.count(u8, clean_rel, &[_]u8{std.fs.path.sep});

        // Skip if beyond max_depth
        if (input.max_depth != null and depth > input.max_depth.?) {
            continue;
        }

        // Check if it's a directory using stat
        const is_dir = checkIsDirectory(path);

        const owned_path = try allocator.dupe(u8, path);
        const name = std.fs.path.basename(owned_path);
        const name_copy = try allocator.dupe(u8, name);

        try entries.append(allocator, .{
            .name = name_copy,
            .path = owned_path,
            .is_dir = is_dir,
            .depth = depth,
        });

        // Check max_results limit
        if (input.max_results) |max| {
            if (entries.items.len >= max) break;
        }
    }

    // Free input strings since we no longer need them
    allocator.free(input.root_path);
    if (input.ignore_globs) |globs| {
        for (globs) |g| allocator.free(g);
        allocator.free(globs);
    }

    return TreeDirResult{
        .entries = entries,
        .total_entries = total_entries,
        .err = null,
    };
}

/// Check if a path is a directory using stat command
fn checkIsDirectory(path: []const u8) bool {
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

    return std.mem.containsAtLeast(u8, result.stdout, 1, "directory");
}

/// Format TreeDirResult as tree string
pub fn tree_dir_result_to_string(allocator: std.mem.Allocator, result: TreeDirResult) ![]const u8 {
    var output = std.ArrayList(u8).empty;
    errdefer output.deinit(allocator);

    const writer = output.writer(allocator);

    // If there's an error, show it
    if (result.err) |err| {
        try writer.writeAll("[ERROR] ");
        try writer.writeAll(err);
        try writer.writeAll("\n\n");
    }

    if (result.entries.items.len == 0) {
        try writer.writeAll("(0 entries)");
        if (result.total_entries > 0) {
            try writer.writeAll(" (filtered by max_depth)");
        }
        try writer.writeByte('\n');
        return try output.toOwnedSlice(allocator);
    }

    // Track which branches have more entries at each depth
    var active_branches = std.ArrayList(bool).empty;
    defer active_branches.deinit(allocator);

    for (result.entries.items) |entry| {
        // Resize tracking array if needed
        while (active_branches.items.len <= entry.depth) {
            try active_branches.append(allocator, false);
        }

        // Add indentation based on depth
        if (entry.depth > 0) {
            for (0..entry.depth - 1) |d| {
                if (active_branches.items[d]) {
                    try writer.writeAll("│   ");
                } else {
                    try writer.writeAll("    ");
                }
            }
            // Add connector
            try writer.writeAll("├── ");
        } else {
            // Depth 0: show folder indicator
            try writer.writeAll("📁 ");
        }

        // Write entry name
        try writer.writeAll(entry.name);

        // Add directory marker
        if (entry.is_dir) {
            try writer.writeByte('/');
        }

        try writer.writeByte('\n');

        // Mark this depth as having entries
        active_branches.items[entry.depth] = true;

        // Clear deeper depths
        for (entry.depth + 1..active_branches.items.len) |d| {
            active_branches.items[d] = false;
        }
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
            .required = &.{"root_path"},
        },
    },
};
