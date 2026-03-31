# Tree Dir Tool Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Create a `tree_dir` agent tool that recursively traverses a directory and returns its structure with configurable depth, filtering, and safety limits.

**Architecture:** Pure Zig implementation using `std.fs.IterableDir` for directory traversal. Returns results as `TreeDirResult` with a string formatter. Tool definition follows OpenAI function-calling schema.

**Tech Stack:** Zig 0.15.2, std library (fs, mem, json)

**Naming Conventions:**
- Functions/variables: `snake_case`
- Structs/types: `PascalCase`

---

## File Structure

| Action | File |
|--------|------|
| Create | `src/modules/agent/tools/tree_dir.zig` |
| Create | `src/modules/agent/tools/tree_dir_test.zig` |
| Modify | `src/ai_workflow/tui/all_agent_tools.zig` |
| Modify | `src/ai_workflow/tui/handle_spawn_sub_agent.zig` |

---

## Chunk 1: Core Data Structures & Basic Traversal

### Task 1: Create `tree_dir.zig` with TreeDirInput and basic entry types

**Files:**
- Create: `src/modules/agent/tools/tree_dir.zig`
- Test: `src/modules/agent/tools/tree_dir_test.zig`

- [ ] **Step 1: Write the failing test**

```zig
const std = @import("std");
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;

const tree_dir = @import("tree_dir.zig");
const TreeDirInput = tree_dir.TreeDirInput;
const HiddenMode = tree_dir.HiddenMode;
const TreeDirEntry = tree_dir.TreeDirEntry;

test "TreeDirInput default values" {
    const input = TreeDirInput{ .root_path = "." };
    
    try expectEqual(@as(usize, 0), input.min_depth);
    try expectEqual(@as(?usize, 4), input.max_depth);
    try expectEqual(@as(usize, 10_000), input.max_nodes_visited);
    try expectEqual(@as(?usize, null), input.max_results);
    try expectEqual(HiddenMode.exclude, input.hidden);
    try expectEqual(true, input.include_files);
    try expectEqual(true, input.include_dirs);
    try expectEqual(false, input.follow_symlinks);
    try expectEqual(true, input.detect_cycles);
    try expectEqual(false, input.include_metadata);
}

test "HiddenMode enum values" {
    try expectEqual(@as(u8, 0), @intFromEnum(HiddenMode.exclude));
    try expectEqual(@as(u8, 1), @intFromEnum(HiddenMode.include));
    try expectEqual(@as(u8, 2), @intFromEnum(HiddenMode.only));
}

test "TreeDirEntry basic struct" {
    const entry = TreeDirEntry{
        .name = "file.txt",
        .path = "/root/file.txt",
        .is_dir = false,
        .depth = 1,
    };
    
    try expectEqualSlices(u8, "file.txt", entry.name);
    try expectEqualSlices(u8, "/root/file.txt", entry.path);
    try expectEqual(false, entry.is_dir);
    try expectEqual(@as(usize, 1), entry.depth);
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `zig build test --seed 0 2>&1 | head -n 50`
Expected: FAIL with "file not found: tree_dir.zig"

- [ ] **Step 3: Write minimal implementation**

```zig
const std = @import("std");
const AgentTool = @import("schemas.zig").AgentTool;

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

/// Execute tree_dir traversal
pub fn execute_tree_dir(allocator: std.mem.Allocator, input: TreeDirInput) !TreeDirResult {
    // TODO: implementation
    _ = allocator;
    _ = input;
    return error.NotYetImplemented;
}

/// Format TreeDirResult as tree string
pub fn tree_dir_result_to_string(allocator: std.mem.Allocator, result: TreeDirResult) ![]const u8 {
    _ = allocator;
    _ = result;
    return error.NotYetImplemented;
}

/// OpenAI-compatible tree_dir tool definition
pub const tree_dir_tool;
```

- [ ] **Step 4: Run test to verify it passes**

Run: `zig build test --seed 0 2>&1 | head -n 50`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add src/modules/agent/tools/tree_dir.zig src/modules/agent/tools/tree_dir_test.zig
git commit -m "feat(tree_dir): add TreeDirInput, TreeDirEntry, TreeDirResult structs"
```

---

