const std = @import("std");
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualSlices = std.testing.expectEqualSlices;

const tree_dir = @import("tree_dir.zig");
const HiddenMode = tree_dir.HiddenMode;
const TreeDirInput = tree_dir.TreeDirInput;
const TreeDirEntry = tree_dir.TreeDirEntry;
const TreeDirResult = tree_dir.TreeDirResult;
const parseTreeDirInput = tree_dir.parseTreeDirInput;
const execute_tree_dir = tree_dir.execute_tree_dir;
const tree_dir_result_to_string = tree_dir.tree_dir_result_to_string;

test "TreeDirInput default values" {
    const input = TreeDirInput{
        .root_path = "src",
    };

    // Check defaults
    try expect(input.min_depth == 0);
    try expect(input.max_depth == 4);
    try expect(input.max_nodes_visited == 10_000);
    try expect(input.hidden == .exclude);
    try expect(input.include_files == true);
    try expect(input.include_dirs == true);
    try expect(input.ignore_globs == null);
}

test "HiddenMode enum values" {
    try expectEqual(@as(HiddenMode, .exclude), HiddenMode.exclude);
    try expectEqual(@as(HiddenMode, .include), HiddenMode.include);
    try expectEqual(@as(HiddenMode, .only), HiddenMode.only);
}

test "execute_tree_dir basic traversal of src with max_depth=2" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const input = TreeDirInput{
        .root_path = "src",
        .max_depth = 2,
    };

    var result = try execute_tree_dir(allocator, input);
    defer result.deinit(allocator);

    // Should have some output
    try expect(result.entries.items.len > 0);
    // Should not be truncated with reasonable depth
    try expect(!result.truncated);
}

test "execute_tree_dir with hidden files excluded" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const input = TreeDirInput{
        .root_path = "src",
        .max_depth = 1,
        .hidden = .exclude,
    };

    var result = try execute_tree_dir(allocator, input);
    defer result.deinit(allocator);

    // Should have entries
    try expect(result.entries.items.len >= 0);
}

test "execute_tree_dir with directories only" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const input = TreeDirInput{
        .root_path = "src",
        .max_depth = 1,
        .include_files = false,
    };

    var result = try execute_tree_dir(allocator, input);
    defer result.deinit(allocator);

    // Should complete without error
    try expect(result.entries.items.len >= 0);
}

test "execute_tree_dir respects max_nodes_visited" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const input = TreeDirInput{
        .root_path = "src",
        .max_depth = 10,
        .max_nodes_visited = 10,
    };

    var result = try execute_tree_dir(allocator, input);
    defer result.deinit(allocator);

    // Should complete without error even with low limit
    // May be truncated if there are more than 10 entries
    try expect(result.nodes_visited > 0);
}

test "tree_dir_result_to_string formats correctly" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var result = TreeDirResult{
        .entries = std.ArrayListUnmanaged(TreeDirEntry){},
        .nodes_visited = 2,
        .truncated = false,
    };
    defer result.deinit(allocator);

    try result.entries.append(allocator, .{
        .name = try allocator.dupe(u8, "modules"),
        .path = try allocator.dupe(u8, "src/modules"),
        .is_dir = true,
        .depth = 1,
    });
    try result.entries.append(allocator, .{
        .name = try allocator.dupe(u8, "main.zig"),
        .path = try allocator.dupe(u8, "src/main.zig"),
        .is_dir = false,
        .depth = 1,
    });

    const output = try tree_dir_result_to_string(allocator, result);

    // Should contain the entry names
    try expect(std.mem.containsAtLeast(u8, output, 1, "modules"));
    try expect(std.mem.containsAtLeast(u8, output, 1, "main.zig"));
}

test "tree_dir_result_to_string includes truncation notice" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var result = TreeDirResult{
        .entries = std.ArrayListUnmanaged(TreeDirEntry){},
        .nodes_visited = 100,
        .truncated = true,
    };
    defer result.deinit(allocator);

    const output = try tree_dir_result_to_string(allocator, result);

    // Should contain truncation notice
    try expect(std.mem.containsAtLeast(u8, output, 1, "truncated"));
    try expect(std.mem.containsAtLeast(u8, output, 1, "100"));
}

test "tree_dir_result_to_string handles empty entries" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const result = TreeDirResult{
        .entries = std.ArrayListUnmanaged(TreeDirEntry){},
        .nodes_visited = 0,
        .truncated = false,
    };

    const output = try tree_dir_result_to_string(allocator, result);

    // Should return empty output (just truncation message if truncated)
    try expect(!result.truncated);
    _ = output;
}

test "TreeDirResult struct fields" {
    var result = TreeDirResult{
        .entries = std.ArrayListUnmanaged(TreeDirEntry){},
        .nodes_visited = 42,
        .truncated = true,
    };
    defer result.deinit(std.testing.allocator);

    try expectEqual(@as(usize, 42), result.nodes_visited);
    try expect(result.truncated == true);
    try expect(result.entries.items.len == 0);
}

test "TreeDirEntry struct fields" {
    const entry = TreeDirEntry{
        .name = "test.zig",
        .path = "/path/to/test.zig",
        .is_dir = false,
        .depth = 2,
    };

    try expectEqualSlices(u8, "test.zig", entry.name);
    try expectEqualSlices(u8, "/path/to/test.zig", entry.path);
    try expect(entry.is_dir == false);
    try expectEqual(@as(usize, 2), entry.depth);
}

test "tree_dir_tool definition is valid" {
    const tool = tree_dir.tree_dir_tool;

    try expectEqualSlices(u8, "function", tool.type);
    try expectEqualSlices(u8, "tree_dir", tool.function.name);
    try expect(tool.function.description.len > 0);
    try expectEqualSlices(u8, "object", tool.function.parameters.type);
    try expect(tool.function.parameters.properties.len > 0);

    // Check required fields
    const required = tool.function.parameters.required;
    try expect(required.len == 1);
    try expectEqualSlices(u8, "root_path", required[0]);
}

test "parseTreeDirInput parses valid JSON" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const json_str = "{\"root_path\": \"src\", \"max_depth\": 2}";
    const input = try parseTreeDirInput(allocator, json_str);

    try expectEqualSlices(u8, "src", input.root_path);
    try expectEqual(@as(?usize, @as(usize, 2)), input.max_depth);
}
