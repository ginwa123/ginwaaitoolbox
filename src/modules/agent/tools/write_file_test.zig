const std = @import("std");
const write_file_mod = @import("write_file.zig");

test "write_file - write new file" {
    const allocator = std.testing.allocator;
    const test_path = "test_write_new.txt";
    const test_content = "Hello, World!\n";
    
    // Clean up any existing file
    std.fs.cwd().deleteFile(test_path) catch {};
    
    const result = try write_file_mod.write_file(allocator, test_path, .{
        .content = test_content,
    });
    defer result.deinit(allocator);
    
    // Verify file was created with correct content
    const file = try std.fs.cwd().openFile(test_path, .{});
    defer file.close();
    const read_content = try file.readToEndAlloc(allocator, std.math.maxInt(usize));
    defer allocator.free(read_content);
    
    try std.testing.expectEqualStrings(test_content, read_content);
    
    // Clean up
    try std.fs.cwd().deleteFile(test_path);
}

test "write_file - overwrite existing file" {
    const allocator = std.testing.allocator;
    const test_path = "test_write_overwrite.txt";
    const original_content = "Original content\n";
    const new_content = "New content\n";
    
    // Create original file using createFile
    const orig_file = try std.fs.cwd().createFile(test_path, .{});
    defer orig_file.close();
    try orig_file.writeAll(original_content);
    
    const result = try write_file_mod.write_file(allocator, test_path, .{
        .content = new_content,
    });
    defer result.deinit(allocator);
    
    // Verify content was overwritten
    const file = try std.fs.cwd().openFile(test_path, .{});
    defer file.close();
    const read_content = try file.readToEndAlloc(allocator, std.math.maxInt(usize));
    defer allocator.free(read_content);
    
    try std.testing.expectEqualStrings(new_content, read_content);
    
    // Clean up
    try std.fs.cwd().deleteFile(test_path);
}

test "write_file - error on invalid directory" {
    const allocator = std.testing.allocator;
    const test_path = "/nonexistent/path/file.txt";
    const test_content = "content\n";
    
    // This should return an error
    const result = write_file_mod.write_file(allocator, test_path, .{
        .content = test_content,
    });
    
    try std.testing.expectError(error.FileNotFound, result);
}

test "write_file - result serialization" {
    const allocator = std.testing.allocator;
    const test_path = "test_serialize.txt";
    const test_content = "Test content\n";
    
    // Clean up
    std.fs.cwd().deleteFile(test_path) catch {};
    
    const result = try write_file_mod.write_file(allocator, test_path, .{
        .content = test_content,
    });
    defer result.deinit(allocator);
    
    const serialized = try write_file_mod.writeFileToString(allocator, result);
    defer allocator.free(serialized);
    
    // Should contain path and success indicator
    try std.testing.expect(std.mem.indexOf(u8, serialized, test_path) != null);
    
    // Clean up
    try std.fs.cwd().deleteFile(test_path);
}

test "write_file tool definition exists" {
    // Verify the tool definition matches expected structure
    try std.testing.expectEqualStrings("write_file", write_file_mod.writeFileTool.function.name);
}