### Task 2: Implement directory traversal with depth control

**Files:**
- Modify: `src/modules/agent/tools/tree_dir.zig`
- Modify: `src/modules/agent/tools/tree_dir_test.zig`

- [ ] **Step 1: Write the failing test**

```zig
test "execute_tree_dir basic traversal" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const input = TreeDirInput{
        .root_path = "src",
        .max_depth = 2,
    };

    var result = try execute_tree_dir(allocator, input);
    defer result.deinit(allocator);

    try expect(result.nodes_visited > 0);
    try expect(result.entries.items.len > 0);
    // First entry should be the root (depth 0)
    try expectEqual(@as(usize, 0), result.entries.items[0].depth);
}

test "execute_tree_dir respects max_depth" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const input = TreeDirInput{
        .root_path = "src",
        .max_depth = 1,
    };

    var result = try execute_tree_dir(allocator, input);
    defer result.deinit(allocator);

    // All entries should have depth <= 1
    for (result.entries.items) |entry| {
        try expect(entry.depth <= 1);
    }
}

test "execute_tree_dir handles non-existent path" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const input = TreeDirInput{
        .root_path = "/nonexistent/path/12345",
    };

    // Should return error or empty result
    const result = execute_tree_dir(allocator, input);
    try expect(result == error.FileNotFound or result == error.AccessDenied);
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `zig build test --seed 0 2>&1 | head -n 50`
Expected: FAIL with "NotYetImplemented"

- [ ] **Step 3: Write implementation**

Replace `execute_tree_dir` with:

```zig
pub fn execute_tree_dir(allocator: std.mem.Allocator, input: TreeDirInput) !TreeDirResult {
    var entries = std.ArrayListUnmanaged(TreeDirEntry){};
    errdefer {
        for (entries.items) |*entry| {
            allocator.free(entry.name);
            allocator.free(entry.path);
        }
        entries.deinit(allocator);
    }

    var nodes_visited: usize = 0;
    var truncated = false;

    // Open root directory
    var root_dir = try std.fs.cwd().openIterableDir(input.root_path, .{});
    defer root_dir.close();

    // Check if root is a file
    const root_stat = try root_dir.dir.stat();
    if (root_stat.kind != .directory) {
        // Root is a file, return just the file entry
        const basename = std.fs.path.basename(input.root_path);
        try entries.append(allocator, .{
            .name = try allocator.dupe(u8, basename),
            .path = try allocator.dupe(u8, input.root_path),
            .is_dir = false,
            .depth = 0,
        });
        return TreeDirResult{
            .entries = entries,
            .nodes_visited = 1,
            .truncated = false,
        };
    }

    // Recursive traversal state
    const max_nodes = input.max_nodes_visited;
    const max_depth = input.max_depth;
    const min_depth = input.min_depth;

    // Stack for iterative traversal: .{dir, parent_path, depth}
    const StackItem = struct {
        dir: std.fs.IterableDir,
        parent_path: []const u8,
        depth: usize,
    };

    var stack = std.ArrayListUnmanaged(StackItem){};
    defer {
        for (stack.items) |*item| {
            item.dir.close();
        }
        stack.deinit(allocator);
    }

    // Add root to stack
    try stack.append(allocator, .{ .dir = root_dir, .parent_path = input.root_path, .depth = 0 });

    while (stack.popOrNull()) |item| {
        var dir = item.dir;
        const parent_path = item.parent_path;
        const depth = item.depth;

        // Skip if we've visited too many nodes
        nodes_visited += 1;
        if (nodes_visited > max_nodes) {
            truncated = true;
            dir.close();
            break;
        }

        // Check depth limits
        if (max_depth != null and depth >= max_depth.?) {
            dir.close();
            continue;
        }

        // Iterate directory
        var it = dir.iterate();
        while (try it.next()) |entry| {
            // Check node limit
            if (nodes_visited >= max_nodes) {
                truncated = true;
                break;
            }

            const name = entry.name;
            
            // Check hidden mode
            if (std.mem.startsWith(u8, name, ".")) {
                switch (input.hidden) {
                    .exclude => continue,
                    .only => {},
                    .include => {},
                }
            } else {
                if (input.hidden == .only) continue;
            }

            // Check if it's a directory or file
            const is_dir = entry.kind == .directory;
            
            if (is_dir and !input.include_dirs) continue;
            if (!is_dir and !input.include_files) continue;

            // Build full path
            const full_path = try std.fs.path.join(allocator, &.{ parent_path, name });
            errdefer allocator.free(full_path);

            // Add entry if within depth range
            if (depth >= min_depth) {
                try entries.append(allocator, .{
                    .name = try allocator.dupe(u8, name),
                    .path = full_path,
                    .is_dir = is_dir,
                    .depth = depth,
                });
            }

            // If directory and within depth, add to stack
            if (is_dir and (max_depth == null or depth + 1 < max_depth.?)) {
                // Open subdirectory
                const subdir = dir.dir.openIterableDir(name, .{
                    .access_subpaths = true,
                }) catch continue;

                try stack.append(allocator, .{
                    .dir = subdir,
                    .parent_path = full_path,
                    .depth = depth + 1,
                });
            }
        }
    }

    return TreeDirResult{
        .entries = entries,
        .nodes_visited = nodes_visited,
        .truncated = truncated,
    };
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `zig build test --seed 0 2>&1 | head -n 80`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add src/modules/agent/tools/tree_dir.zig src/modules/agent/tools/tree_dir_test.zig
git commit -m "feat(tree_dir): implement depth-controlled directory traversal"
```

---

### Task 3: Implement tree string formatter

**Files:**
- Modify: `src/modules/agent/tools/tree_dir.zig`
- Modify: `src/modules/agent/tools/tree_dir_test.zig`

- [ ] **Step 1: Write the failing test**

```zig
test "tree_dir_result_to_string formats tree correctly" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var result = TreeDirResult{
        .entries = std.ArrayListUnmanaged(TreeDirEntry){},
        .nodes_visited = 3,
        .truncated = false,
    };
    defer result.deinit(allocator);

    // Simulate a simple structure: root/a.txt, root/b.txt, root/sub/c.txt
    try result.entries.append(allocator, .{ .name = "src", .path = "/project/src", .is_dir = true, .depth = 0 });
    try result.entries.append(allocator, .{ .name = "file1.zig", .path = "/project/src/file1.zig", .is_dir = false, .depth = 1 });
    try result.entries.append(allocator, .{ .name = "file2.zig", .path = "/project/src/file2.zig", .is_dir = false, .depth = 1 });

    const output = try tree_dir_result_to_string(allocator, result);

    // Should contain tree tags
    try std.testing.expect(std.mem.indexOf(u8, output, "<tree>") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "</tree>") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "src") != null);
}

