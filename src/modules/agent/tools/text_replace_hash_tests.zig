const std = @import("std");
const text_replace_mod = @import("text_replace.zig");
const read_file_mod = @import("read_file.zig");

// ============================================
// HASH GUARD TESTS FOR text_replace
// ============================================

test "text_replace - accepts expected_hash parameter" {
    const allocator = std.testing.allocator;
    const test_path = "test_hash_accept.txt";
    const original_content = "Hello, World!\n";
    const old_str = "Hello";
    const new_str = "Goodbye";
    
    // Create original file
    const orig_file = try std.fs.cwd().createFile(test_path, .{});
    defer orig_file.close();
    try orig_file.writeAll(original_content);
    
    // First read to get the hash
    const read_result = try read_file_mod.read_file(allocator, test_path, .{});
    defer read_result.deinit(allocator);
    
    // Now edit with the correct hash
    const result = try text_replace_mod.text_replace(allocator, test_path, old_str, new_str, read_result.sha256);
    defer result.deinit(allocator);
    
    // Verify success - should have both sha256_before and sha256_after
    try std.testing.expect(result.sha256_before.len > 0);
    try std.testing.expect(result.sha256_after.len > 0);
    try std.testing.expectEqualStrings(read_result.sha256, result.sha256_before);
    
    // Clean up
    try std.fs.cwd().deleteFile(test_path);
}

test "text_replace - rejects mismatched hash" {
    const allocator = std.testing.allocator;
    const test_path = "test_hash_mismatch.txt";
    const original_content = "Hello, World!\n";
    const old_str = "Hello";
    const new_str = "Goodbye";
    const wrong_hash = "this_is_not_the_correct_hash_12345678901234567890123456789012";
    
    // Create original file
    const orig_file = try std.fs.cwd().createFile(test_path, .{});
    defer orig_file.close();
    try orig_file.writeAll(original_content);
    
    // Try to edit with wrong hash - should fail
    const result = text_replace_mod.text_replace(allocator, test_path, old_str, new_str, wrong_hash);
    
    try std.testing.expectError(text_replace_mod.TextReplaceError.HashMismatch, result);
    
    // Clean up
    try std.fs.cwd().deleteFile(test_path);
}

test "text_replace - rejects if file changed between read and edit" {
    const allocator = std.testing.allocator;
    const test_path = "test_hash_concurrent.txt";
    const original_content = "Hello, World!\n";
    const old_str = "Hello";
    const new_str = "Goodbye";
    
    // Create original file
    {
        const orig_file = try std.fs.cwd().createFile(test_path, .{});
        defer orig_file.close();
        try orig_file.writeAll(original_content);
    }
    
    // Agent reads file and gets hash
    const read_result = try read_file_mod.read_file(allocator, test_path, .{});
    defer read_result.deinit(allocator);
    
    // Simulate another process/agent editing the file
    {
        const mod_file = try std.fs.cwd().createFile(test_path, .{});
        defer mod_file.close();
        try mod_file.writeAll("Different content\n");
    }
    
    // Now try to edit with the old hash - should fail
    const result = text_replace_mod.text_replace(allocator, test_path, old_str, new_str, read_result.sha256);
    
    try std.testing.expectError(text_replace_mod.TextReplaceError.HashMismatch, result);
    
    // Clean up
    try std.fs.cwd().deleteFile(test_path);
}

test "text_replace - result serialization includes hashes" {
    const allocator = std.testing.allocator;
    const test_path = "test_hash_serialize.txt";
    const original_content = "test content\n";
    
    // Create original file
    const orig_file = try std.fs.cwd().createFile(test_path, .{});
    defer orig_file.close();
    try orig_file.writeAll(original_content);
    
    // First read to get the hash
    const read_result = try read_file_mod.read_file(allocator, test_path, .{});
    defer read_result.deinit(allocator);
    
    // Edit with the correct hash
    const result = try text_replace_mod.text_replace(allocator, test_path, "test", "new", read_result.sha256);
    defer result.deinit(allocator);
    
    const serialized = try text_replace_mod.textReplaceToString(allocator, result);
    defer allocator.free(serialized);
    
    // Should contain SHA256 fields
    try std.testing.expect(std.mem.indexOf(u8, serialized, "<sha256_before>") != null);
    try std.testing.expect(std.mem.indexOf(u8, serialized, "<sha256_after>") != null);
    
    // Clean up
    try std.fs.cwd().deleteFile(test_path);
}

test "text_replace - different hash before and after edit" {
    const allocator = std.testing.allocator;
    const test_path = "test_hash_change.txt";
    const original_content = "Hello, World!\n";
    const old_str = "Hello";
    const new_str = "Goodbye";
    
    // Create original file
    const orig_file = try std.fs.cwd().createFile(test_path, .{});
    defer orig_file.close();
    try orig_file.writeAll(original_content);
    
    // First read to get the hash
    const read_result = try read_file_mod.read_file(allocator, test_path, .{});
    defer read_result.deinit(allocator);
    
    // Edit with the correct hash
    const result = try text_replace_mod.text_replace(allocator, test_path, old_str, new_str, read_result.sha256);
    defer result.deinit(allocator);
    
    // Before and after hashes should be different
    try std.testing.expect(!std.mem.eql(u8, result.sha256_before, result.sha256_after));
    
    // Clean up
    try std.fs.cwd().deleteFile(test_path);
}
