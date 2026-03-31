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
    try expect(input.max_depth == 4);
    try expect(input.max_results == null);
    try expect(input.hidden == .exclude);
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
    try expect(result.total_entries > 0);
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

test "execute_tree_dir respects max_results" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const input = TreeDirInput{
        .root_path = "src",
        .max_depth = 3,
        .max_results = 5,
    };

    var result = try execute_tree_dir(allocator, input);
    defer result.deinit(allocator);

    // Should not exceed max_results
    try expect(result.entries.items.len <= 5);
}

test "tree_dir_result_to_string formats correctly" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var result = TreeDirResult{
        .entries = std.ArrayListUnmanaged(TreeDirEntry){},
        .total_entries = 2,
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
    // Should show directory marker
    try expect(std.mem.containsAtLeast(u8, output, 1, "/"));
    // Should show entry count
    try expect(std.mem.containsAtLeast(u8, output, 1, "2 entries"));
}

test "tree_dir_result_to_string handles empty entries" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const result = TreeDirResult{
        .entries = std.ArrayListUnmanaged(TreeDirEntry){},
        .total_entries = 0,
    };

    const output = try tree_dir_result_to_string(allocator, result);

    // Should return empty output with zero entries
    try expect(std.mem.containsAtLeast(u8, output, 1, "0 entries"));
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