test "tree_dir_result_to_string shows truncation message" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var result = TreeDirResult{
        .entries = std.ArrayListUnmanaged(TreeDirEntry){},
        .nodes_visited = 10_000,
        .truncated = true,
    };
    defer result.deinit(allocator);

    const output = try tree_dir_result_to_string(allocator, result);

    try std.testing.expect(std.mem.indexOf(u8, output, "truncated") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "10,000") != null);
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `zig build test --seed 0 2>&1 | head -n 50`
Expected: FAIL with "NotYetImplemented"

- [ ] **Step 3: Write implementation**

Replace `tree_dir_result_to_string` with:

```zig
/// Format TreeDirResult as a tree string with ASCII art
pub fn tree_dir_result_to_string(allocator: std.mem.Allocator, result: TreeDirResult) ![]const u8 {
    var output = std.ArrayList(u8).empty;
    errdefer output.deinit(allocator);

    const writer = output.writer(allocator);

    try writer.writeAll("<tree>");

    if (result.entries.items.len == 0) {
        try writer.writeAll("(empty directory)</tree>");
        return try output.toOwnedSlice(allocator);
    }

    // Group entries by depth and parent
    // For simple ASCII tree, we'll just show depth and name
    var last_depth: usize = 0;
    
    for (result.entries.items, 0..) |entry, i| {
        // Build indentation
        if (entry.depth > 0) {
            // Draw vertical lines for intermediate depths
            var d: usize = 1;
            while (d < entry.depth) : (d += 1) {
                try writer.writeAll("│   ");
            }
            
            // Determine connector
            const is_last = blk: {
                // Check if this is the last entry at this depth
                const next_idx = i + 1;
                if (next_idx >= result.entries.items.len) break :blk true;
                const next_entry = result.entries.items[next_idx];
                if (next_entry.depth <= entry.depth) break :blk true;
                break :blk false;
            };
            
            if (is_last) {
                try writer.writeAll("└── ");
            } else {
                try writer.writeAll("├── ");
            }
        }
        
        // Write entry name (with / suffix for directories)
        if (entry.is_dir) {
            try writer.print("{s}/\n", .{entry.name});
        } else {
            try writer.print("{s}\n", .{entry.name});
        }
        
        last_depth = entry.depth;
    }

    // Add truncation notice if needed
    if (result.truncated) {
        const formatted = try std.fmt.allocPrint(allocator, "{d}", .{result.nodes_visited});
        defer allocator.free(formatted);
        
        var formatted_with_commas = std.ArrayList(u8).empty;
        defer formatted_with_commas.deinit(allocator);
        
        var pos: usize = 0;
        const digits = formatted.len;
        while (pos < digits) : (pos += 1) {
            if (pos > 0 and (digits - pos) % 3 == 0) {
                try formatted_with_commas.append(',');
            }
            try formatted_with_commas.append(formatted[pos]);
        }
        
        try writer.print("\n(truncated after {s} items)", .{formatted_with_commas.items});
    }

    try writer.writeAll("</tree>");

    return try output.toOwnedSlice(allocator);
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `zig build test --seed 0 2>&1 | head -n 80`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add src/modules/agent/tools/tree_dir.zig src/modules/agent/tools/tree_dir_test.zig
git commit -m "feat(tree_dir): implement ASCII tree string formatter"
```

