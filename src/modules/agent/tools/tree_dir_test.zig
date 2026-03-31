const std = @import("std");
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualSlices = std.testing.expectEqualSlices;
const expectError = std.testing.expectError;

const tree_dir = @import("tree_dir.zig");
const HiddenMode = tree_dir.HiddenMode;
const TreeDirInput = tree_dir.TreeDirInput;
const TreeDirEntry = tree_dir.TreeDirEntry;
const TreeDirResult = tree_dir.TreeDirResult;
const execute_tree_dir = tree_dir.execute_tree_dir;
const tree_dir_result_to_string = tree_dir.tree_dir_result_to_string;

test "HiddenMode enum values" {
    try expect(@as(HiddenMode, .exclude) == .exclude);
    try expect(@as(HiddenMode, .include) == .include);
    try expect(@as(HiddenMode, .only) == .only);
}

test "TreeDirInput default values" {
    const input = TreeDirInput{
        .root_path = "/tmp",
    };

    // Check default values
    try expectEqual(@as(usize, 0), input.min_depth);
    try expectEqual(@as(usize, 4), input.max_depth);
    try expectEqual(@as(usize, 10000), input.max_nodes_visited);
    try expectEqual(@as(?u32, null), input.timeout_ms);
    try expectEqual(@as(?usize, null), input.max_results);
    try expectEqual(HiddenMode.exclude, input.hidden);
    try expect(input.include_files == true);
    try expect(input.include_dirs == true);
    try expectEqual(@as(?[]const []const u8, null), input.ignore_globs);
    try expectEqual(@as(?[]const []const u8, null), input.include_globs);
    try expect(input.follow_symlinks == false);
    try expect(input.detect_cycles == true);
    try expect(input.include_metadata == false);
}

test "TreeDirInput with custom values" {
    const input = TreeDirInput{
        .root_path = "/home/user",
        .min_depth = 1,
        .max_depth = 6,
        .max_nodes_visited = 5000,
        .timeout_ms = 1000,
        .max_results = 100,
        .hidden = .include,
        .include_files = false,
        .include_dirs = true,
        .follow_symlinks = true,
        .detect_cycles = false,
        .include_metadata = true,
    };

    try expectEqualSlices(u8, "/home/user", input.root_path);
    try expectEqual(@as(usize, 1), input.min_depth);
    try expectEqual(@as(usize, 6), input.max_depth);
    try expectEqual(@as(usize, 5000), input.max_nodes_visited);
    try expectEqual(@as(?u32, 1000), input.timeout_ms);
    try expectEqual(@as(?usize, 100), input.max_results);
    try expectEqual(HiddenMode.include, input.hidden);
    try expect(input.include_files == false);
    try expect(input.include_dirs == true);
    try expect(input.follow_symlinks == true);
    try expect(input.detect_cycles == false);
    try expect(input.include_metadata == true);
}

test "TreeDirEntry structure creation" {
    const entry = TreeDirEntry{
        .name = "test.txt",
        .path = "/tmp/test.txt",
        .is_dir = false,
        .depth = 2,
    };

    try expectEqualSlices(u8, "test.txt", entry.name);
    try expectEqualSlices(u8, "/tmp/test.txt", entry.path);
    try expect(entry.is_dir == false);
    try expectEqual(@as(usize, 2), entry.depth);
}

test "TreeDirEntry for directory" {
    const entry = TreeDirEntry{
        .name = "src",
        .path = "/project/src",
        .is_dir = true,
        .depth = 1,
    };

    try expectEqualSlices(u8, "src", entry.name);
    try expectEqualSlices(u8, "/project/src", entry.path);
    try expect(entry.is_dir == true);
    try expectEqual(@as(usize, 1), entry.depth);
}

test "TreeDirResult structure creation" {
    const entries = std.ArrayListUnmanaged(TreeDirEntry){};
    const result = TreeDirResult{
        .entries = entries,
        .nodes_visited = 0,
        .truncated = false,
    };

    try expectEqual(@as(usize, 0), result.entries.items.len);
    try expectEqual(@as(usize, 0), result.nodes_visited);
    try expect(result.truncated == false);
}

