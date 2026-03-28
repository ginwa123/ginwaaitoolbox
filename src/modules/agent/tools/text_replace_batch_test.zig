const std = @import("std");
const text_replace_mod = @import("text_replace.zig");
const read_file_mod = @import("read_file.zig");

// Convenience type aliases
const TextReplaceOp = text_replace_mod.TextReplaceOp;
const TextReplaceBatchResult = text_replace_mod.TextReplaceBatchResult;
const text_replace_batch = text_replace_mod.text_replace_batch;

test "text_replace_batch - applies multiple replacements" {
    const allocator = std.testing.allocator;
    const test_path = "test_batch_basic.txt";
    const original_content = "Hello World!\nGoodbye World!\n";
    
    // Create original file
    const orig_file = try std.fs.cwd().createFile(test_path, .{});
    defer orig_file.close();
    try orig_file.writeAll(original_content);
    
    const read_result = try read_file_mod.read_file(allocator, test_path, .{});
    defer read_result.deinit(allocator);
    
    const ops = &.{
        TextReplaceOp{ .old_str = "Hello", .new_str = "Hi" },
        TextReplaceOp{ .old_str = "Goodbye", .new_str = "Cya" },
    };
    
    const result = try text_replace_batch(allocator, test_path, ops, read_result.sha256);
    defer result.deinit(allocator);
    
    // Verify file content
    const file = try std.fs.cwd().openFile(test_path, .{});
    defer file.close();
    const read_content = try file.readToEndAlloc(allocator, std.math.maxInt(usize));
    defer allocator.free(read_content);
    
    const expected = "Hi World!\nCya World!\n";
    try std.testing.expectEqualStrings(expected, read_content);
    
    // Clean up
    try std.fs.cwd().deleteFile(test_path);
}

test "text_replace_batch - single operation" {
    const allocator = std.testing.allocator;
    const test_path = "test_batch_single.txt";
    const original_content = "Hello World!\n";
    
    const orig_file = try std.fs.cwd().createFile(test_path, .{});
    defer orig_file.close();
    try orig_file.writeAll(original_content);
    
    const read_result = try read_file_mod.read_file(allocator, test_path, .{});
    defer read_result.deinit(allocator);
    
    const ops = &.{
        TextReplaceOp{ .old_str = "Hello", .new_str = "Hi" },
    };
    
    const result = try text_replace_batch(allocator, test_path, ops, read_result.sha256);
    defer result.deinit(allocator);
    
    const file = try std.fs.cwd().openFile(test_path, .{});
    defer file.close();
    const read_content = try file.readToEndAlloc(allocator, std.math.maxInt(usize));
    defer allocator.free(read_content);
    
    const expected = "Hi World!\n";
    try std.testing.expectEqualStrings(expected, read_content);
    
    try std.fs.cwd().deleteFile(test_path);
}

test "text_replace_batch - empty operations" {
    const allocator = std.testing.allocator;
    const test_path = "test_batch_empty.txt";
    const original_content = "Hello World!\n";
    
    const orig_file = try std.fs.cwd().createFile(test_path, .{});
    defer orig_file.close();
    try orig_file.writeAll(original_content);
    
    const read_result = try read_file_mod.read_file(allocator, test_path, .{});
    defer read_result.deinit(allocator);
    
    const ops: []const TextReplaceOp = &.{};
    
    const result = try text_replace_batch(allocator, test_path, ops, read_result.sha256);
    defer result.deinit(allocator);
    
    const file = try std.fs.cwd().openFile(test_path, .{});
    defer file.close();
    const read_content = try file.readToEndAlloc(allocator, std.math.maxInt(usize));
    defer allocator.free(read_content);
    
    // Should be unchanged
    try std.testing.expectEqualStrings(original_content, read_content);
    
    try std.fs.cwd().deleteFile(test_path);
}

test "text_replace_batch - rejects mismatched hash" {
    const allocator = std.testing.allocator;
    const test_path = "test_batch_hash_mismatch.txt";
    const original_content = "Hello World!\n";
    
    const orig_file = try std.fs.cwd().createFile(test_path, .{});
    defer orig_file.close();
    try orig_file.writeAll(original_content);
    
    const ops = &.{
        TextReplaceOp{ .old_str = "Hello", .new_str = "Hi" },
    };
    
    // Wrong hash should fail
    const result = text_replace_batch(allocator, test_path, ops, "wrong_hash");
    
    try std.testing.expectError(text_replace_mod.TextReplaceError.HashMismatch, result);
    
    // File should be unchanged
    const file = try std.fs.cwd().openFile(test_path, .{});
    defer file.close();
    const read_content = try file.readToEndAlloc(allocator, std.math.maxInt(usize));
    defer allocator.free(read_content);
    
    try std.testing.expectEqualStrings(original_content, read_content);
    
    try std.fs.cwd().deleteFile(test_path);
}
