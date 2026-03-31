const std = @import("std");
const schemas = @import("schemas.zig");
const AgentTool = schemas.AgentTool;

/// Hidden file mode for tree directory listing.
pub const HiddenMode = enum {
    /// Exclude hidden files and directories (default)
    exclude,
    /// Include hidden files and directories
    include,
    /// Show only hidden files and directories
    only,
};

/// Input for the tree directory tool.
pub const TreeDirInput = struct {
    /// Root path to start tree listing from
    root_path: []const u8,
    /// Minimum depth to traverse (0 = root only, 1 = root + immediate children, etc.)
    min_depth: usize = 0,
    /// Maximum depth to traverse (default: 4)
    max_depth: usize = 4,
    /// Maximum number of nodes to visit before stopping (default: 10000)
    max_nodes_visited: usize = 10000,
    /// Timeout in milliseconds for the operation
    timeout_ms: ?u32 = null,
    /// Maximum number of results to return
    max_results: ?usize = null,
    /// Hidden file mode (exclude, include, only)
    hidden: HiddenMode = .exclude,
    /// Whether to include files in the tree (default: true)
    include_files: bool = true,
    /// Whether to include directories in the tree (default: true)
    include_dirs: bool = true,
    /// Glob patterns to ignore
    ignore_globs: ?[]const []const u8 = null,
    /// Glob patterns to include (if null, all files/dirs are included)
    include_globs: ?[]const []const u8 = null,
    /// Whether to follow symbolic links (default: false)
    follow_symlinks: bool = false,
    /// Whether to detect and avoid cycles when following symlinks (default: true)
    detect_cycles: bool = true,
    /// Whether to include file metadata (size, modified time, etc.) (default: false)
    include_metadata: bool = false,
};

/// A single entry in the tree directory listing.
pub const TreeDirEntry = struct {
    /// Name of the file or directory
    name: []const u8,
    /// Full path to the file or directory
    path: []const u8,
    /// Whether this entry is a directory
    is_dir: bool,
    /// Depth level in the tree (0 = root)
    depth: usize,
};

/// Result from executing a tree directory listing.
pub const TreeDirResult = struct {
    /// List of entries found
    entries: std.ArrayListUnmanaged(TreeDirEntry),
    /// Number of nodes visited during traversal
    nodes_visited: usize,
    /// Whether the result was truncated due to limits
    truncated: bool,

    /// Free all allocated memory.
    pub fn deinit(self: *TreeDirResult, allocator: std.mem.Allocator) void {
        for (self.entries.items) |entry| {
            allocator.free(entry.name);
            allocator.free(entry.path);
        }
        self.entries.deinit(allocator);
    }
};

/// Execute a tree directory listing.
///
/// This is a stub implementation that returns NotYetImplemented.
/// TODO: Implement actual tree directory traversal.
pub fn execute_tree_dir(allocator: std.mem.Allocator, input: TreeDirInput) error{NotYetImplemented}!TreeDirResult {
    _ = allocator;
    _ = input;
    return error.NotYetImplemented;
}

/// Convert TreeDirResult to a string representation.
/// Returns a warning message if no entries are found.
///
/// This is a stub implementation.
/// TODO: Implement actual formatting.
pub fn tree_dir_result_to_string(allocator: std.mem.Allocator, result: TreeDirResult) ![]const u8 {
    _ = allocator;
    _ = result;
    return error.NotYetImplemented;
}

/// OpenAI-compatible tree directory tool definition.
pub const tree_dir_tool: AgentTool = undefined;

test {
    _ = @import("tree_dir_test.zig");
}
