const std = @import("std");
const read_file = @import("read_file.zig");

test "hash_only returns only hash without content" {
    const allocator = std.testing.allocator;

    // Create a temp file with known content
    const test_content = "Hello, World!\n";
    const temp_path = "/tmp/read_file_hash_only_test.txt";
    try std.fs.cwd().writeFile(.{
        .sub_path = temp_path,
        .data = test_content,
    });
    defer std.fs.cwd().deleteFile(temp_path) catch {};

    // Test with hash_only = true
    const opts = read_file.ReadFileOptions{
        .hash_only = true,
    };

    const result = try read_file.read_file(allocator, temp_path, opts);
    defer result.deinit(allocator);

    // Hash should be present (64 hex chars for SHA256)
    try std.testing.expect(result.sha256.len == 64);

    // Content should be empty when hash_only
    try std.testing.expect(result.content.len == 0);

    // Line info should be zero
    try std.testing.expect(result.total_lines == 0);
    try std.testing.expect(result.start_line == 0);
    try std.testing.expect(result.end_line == 0);

    // Verify hash is valid hex string
    for (result.sha256) |c| {
        const is_hex = (c >= '0' and c <= '9') or (c >= 'a' and c <= 'f');
        try std.testing.expect(is_hex);
    }
}

test "hash_only false returns full content as normal" {
    const allocator = std.testing.allocator;

    const test_content = "Line 1\nLine 2\n";
    const temp_path = "/tmp/read_file_hash_only_false_test.txt";
    try std.fs.cwd().writeFile(.{
        .sub_path = temp_path,
        .data = test_content,
    });
    defer std.fs.cwd().deleteFile(temp_path) catch {};

    // Test with hash_only = false (default)
    const opts = read_file.ReadFileOptions{
        .hash_only = false,
    };

    const result = try read_file.read_file(allocator, temp_path, opts);
    defer result.deinit(allocator);

    // Hash should still be present
    try std.testing.expect(result.sha256.len == 64);

    // Content should NOT be empty
    try std.testing.expect(result.content.len > 0);

    // Line info should be correct
    try std.testing.expect(result.total_lines == 2);
}
