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

test "write_file - replace line range" {
    const allocator = std.testing.allocator;
    const test_path = "test_write_range.txt";
    const original_content = "Line 0\nLine 1\nLine 2\nLine 3\nLine 4\n";
    const replacement = "REPLACED\n";
    
    // Create original file
    const orig_file = try std.fs.cwd().createFile(test_path, .{});
    defer orig_file.close();
    try orig_file.writeAll(original_content);
    
    const result = try write_file_mod.write_file(allocator, test_path, .{
        .content = replacement,
        .start_line = 1,
        .end_line = 3, // Replace lines 1-3 (inclusive)
    });
    defer result.deinit(allocator);
    
    // Verify line range was replaced
    const file = try std.fs.cwd().openFile(test_path, .{});
    defer file.close();
    const read_content = try file.readToEndAlloc(allocator, std.math.maxInt(usize));
    defer allocator.free(read_content);
    
    const expected = "Line 0\nREPLACED\nLine 4\n";
    try std.testing.expectEqualStrings(expected, read_content);
    
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

// ====== NEW TESTS FOR BEFORE/AFTER FEATURE ======

test "write_file - before/after captured on line replacement" {
    const allocator = std.testing.allocator;
    const test_path = "test_before_after.txt";
    const original_content = "Line 0\nLine 1\nLine 2\nLine 3\nLine 4\n";
    const replacement = "REPLACED\n";
    
    // Create original file
    const orig_file = try std.fs.cwd().createFile(test_path, .{});
    defer orig_file.close();
    try orig_file.writeAll(original_content);
    
    const result = try write_file_mod.write_file(allocator, test_path, .{
        .content = replacement,
        .start_line = 1,
        .end_line = 3, // Replace lines 1-3 (inclusive)
    });
    defer result.deinit(allocator);
    
    // Verify "before" captures the replaced lines
    const expected_before = "Line 1\nLine 2\nLine 3\n";
    try std.testing.expectEqualStrings(expected_before, result.before);
    
    // Verify "after" contains the new content
    try std.testing.expectEqualStrings(replacement, result.after);
    
    // Clean up
    try std.fs.cwd().deleteFile(test_path);
}

test "write_file - before is empty on full overwrite" {
    const allocator = std.testing.allocator;
    const test_path = "test_before_empty.txt";
    const original_content = "Original content\n";
    const new_content = "New content\n";
    
    // Create original file
    const orig_file = try std.fs.cwd().createFile(test_path, .{});
    defer orig_file.close();
    try orig_file.writeAll(original_content);
    
    const result = try write_file_mod.write_file(allocator, test_path, .{
        .content = new_content,
    });
    defer result.deinit(allocator);
    
    // Verify "before" is empty for full overwrite
    try std.testing.expect(result.before.len == 0);
    
    // Verify "after" contains the new content
    try std.testing.expectEqualStrings(new_content, result.after);
    
    // Clean up
    try std.fs.cwd().deleteFile(test_path);
}

test "write_file - before/after serialization includes new tags" {
    const allocator = std.testing.allocator;
    const test_path = "test_serialize_tags.txt";
    const original_content = "Line 0\nLine 1\nLine 2\n";
    const replacement = "NEW CONTENT\n";
    
    // Create original file
    const orig_file = try std.fs.cwd().createFile(test_path, .{});
    defer orig_file.close();
    try orig_file.writeAll(original_content);
    
    const result = try write_file_mod.write_file(allocator, test_path, .{
        .content = replacement,
        .start_line = 1,
        .end_line = 1, // Replace just line 1
    });
    defer result.deinit(allocator);
    
    const serialized = try write_file_mod.writeFileToString(allocator, result);
    defer allocator.free(serialized);
    
    // Verify XML tags are present
    try std.testing.expect(std.mem.indexOf(u8, serialized, "<before>") != null);
    try std.testing.expect(std.mem.indexOf(u8, serialized, "</before>") != null);
    try std.testing.expect(std.mem.indexOf(u8, serialized, "<after>") != null);
    try std.testing.expect(std.mem.indexOf(u8, serialized, "</after>") != null);
    
    // Verify the actual content is in the serialized output
    try std.testing.expect(std.mem.indexOf(u8, serialized, "Line 1\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, serialized, replacement) != null);
    
    // Clean up
    try std.fs.cwd().deleteFile(test_path);
}

test "write_file - before/after with multiline replacement" {
    const allocator = std.testing.allocator;
    const test_path = "test_multiline.txt";
    const original_content = "START\nold line 1\nold line 2\nEND\n";
    const replacement = "new line A\nnew line B\n";
    
    // Create original file
    const orig_file = try std.fs.cwd().createFile(test_path, .{});
    defer orig_file.close();
    try orig_file.writeAll(original_content);
    
    const result = try write_file_mod.write_file(allocator, test_path, .{
        .content = replacement,
        .start_line = 1,
        .end_line = 2, // Replace lines 1-2
    });
    defer result.deinit(allocator);
    
    // Verify "before" captures both old lines
    const expected_before = "old line 1\nold line 2\n";
    try std.testing.expectEqualStrings(expected_before, result.before);
    
    // Verify "after" contains the multiline replacement
    try std.testing.expectEqualStrings(replacement, result.after);
    
    // Clean up
    try std.fs.cwd().deleteFile(test_path);
}