test "TreeDirResult with entries" {
    var entries = std.ArrayListUnmanaged(TreeDirEntry){};
    try entries.append(std.testing.allocator, .{
        .name = try std.testing.allocator.dupe(u8, "file1.txt"),
        .path = try std.testing.allocator.dupe(u8, "/tmp/file1.txt"),
        .is_dir = false,
        .depth = 0,
    });
    try entries.append(std.testing.allocator, .{
        .name = try std.testing.allocator.dupe(u8, "subdir"),
        .path = try std.testing.allocator.dupe(u8, "/tmp/subdir"),
        .is_dir = true,
        .depth = 1,
    });

    var result = TreeDirResult{
        .entries = entries,
        .nodes_visited = 10,
        .truncated = false,
    };

    try expectEqual(@as(usize, 2), result.entries.items.len);
    try expectEqual(@as(usize, 10), result.nodes_visited);
    try expect(result.truncated == false);

    // Clean up memory
    result.deinit(std.testing.allocator);
}

test "TreeDirResult deinit cleans up memory" {
    var entries = std.ArrayListUnmanaged(TreeDirEntry){};
    try entries.append(std.testing.allocator, .{
        .name = try std.testing.allocator.dupe(u8, "test.txt"),
        .path = try std.testing.allocator.dupe(u8, "/tmp/test.txt"),
        .is_dir = false,
        .depth = 0,
    });
    try entries.append(std.testing.allocator, .{
        .name = try std.testing.allocator.dupe(u8, "subdir"),
        .path = try std.testing.allocator.dupe(u8, "/tmp/subdir"),
        .is_dir = true,
        .depth = 1,
    });

    var result = TreeDirResult{
        .entries = entries,
        .nodes_visited = 2,
        .truncated = false,
    };

    // deinit should not panic and should clean up memory
    result.deinit(std.testing.allocator);
}

test "execute_tree_dir returns NotYetImplemented error" {
    const input = TreeDirInput{
        .root_path = "/tmp",
    };

    try expectError(error.NotYetImplemented, execute_tree_dir(std.testing.allocator, input));
}

test "tree_dir_result_to_string returns NotYetImplemented error" {
    const entries = std.ArrayListUnmanaged(TreeDirEntry){};
    const result = TreeDirResult{
        .entries = entries,
        .nodes_visited = 0,
        .truncated = false,
    };

    try expectError(error.NotYetImplemented, tree_dir_result_to_string(std.testing.allocator, result));
}

test "TreeDirInput depth range validation in defaults" {
    // Test that min_depth defaults to 0
    const input1 = TreeDirInput{ .root_path = "/tmp" };
    try expectEqual(@as(usize, 0), input1.min_depth);

    // Test that max_depth defaults to 4
    const input2 = TreeDirInput{ .root_path = "/tmp" };
    try expectEqual(@as(usize, 4), input2.max_depth);

    // Verify max_depth >= min_depth when both are custom
    const input3 = TreeDirInput{
        .root_path = "/tmp",
        .min_depth = 2,
        .max_depth = 3,
    };
    try expect(input3.max_depth >= input3.min_depth);
}

test "TreeDirInput with glob patterns" {
    const globs = &.{ "*.txt", "*.md" };
    const input = TreeDirInput{
        .root_path = "/tmp",
        .include_globs = globs,
    };

    try expect(input.include_globs != null);
    try expectEqual(@as(usize, 2), input.include_globs.?.len);
    try expectEqualSlices(u8, "*.txt", input.include_globs.?[0]);
    try expectEqualSlices(u8, "*.md", input.include_globs.?[1]);
}

test "TreeDirInput with ignore patterns" {
    const ignore = &.{ "node_modules", ".git", "*.tmp" };
    const input = TreeDirInput{
        .root_path = "/tmp",
        .ignore_globs = ignore,
    };

    try expect(input.ignore_globs != null);
    try expectEqual(@as(usize, 3), input.ignore_globs.?.len);
    try expectEqualSlices(u8, "node_modules", input.ignore_globs.?[0]);
    try expectEqualSlices(u8, ".git", input.ignore_globs.?[1]);
    try expectEqualSlices(u8, "*.tmp", input.ignore_globs.?[2]);
}

test "TreeDirResult truncated flag" {
    const entries = std.ArrayListUnmanaged(TreeDirEntry){};
    const result = TreeDirResult{
        .entries = entries,
        .nodes_visited = 10000,
        .truncated = true,
    };

    try expect(result.truncated == true);
    try expectEqual(@as(usize, 10000), result.nodes_visited);
}
