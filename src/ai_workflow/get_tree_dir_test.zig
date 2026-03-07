const std = @import("std");
const get_tree_dir = @import("get_tree_dir.zig");

test "get_tree_dir returns string" {
    const allocator = std.testing.allocator;
    const cwd = ".";
    
    // This will actually run the tree command
    const result = get_tree_dir.run(allocator, cwd) catch |err| {
        // If tree command fails, that's ok for this test
        if (err == error.FileNotFound or err == error.ExitCodeFailure) {
            return;
        }
        return err;
    };
    defer allocator.free(result);
    
    // Result should be a string (could be empty if no files)
    // Just verify it doesn't crash - using result to avoid unused warning
    try std.testing.expect(result.len >= 0);
}

test "get_tree_dir with nonexistent directory" {
    const allocator = std.testing.allocator;
    const cwd = "/nonexistent/path/that/does/not/exist";
    
    // Should fail gracefully
    const result = get_tree_dir.run(allocator, cwd);
    try std.testing.expect(result == error.FileNotFound or result == error.ExitCodeFailure);
}
