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

test "text_replace_batch - sequential special char replacements" {
    const allocator = std.testing.allocator;
    const test_path = "test_batch_special_chars.txt";
    const original_content = "a\\b\\c";
    
    // Create original file
    const orig_file = try std.fs.cwd().createFile(test_path, .{});
    defer orig_file.close();
    try orig_file.writeAll(original_content);
    
    const read_result = try read_file_mod.read_file(allocator, test_path, .{});
    defer read_result.deinit(allocator);
    
    // Sequential replacements: a->X, b->Y, c->Z
    // Order matters - should replace sequentially without interference
    const ops = &.{
        TextReplaceOp{ .old_str = "a", .new_str = "X" },
        TextReplaceOp{ .old_str = "b", .new_str = "Y" },
        TextReplaceOp{ .old_str = "c", .new_str = "Z" },
    };
    
    const result = try text_replace_batch(allocator, test_path, ops, read_result.sha256);
    defer result.deinit(allocator);
    
    // Verify file content
    const file = try std.fs.cwd().openFile(test_path, .{});
    defer file.close();
    const read_content = try file.readToEndAlloc(allocator, std.math.maxInt(usize));
    defer allocator.free(read_content);
    
    const expected = "X\\Y\\Z";
    try std.testing.expectEqualStrings(expected, read_content);
    
    // Clean up
    try std.fs.cwd().deleteFile(test_path);
}

