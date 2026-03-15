const std = @import("std");
const build_memory_for_agent = @import("build_memory_for_agent_prompt.zig");

test "run creates MEMORY.MD and returns content" {
    const allocator = std.testing.allocator;
    
    // Create a temporary directory for testing
    const test_dir_name = "test_memory_dir_1";
    // Clean up if exists
    std.fs.cwd().deleteTree(test_dir_name) catch {};
    
    const test_dir = try std.fs.cwd().makeOpenPath(test_dir_name, .{});
    defer {
        std.fs.cwd().deleteTree(test_dir_name) catch {};
    }
    
    // Get the real path of the temp directory (relative to cwd)
    const cwd = try test_dir.realpathAlloc(allocator, ".");
    defer allocator.free(cwd);
    
    // Run the function - should create MEMORY.MD with empty content
    const content = try build_memory_for_agent.run(allocator, cwd);
    defer allocator.free(content);
    
    // Verify the file was created
    const memory_path = try std.fs.path.join(allocator, &[_][]const u8{ cwd, "MEMORY.MD" });
    defer allocator.free(memory_path);
    
    std.fs.cwd().access(memory_path, .{}) catch {
        return error.FileNotCreated;
    };
    
    // Verify we can read the file
    const file = try std.fs.openFileAbsolute(memory_path, .{});
    defer file.close();
    
    const read_content = try file.readToEndAlloc(allocator, std.math.maxInt(usize));
    defer allocator.free(read_content);
    
    // Content should be empty since we just created it
    try std.testing.expectEqualSlices(u8, "", read_content);
}

test "run returns existing MEMORY.MD content" {
    const allocator = std.testing.allocator;
    
    // Create a temporary directory
    const test_dir_name = "test_memory_dir_2";
    // Clean up if exists
    std.fs.cwd().deleteTree(test_dir_name) catch {};
    
    const test_dir = try std.fs.cwd().makeOpenPath(test_dir_name, .{});
    defer {
        std.fs.cwd().deleteTree(test_dir_name) catch {};
    }
    
    const cwd = try test_dir.realpathAlloc(allocator, ".");
    defer allocator.free(cwd);
    
    // Pre-create MEMORY.MD with some content
    const memory_path = try std.fs.path.join(allocator, &[_][]const u8{ cwd, "MEMORY.MD" });
    defer allocator.free(memory_path);
    
    const test_content = "Hello, Memory!";
    const file = try std.fs.createFileAbsolute(memory_path, .{});
    defer file.close();
    try file.writeAll(test_content);
    
    // Run the function - should return existing content
    const content = try build_memory_for_agent.run(allocator, cwd);
    defer allocator.free(content);
    
    // Verify the content matches what we wrote
    try std.testing.expectEqualSlices(u8, test_content, content);
}