---

## Chunk 2: Tool Definition & Integration

### Task 4: Add tool definition and glob filtering

**Files:**
- Modify: `src/modules/agent/tools/tree_dir.zig`
- Modify: `src/modules/agent/tools/tree_dir_test.zig`

- [ ] **Step 1: Write the failing test**

```zig
test "tree_dir_tool definition is valid" {
    const tool = tree_dir.tree_dir_tool;
    
    try expectEqualSlices(u8, "function", tool.type);
    try expectEqualSlices(u8, "tree_dir", tool.function.name);
    try expect(tool.function.description.len > 0);
    try expectEqualSlices(u8, "object", tool.function.parameters.type);
}

test "execute_tree_dir with ignore_globs filters entries" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const input = TreeDirInput{
        .root_path = "src",
        .max_depth = 2,
        .ignore_globs = &.{"*.txt"},
    };

    var result = try execute_tree_dir(allocator, input);
    defer result.deinit(allocator);

    // Should not contain .txt files
    for (result.entries.items) |entry| {
        try expect(!std.mem.endsWith(u8, entry.name, ".txt"));
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `zig build test --seed 0 2>&1 | head -n 50`
Expected: FAIL with "tree_dir.tree_dir_tool"

- [ ] **Step 3: Write implementation**

Add glob matching helper and tool definition:

```zig
/// Simple glob pattern matching (supports * wildcard)
fn matches_glob(name: []const u8, pattern: []const u8) bool {
    // Simple implementation: check if pattern is prefix or suffix
    if (std.mem.eql(u8, pattern, "*")) return true;
    
    if (std.mem.startsWith(u8, pattern, "*")) {
        const suffix = pattern[1..];
        return std.mem.endsWith(u8, name, suffix);
    }
    
    if (std.mem.endsWith(u8, pattern, "*")) {
        const prefix = pattern[0..pattern.len - 1];
        return std.mem.startsWith(u8, name, prefix);
    }
    
    return std.mem.eql(u8, name, pattern);
}