test "text_replace_batch - special chars becoming special" {
    const allocator = std.testing.allocator;
    const test_path = "test_batch_special_replacement.txt";
    const original_content = "hello";
    
    // Create original file
    const orig_file = try std.fs.cwd().createFile(test_path, .{});
    defer orig_file.close();
    try orig_file.writeAll(original_content);
    
    const read_result = try read_file_mod.read_file(allocator, test_path, .{});
    defer read_result.deinit(allocator);
    
    // Replacement contains a backslash - should work correctly
    const ops = &.{
        TextReplaceOp{ .old_str = "hello", .new_str = "hel\\lo" },
    };
    
    const result = try text_replace_batch(allocator, test_path, ops, read_result.sha256);
    defer result.deinit(allocator);
    
    // Verify file content
    const file = try std.fs.cwd().openFile(test_path, .{});
    defer file.close();
    const read_content = try file.readToEndAlloc(allocator, std.math.maxInt(usize));
    defer allocator.free(read_content);
    
    const expected = "hel\\lo";
    try std.testing.expectEqualStrings(expected, read_content);
    
    // Clean up
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

test "text_replace_batch - multiple backslashes" {
    const allocator = std.testing.allocator;
    const test_path = "test_batch_backslashes.txt";
    // In Zig strings, \\ represents a single backslash
    // Test single backslash replacement (old_str must be unique per implementation)
    const original_content = "a\\b";
    
    const orig_file = try std.fs.cwd().createFile(test_path, .{});
    defer orig_file.close();
    try orig_file.writeAll(original_content);
    
    const read_result = try read_file_mod.read_file(allocator, test_path, .{});
    defer read_result.deinit(allocator);
    
    // Replace single backslash with forward slash
    const ops = &.{
        TextReplaceOp{ .old_str = "\\", .new_str = "/" },
    };
    
    const result = try text_replace_batch(allocator, test_path, ops, read_result.sha256);
    defer result.deinit(allocator);
    
    const file = try std.fs.cwd().openFile(test_path, .{});
    defer file.close();
    const read_content = try file.readToEndAlloc(allocator, std.math.maxInt(usize));
    defer allocator.free(read_content);
    
    // Single backslash replaced with forward slash
    try std.testing.expectEqualStrings("a/b", read_content);
    
    try std.fs.cwd().deleteFile(test_path);
}

test "text_replace_batch - multiple quotes" {
    const allocator = std.testing.allocator;
    const test_path = "test_batch_quotes.txt";
    const original_content = "\"a\" \"b\" \"c\"";
    
    const orig_file = try std.fs.cwd().createFile(test_path, .{});
    defer orig_file.close();
    try orig_file.writeAll(original_content);
    
    const read_result = try read_file_mod.read_file(allocator, test_path, .{});
    defer read_result.deinit(allocator);
    
    // Replace first quoted item only
    const ops = &.{
        TextReplaceOp{ .old_str = "\"a\"", .new_str = "'x'" },
    };
    
    const result = try text_replace_batch(allocator, test_path, ops, read_result.sha256);
    defer result.deinit(allocator);
    
    const file = try std.fs.cwd().openFile(test_path, .{});
    defer file.close();
    const read_content = try file.readToEndAlloc(allocator, std.math.maxInt(usize));
    defer allocator.free(read_content);
    
    try std.testing.expectEqualStrings("'x' \"b\" \"c\"", read_content);
    
    try std.fs.cwd().deleteFile(test_path);
}

test "text_replace_batch - mixed special chars" {
    const allocator = std.testing.allocator;
    const test_path = "test_batch_mixed_special.txt";
    // URL with backslash paths: http://example.com/path\to\file
    const original_content = "http://example.com/path\\to\\file";
    
    const orig_file = try std.fs.cwd().createFile(test_path, .{});
    defer orig_file.close();
    try orig_file.writeAll(original_content);
    
    const read_result = try read_file_mod.read_file(allocator, test_path, .{});
    defer read_result.deinit(allocator);
    
    // Replace domain but preserve backslash paths
    const ops = &.{
        TextReplaceOp{ .old_str = "http://example.com", .new_str = "https://localhost" },
    };
    
    const result = try text_replace_batch(allocator, test_path, ops, read_result.sha256);
    defer result.deinit(allocator);
    
    const file = try std.fs.cwd().openFile(test_path, .{});
    defer file.close();
    const read_content = try file.readToEndAlloc(allocator, std.math.maxInt(usize));
    defer allocator.free(read_content);
    
    // Domain changed, but backslash paths preserved
    try std.testing.expectEqualStrings("https://localhost/path\\to\\file", read_content);
    
    try std.fs.cwd().deleteFile(test_path);
}

test "text_replace_batch - newlines" {
    const allocator = std.testing.allocator;
    const test_path = "test_batch_newlines.txt";
    // Use single newline to ensure pattern is unique
    const original_content = "line1\nline2line3";
    
    const orig_file = try std.fs.cwd().createFile(test_path, .{});
    defer orig_file.close();
    try orig_file.writeAll(original_content);
    
    const read_result = try read_file_mod.read_file(allocator, test_path, .{});
    defer read_result.deinit(allocator);
    
    const ops = &.{
        TextReplaceOp{ .old_str = "\n", .new_str = "\r\n" },
    };
    
    const result = try text_replace_batch(allocator, test_path, ops, read_result.sha256);
    defer result.deinit(allocator);
    
    const file = try std.fs.cwd().openFile(test_path, .{});
    defer file.close();
    const read_content = try file.readToEndAlloc(allocator, std.math.maxInt(usize));
    defer allocator.free(read_content);
    
    const expected = "line1\r\nline2line3";
    try std.testing.expectEqualStrings(expected, read_content);
    
    try std.fs.cwd().deleteFile(test_path);
}

test "text_replace_batch - tabs" {
    const allocator = std.testing.allocator;
    const test_path = "test_batch_tabs.txt";
    // Use single tab to ensure pattern is unique
    const original_content = "col1\tcol2col3";
    
    const orig_file = try std.fs.cwd().createFile(test_path, .{});
    defer orig_file.close();
    try orig_file.writeAll(original_content);
    
    const read_result = try read_file_mod.read_file(allocator, test_path, .{});
    defer read_result.deinit(allocator);
    
    const ops = &.{
        TextReplaceOp{ .old_str = "\t", .new_str = "    " },
    };
    
    const result = try text_replace_batch(allocator, test_path, ops, read_result.sha256);
    defer result.deinit(allocator);
    
    const file = try std.fs.cwd().openFile(test_path, .{});
    defer file.close();
    const read_content = try file.readToEndAlloc(allocator, std.math.maxInt(usize));
    defer allocator.free(read_content);
    
    const expected = "col1    col2col3";
    try std.testing.expectEqualStrings(expected, read_content);
    
    try std.fs.cwd().deleteFile(test_path);
}

test "text_replace_batch - carriage return" {
    const allocator = std.testing.allocator;
    const test_path = "test_batch_carriage_return.txt";
    const original_content = "Windows\r\nFile";
    
    const orig_file = try std.fs.cwd().createFile(test_path, .{});
    defer orig_file.close();
    try orig_file.writeAll(original_content);
    
    const read_result = try read_file_mod.read_file(allocator, test_path, .{});
    defer read_result.deinit(allocator);
    
    const ops = &.{
        TextReplaceOp{ .old_str = "\r\n", .new_str = "\n" },
    };
    
    const result = try text_replace_batch(allocator, test_path, ops, read_result.sha256);
    defer result.deinit(allocator);
    
    const file = try std.fs.cwd().openFile(test_path, .{});
    defer file.close();
    const read_content = try file.readToEndAlloc(allocator, std.math.maxInt(usize));
    defer allocator.free(read_content);
    
    const expected = "Windows\nFile";
    try std.testing.expectEqualStrings(expected, read_content);
    
    try std.fs.cwd().deleteFile(test_path);
}
