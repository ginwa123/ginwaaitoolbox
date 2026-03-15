const std = @import("std");
const text_replace_mod = @import("text_replace.zig");
const read_file_mod = @import("read_file.zig");

test "text_replace - basic replace single occurrence" {
    const allocator = std.testing.allocator;
    const test_path = "test_replace_basic.txt";
    const original_content = "Hello, World!\n";
    const old_str = "Hello";
    const new_str = "Goodbye";
    
    // Create original file
    const orig_file = try std.fs.cwd().createFile(test_path, .{});
    defer orig_file.close();
    try orig_file.writeAll(original_content);
    
    // Get the hash from read_file
    const read_result = try read_file_mod.read_file(allocator, test_path, .{});
    defer read_result.deinit(allocator);
    
    const result = try text_replace_mod.text_replace(allocator, test_path, old_str, new_str, read_result.sha256);
    defer result.deinit(allocator);
    
    // Verify file content was changed
    const file = try std.fs.cwd().openFile(test_path, .{});
    defer file.close();
    const read_content = try file.readToEndAlloc(allocator, std.math.maxInt(usize));
    defer allocator.free(read_content);
    
    const expected = "Goodbye, World!\n";
    try std.testing.expectEqualStrings(expected, read_content);
    
    // Verify result fields
    try std.testing.expectEqual(@as(usize, 0), result.replaced_at_byte);
    try std.testing.expectEqualStrings(old_str, result.old_str);
    try std.testing.expectEqualStrings(new_str, result.new_str);
    
    // Clean up
    try std.fs.cwd().deleteFile(test_path);
}

test "text_replace - old_str not found returns error" {
    const allocator = std.testing.allocator;
    const test_path = "test_replace_notfound.txt";
    const original_content = "Hello, World!\n";
    
    // Create original file
    const orig_file = try std.fs.cwd().createFile(test_path, .{});
    defer orig_file.close();
    try orig_file.writeAll(original_content);
    
    // Get the hash from read_file
    const read_result = try read_file_mod.read_file(allocator, test_path, .{});
    defer read_result.deinit(allocator);
    
    const result = text_replace_mod.text_replace(allocator, test_path, "nonexistent", "new", read_result.sha256);
    
    try std.testing.expectError(text_replace_mod.TextReplaceError.OldStrNotFound, result);
    
    // Clean up
    try std.fs.cwd().deleteFile(test_path);
}

test "text_replace - old_str appears twice returns OldStrNotUnique" {
    const allocator = std.testing.allocator;
    const test_path = "test_replace_duplicate.txt";
    const original_content = "const x = 0;\nconst x = 0;\n";
    
    // Create original file with two identical lines
    const orig_file = try std.fs.cwd().createFile(test_path, .{});
    defer orig_file.close();
    try orig_file.writeAll(original_content);
    
    // Get the hash from read_file
    const read_result = try read_file_mod.read_file(allocator, test_path, .{});
    defer read_result.deinit(allocator);
    
    // This should fail because "const x = 0;" appears twice (both lines are identical)
    const result = text_replace_mod.text_replace(allocator, test_path, "const x = 0;", "const z = 1;", read_result.sha256);
    
    try std.testing.expectError(text_replace_mod.TextReplaceError.OldStrNotUnique, result);
    
    // Clean up
    try std.fs.cwd().deleteFile(test_path);
}

test "text_replace - replace with empty string" {
    const allocator = std.testing.allocator;
    const test_path = "test_replace_empty.txt";
    const original_content = "Hello, World!\n";
    
    // Create original file
    const orig_file = try std.fs.cwd().createFile(test_path, .{});
    defer orig_file.close();
    try orig_file.writeAll(original_content);
    
    // Get the hash from read_file
    const read_result = try read_file_mod.read_file(allocator, test_path, .{});
    defer read_result.deinit(allocator);
    
    const result = try text_replace_mod.text_replace(allocator, test_path, ", World!", "", read_result.sha256);
    defer result.deinit(allocator);
    
    // Verify content
    const file = try std.fs.cwd().openFile(test_path, .{});
    defer file.close();
    const read_content = try file.readToEndAlloc(allocator, std.math.maxInt(usize));
    defer allocator.free(read_content);
    
    const expected = "Hello\n";
    try std.testing.expectEqualStrings(expected, read_content);
    
    // Clean up
    try std.fs.cwd().deleteFile(test_path);
}