/// OpenAI-compatible tree_dir tool definition
pub const tree_dir_tool = AgentTool{
    .type = "function",
    .function = .{
        .name = "tree_dir",
        .description =
        \\Display the directory structure as a tree.
        \\Returns: <tree>formatted output</tree>
        \\
        \\- Use this to visualize folder hierarchies
        \\- Respects max_depth to control recursion depth
        \\- Truncates output if max_nodes_visited is exceeded
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
                    .name = "min_depth",
                    .type = "number",
                    .description = "Minimum depth to include (0 = root only). Default: 0.",
                },
                .{
                    .name = "max_depth",
                    .type = "number",
                    .description = "Maximum depth to traverse (null = no limit). Default: 4.",
                },
                .{
                    .name = "max_nodes_visited",
                    .type = "number",
                    .description = "Maximum number of filesystem nodes to visit (safety limit). Default: 10000.",
                },
                .{
                    .name = "max_results",
                    .type = "number",
                    .description = "Maximum number of entries to return (null = no limit).",
                },
                .{
                    .name = "hidden",
                    .type = "string",
                    .description = "Hidden file mode: 'exclude', 'include', or 'only'. Default: 'exclude'.",
                },
                .{
                    .name = "include_files",
                    .type = "boolean",
                    .description = "Include files in output. Default: true.",
                },
                .{
                    .name = "include_dirs",
                    .type = "boolean",
                    .description = "Include directories in output. Default: true.",
                },
                .{
                    .name = "ignore_globs",
                    .type = "array",
                    .description = "Glob patterns to ignore (e.g. 'node_modules', '*.log').",
                    .items = &.{.{ .type = "string" }},
                },
                .{
                    .name = "include_globs",
                    .type = "array",
                    .description = "Only include entries matching these patterns.",
                    .items = &.{.{ .type = "string" }},
                },
                .{
                    .name = "follow_symlinks",
                    .type = "boolean",
                    .description = "Follow symbolic links. Default: false.",
                },
                .{
                    .name = "detect_cycles",
                    .type = "boolean",
                    .description = "Detect and prevent cycles when following symlinks. Default: true.",
                },
            },
            .required = &.{ "root_path" },
        },
    },
};
```

- [ ] **Step 4: Run test to verify it passes**

Run: `zig build test --seed 0 2>&1 | head -n 80`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add src/modules/agent/tools/tree_dir.zig src/modules/agent/tools/tree_dir_test.zig
git commit -m "feat(tree_dir): add tool definition and glob filtering"
```

---

### Task 5: Register tool in all_agent_tools.zig

**Files:**
- Modify: `src/ai_workflow/tui/all_agent_tools.zig`

- [ ] **Step 1: Add import**

Add after the other imports:
```zig
const tree_dir_tool = root_mod.tree_dir;
```

- [ ] **Step 2: Add to all_agent_tools array**

Add after glob_tool:
```zig
    tree_dir_tool.tree_dir_tool,
```

- [ ] **Step 3: Verify build**

Run: `zig build 2>&1 | head -n 50`
Expected: No errors

- [ ] **Step 4: Commit**

```bash
git add src/ai_workflow/tui/all_agent_tools.zig
git commit -m "feat(tree_dir): register tool in all_agent_tools"
```

---

### Task 6: Add handler in handle_spawn_sub_agent.zig

**Files:**
- Modify: `src/ai_workflow/tui/handle_spawn_sub_agent.zig`

- [ ] **Step 1: Add import**

```zig
const TreeDirTool = root_mod.tree_dir;
```

- [ ] **Step 2: Add exec function**

Add after the other exec functions:

```zig
fn exec_tree_dir(
    allocator: std.mem.Allocator,
    tc: agent.ToolCall,
    db: *sqlite.SqliteBackend,
    session_id: []const u8,
) !SubAgentToolResult {
    _ = db;
    _ = session_id;
    
    const input = try tc.parseArgs(TreeDirInput);
    var result = try execute_tree_dir(allocator, input);
    errdefer result.deinit(allocator);
    
    const output = try tree_dir_result_to_string(allocator, result);
    errdefer allocator.free(output);
    
    return SubAgentToolResult{
        .content = output,
        .is_error = false,
    };
}
```

- [ ] **Step 3: Register in SUB_AGENT_TOOL_REGISTRY**

Add to the registry array:
```zig
.{ .name = "tree_dir", .exec = exec_tree_dir, .tool_def = TreeDirTool.tree_dir_tool },
```

- [ ] **Step 4: Verify build**

Run: `zig build 2>&1 | head -n 50`
Expected: No errors

- [ ] **Step 5: Commit**

