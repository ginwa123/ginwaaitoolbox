const std = @import("std");
const read_file_mod = @import("read_file.zig");

test "read_file - read entire file" {
    const allocator = std.testing.allocator;
    const test_path = "test_read.txt";
    const test_content = "Line 1\nLine 2\nLine 3\n";
    
    // Create test file
    const file = try std.fs.cwd().createFile(test_path, .{});
    defer file.close();
    try file.writeAll(test_content);
    
    const result = try read_file_mod.read_file(allocator, test_path, .{});
    defer result.deinit(allocator);
    
    try std.testing.expectEqualStrings(test_content, result.content);
    try std.testing.expectEqual(@as(usize, 3), result.total_lines);
    try std.testing.expectEqual(@as(usize, 0), result.start_line);
    try std.testing.expectEqual(@as(usize, 2), result.end_line);
    
    // Clean up
    try std.fs.cwd().deleteFile(test_path);
}

test "read_file - with offset and limit" {
    const allocator = std.testing.allocator;
    const test_path = "test_read_offset.txt";
    const test_content = "Line 1\nLine 2\nLine 3\nLine 4\nLine 5\n";
    
    // Create test file
    const file = try std.fs.cwd().createFile(test_path, .{});
    defer file.close();
    try file.writeAll(test_content);
    
    // Read from offset 1, limit 2
    const result = try read_file_mod.read_file(allocator, test_path, .{
        .offset = 1,
        .limit = 2,
    });
    defer result.deinit(allocator);
    
    try std.testing.expectEqualStrings("Line 2\nLine 3\n", result.content);
    try std.testing.expectEqual(@as(usize, 5), result.total_lines);
    try std.testing.expectEqual(@as(usize, 1), result.start_line);
    try std.testing.expectEqual(@as(usize, 2), result.end_line);
    
    // Clean up
    try std.fs.cwd().deleteFile(test_path);
}

test "read_file - with show_line_numbers enabled" {
    const allocator = std.testing.allocator;
    const test_path = "test_read_line_nums.txt";
    const test_content = "Line 1\nLine 2\nLine 3\n";
    
    // Create test file
    const file = try std.fs.cwd().createFile(test_path, .{});
    defer file.close();
    try file.writeAll(test_content);
    
    const result = try read_file_mod.read_file(allocator, test_path, .{
        .show_line_numbers = true,
    });
    defer result.deinit(allocator);
    
    // Expected: "   1\tLine 1\n   2\tLine 2\n   3\tLine 3\n"
    const expected = "   1\tLine 1\n   2\tLine 2\n   3\tLine 3\n";
    try std.testing.expectEqualStrings(expected, result.content);
    try std.testing.expectEqual(@as(usize, 3), result.total_lines);
    try std.testing.expectEqual(@as(usize, 0), result.start_line);
    try std.testing.expectEqual(@as(usize, 2), result.end_line);
    
    // Clean up
    try std.fs.cwd().deleteFile(test_path);
}

test "read_file - show_line_numbers with offset and limit" {
    const allocator = std.testing.allocator;
    const test_path = "test_read_line_nums_offset.txt";
    const test_content = "Line 1\nLine 2\nLine 3\nLine 4\nLine 5\n";
    
    // Create test file
    const file = try std.fs.cwd().createFile(test_path, .{});
    defer file.close();
    try file.writeAll(test_content);
    
    // Read from offset 1, limit 2, with line numbers
    const result = try read_file_mod.read_file(allocator, test_path, .{
        .offset = 1,
        .limit = 2,
        .show_line_numbers = true,
    });
    defer result.deinit(allocator);
    
    // Line numbers should still show actual line numbers (1-indexed), not offset
    const expected = "   2\tLine 2\n   3\tLine 3\n";
    try std.testing.expectEqualStrings(expected, result.content);
    try std.testing.expectEqual(@as(usize, 5), result.total_lines);
    try std.testing.expectEqual(@as(usize, 1), result.start_line);
    try std.testing.expectEqual(@as(usize, 2), result.end_line);
    
    // Clean up
    try std.fs.cwd().deleteFile(test_path);
}

test "read_file - show_line_numbers defaults to false" {
    const allocator = std.testing.allocator;
    const test_path = "test_read_no_line_nums.txt";
    const test_content = "Hello\n";
    
    // Create test file
    const file = try std.fs.cwd().createFile(test_path, .{});
    defer file.close();
    try file.writeAll(test_content);
    
    // Without show_line_numbers (should default to false)
    const result = try read_file_mod.read_file(allocator, test_path, .{});
    defer result.deinit(allocator);
    
    try std.testing.expectEqualStrings(test_content, result.content);
    
    // Clean up
    try std.fs.cwd().deleteFile(test_path);
}

test "read_file - file without trailing newline" {
    const allocator = std.testing.allocator;
    const test_path = "test_read_no_newline.txt";
    const test_content = "No newline at end";
    
    // Create test file without trailing newline
    const file = try std.fs.cwd().createFile(test_path, .{});
    defer file.close();
    try file.writeAll(test_content);
    
    const result = try read_file_mod.read_file(allocator, test_path, .{});
    defer result.deinit(allocator);
    
    try std.testing.expectEqualStrings(test_content, result.content);
    try std.testing.expectEqual(@as(usize, 1), result.total_lines);
    
    // Clean up
    try std.fs.cwd().deleteFile(test_path);
}

test "read_file - error on non-existent file" {
    const allocator = std.testing.allocator;
    const result = read_file_mod.read_file(allocator, "non_existent_file_xyz.txt", .{});
    
    try std.testing.expectError(error.FileNotFound, result);
}

test "read_file - result serialization" {
    const allocator = std.testing.allocator;
    const test_path = "test_serialize_read.txt";
    const test_content = "Test\n";
    
    // Create test file
    const file = try std.fs.cwd().createFile(test_path, .{});
    defer file.close();
    try file.writeAll(test_content);
    
    const result = try read_file_mod.read_file(allocator, test_path, .{});
    defer result.deinit(allocator);
    
    const serialized = try read_file_mod.readFileToString(allocator, result);
    defer allocator.free(serialized);
    
    // Should contain expected XML tags
    try std.testing.expect(std.mem.indexOf(u8, serialized, "<content>") != null);
    try std.testing.expect(std.mem.indexOf(u8, serialized, "<total_lines>") != null);
    try std.testing.expect(std.mem.indexOf(u8, serialized, "<start_line>") != null);
    try std.testing.expect(std.mem.indexOf(u8, serialized, "<end_line>") != null);
    
    // Clean up
    try std.fs.cwd().deleteFile(test_path);
}

test "read_file tool definition exists" {
    // Verify the tool definition matches expected structure
    try std.testing.expectEqualStrings("read_file", read_file_mod.readFileTool.function.name);
}

test "read_file tool has show_line_numbers parameter" {
    // Verify the tool has the new parameter defined
    const tool = read_file_mod.readFileTool;
    const params = tool.function.parameters;
    
    // Find show_line_numbers property
    var found = false;
    for (params.properties) |prop| {
        if (std.mem.eql(u8, prop.name, "show_line_numbers")) {
            found = true;
            try std.testing.expectEqualStrings("boolean", prop.type);
        }
    }
    try std.testing.expect(found);
}