test "text_replace - result serialization" {
    const allocator = std.testing.allocator;
    const test_path = "test_replace_serialize.txt";
    const original_content = "test content\n";
    
    // Create original file
    const orig_file = try std.fs.cwd().createFile(test_path, .{});
    defer orig_file.close();
    try orig_file.writeAll(original_content);
    
    // Get the hash from read_file
    const read_result = try read_file_mod.read_file(allocator, test_path, .{});
    defer read_result.deinit(allocator);
    
    const result = try text_replace_mod.text_replace(allocator, test_path, "test", "new", read_result.sha256);
    defer result.deinit(allocator);
    
    const serialized = try text_replace_mod.textReplaceToStringXML(allocator, result);
    defer allocator.free(serialized);
    
    // Should contain path and replaced_at_byte
    try std.testing.expect(std.mem.indexOf(u8, serialized, test_path) != null);
    try std.testing.expect(std.mem.indexOf(u8, serialized, "<replaced_at_byte>") != null);
    
    // Clean up
    try std.fs.cwd().deleteFile(test_path);
}

test "text_replace tool definition exists" {
    try std.testing.expectEqualStrings("text_replace", text_replace_mod.textReplaceTool.function.name);
}

test "text_replace - unique match with surrounding context" {
    const allocator = std.testing.allocator;
    const test_path = "test_replace_context.txt";
    const original_content = "fn setup() void {\n    const x = 0;\n}\n\nfn other() void {\n    const x = 0;\n}\n";
    
    // Create original file
    const orig_file = try std.fs.cwd().createFile(test_path, .{});
    defer orig_file.close();
    try orig_file.writeAll(original_content);
    
    // Get the hash from read_file
    const read_result = try read_file_mod.read_file(allocator, test_path, .{});
    defer read_result.deinit(allocator);
    
    // Using context to make it unique - should succeed
    const old_str_with_context = "fn setup() void {\n    const x = 0;";
    const new_str = "fn setup() void {\n    const z = 1;";
    
    const result = try text_replace_mod.text_replace(allocator, test_path, old_str_with_context, new_str, read_result.sha256);
    defer result.deinit(allocator);
    
    // Verify file was modified correctly
    const file = try std.fs.cwd().openFile(test_path, .{});
    defer file.close();
    const read_content = try file.readToEndAlloc(allocator, std.math.maxInt(usize));
    defer allocator.free(read_content);
    
    // First occurrence should be replaced, second should remain
    try std.testing.expect(std.mem.indexOf(u8, read_content, "const z = 1;") != null);
    try std.testing.expect(std.mem.indexOf(u8, read_content, "const x = 0;") != null);
    
    // Clean up
    try std.fs.cwd().deleteFile(test_path);
}

test "text_replace - multiline replace" {
    const allocator = std.testing.allocator;
    const test_path = "test_replace_multiline.txt";
    const original_content = "start\nold line 1\nold line 2\nend\n";
    
    // Create original file
    const orig_file = try std.fs.cwd().createFile(test_path, .{});
    defer orig_file.close();
    try orig_file.writeAll(original_content);
    
    // Get the hash from read_file
    const read_result = try read_file_mod.read_file(allocator, test_path, .{});
    defer read_result.deinit(allocator);
    
    const result = try text_replace_mod.text_replace(allocator, test_path, "old line 1\nold line 2", "new line A\nnew line B", read_result.sha256);
    defer result.deinit(allocator);
    
    // Verify content
    const file = try std.fs.cwd().openFile(test_path, .{});
    defer file.close();
    const read_content = try file.readToEndAlloc(allocator, std.math.maxInt(usize));
    defer allocator.free(read_content);
    
    const expected = "start\nnew line A\nnew line B\nend\n";
    try std.testing.expectEqualStrings(expected, read_content);
    
    // Clean up
    try std.fs.cwd().deleteFile(test_path);
}

test "text_replace - replace at end of file" {
    const allocator = std.testing.allocator;
    const test_path = "test_replace_end.txt";
    const original_content = "start\nend";
    
    // Create original file
    const orig_file = try std.fs.cwd().createFile(test_path, .{});
    defer orig_file.close();
    try orig_file.writeAll(original_content);
    
    // Get the hash from read_file
    const read_result = try read_file_mod.read_file(allocator, test_path, .{});
    defer read_result.deinit(allocator);
    
    const result = try text_replace_mod.text_replace(allocator, test_path, "end", "FINISH", read_result.sha256);
    defer result.deinit(allocator);
    
    // Verify replaced_at_byte points to end
    try std.testing.expectEqual(@as(usize, 6), result.replaced_at_byte);
    
    // Verify content
    const file = try std.fs.cwd().openFile(test_path, .{});
    defer file.close();
    const read_content = try file.readToEndAlloc(allocator, std.math.maxInt(usize));
    defer allocator.free(read_content);
    
    const expected = "start\nFINISH";
    try std.testing.expectEqualStrings(expected, read_content);
    
    // Clean up
    try std.fs.cwd().deleteFile(test_path);
}