```bash
git add src/ai_workflow/tui/handle_spawn_sub_agent.zig
git commit -m "feat(tree_dir): add handler in handle_spawn_sub_agent"
```

---

## Chunk 3: Advanced Features

### Task 7: Add cycle detection for symlinks

**Files:**
- Modify: `src/modules/agent/tools/tree_dir.zig`
- Modify: `src/modules/agent/tools/tree_dir_test.zig`

- [ ] **Step 1: Write the failing test**

```zig
test "execute_tree_dir detects symlink cycles" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // Create a temp directory with a circular symlink
    const tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    
    // Create dir/a -> dir (circular)
    try tmp_dir.dir.symLink(".", "circular_link", .dir);
    
    const input = TreeDirInput{
        .root_path = tmp_dir.path,
        .max_depth = 10,
        .follow_symlinks = true,
        .detect_cycles = true,
    };

    var result = try execute_tree_dir(allocator, input);
    defer result.deinit(allocator);

    // Should not hang and should complete
    try expect(result.nodes_visited < 1000);
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `zig build test --seed 0 2>&1 | head -n 50`
Expected: FAIL (no cycle detection yet)

- [ ] **Step 3: Implement cycle detection**

Update `execute_tree_dir` to track visited inodes:

```zig
// Track visited directories by inode for cycle detection
var visited_dirs = std.AutoHashMap(u64, void).init(allocator);
defer visited_dirs.deinit();

while (stack.popOrNull()) |item| {
    // ... existing code ...
    
    // Add cycle detection for directories
    if (is_dir) {
        const stat = dir.dir.statFile(name) catch continue;
        if (stat.kind == .directory) {
            const inode = stat.inode;
            
            if (input.detect_cycles) {
                if (visited_dirs.contains(inode)) {
                    continue; // Skip already visited
                }
                try visited_dirs.put(inode, {});
            }
        }
    }
    
    // ... rest of code ...
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `zig build test --seed 0 2>&1 | head -n 80`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add src/modules/agent/tools/tree_dir.zig src/modules/agent/tools/tree_dir_test.zig
git commit -m "feat(tree_dir): add symlink cycle detection"
```

---

### Task 8: Add metadata support

**Files:**
- Modify: `src/modules/agent/tools/tree_dir.zig`
- Modify: `src/modules/agent/tools/tree_dir_test.zig`

- [ ] **Step 1: Write the failing test**

```zig
test "TreeDirEntry with metadata" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const input = TreeDirInput{
        .root_path = "src",
        .include_metadata = true,
    };

    var result = try execute_tree_dir(allocator, input);
    defer result.deinit(allocator);

    // Check that entries have metadata populated
    for (result.entries.items) |entry| {
        if (entry.metadata) |meta| {
            try expect(meta.size > 0 or entry.is_dir);
        }
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `zig build test --seed 0 2>&1 | head -n 50`
Expected: FAIL (no metadata field yet)

- [ ] **Step 3: Add metadata field and populate it**

Update `TreeDirEntry`:
```zig
pub const TreeDirEntry = struct {
    name: []const u8,
    path: []const u8,
    is_dir: bool,
    depth: usize,
    
    /// Optional metadata (only populated if include_metadata is true)
    metadata: ?FileMetadata = null,
};

pub const FileMetadata = struct {
    size: u64,
    modified_ns: i128,
};
```

Update traversal to populate metadata when `input.include_metadata`:
```zig
if (input.include_metadata) {
    const stat = dir.dir.statFile(name) catch null;
    if (stat) |s| {
        entry.metadata = FileMetadata{
            .size = s.size,
            .modified_ns = @intCast(s.mtime),
        };
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `zig build test --seed 0 2>&1 | head -n 80`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add src/modules/agent/tools/tree_dir.zig src/modules/agent/tools/tree_dir_test.zig
git commit -m "feat(tree_dir): add optional metadata support"
```

---

## Execution Handoff

Plan complete and saved to `docs/superpowers/plans/2026-03-31-tree-dir-tool.md`. Ready to execute?

**Use subagent-driven-development to implement this plan.** Each task should be executed by a separate sub-agent with TDD approach. Start with Chunk 1 (core structures), then Chunk 2 (integration), then Chunk 3 (advanced features).
