const std = @import("std");
const read_file = @import("read_file.zig");

test "read_file - basic read" {
    const allocator = std.testing.allocator;

    const test_content = "Line 1\nLine 2\n";
    const temp_path = "/tmp/read_file_basic_test.txt";
    try std.fs.cwd().writeFile(.{
        .sub_path = temp_path,
        .data = test_content,
    });
    defer std.fs.cwd().deleteFile(temp_path) catch {};

    const result = try read_file.read_file(allocator, temp_path, .{});
    defer result.deinit(allocator);

    try std.testing.expect(result.content.len > 0);
    try std.testing.expect(result.total_lines == 2);
}

test "read_file - with pagination" {
    const allocator = std.testing.allocator;

    const test_content = "Line 1\nLine 2\nLine 3\nLine 4\nLine 5\n";
    const temp_path = "/tmp/read_file_paginate_test.txt";
    try std.fs.cwd().writeFile(.{
        .sub_path = temp_path,
        .data = test_content,
    });
    defer std.fs.cwd().deleteFile(temp_path) catch {};

    const result = try read_file.read_file(allocator, temp_path, .{
        .offset = 1,
        .limit = 2,
    });
    defer result.deinit(allocator);

    try std.testing.expect(result.total_lines == 5);
    try std.testing.expect(result.start_line == 1);
}

test "read_file - show line numbers" {
    const allocator = std.testing.allocator;

    const test_content = "Line 1\nLine 2\n";
    const temp_path = "/tmp/read_file_linenums_test.txt";
    try std.fs.cwd().writeFile(.{
        .sub_path = temp_path,
        .data = test_content,
    });
    defer std.fs.cwd().deleteFile(temp_path) catch {};

    const result = try read_file.read_file(allocator, temp_path, .{
        .show_line_numbers = true,
    });
    defer result.deinit(allocator);

    // Content should have some prefix (line number) + original line
    try std.testing.expect(result.content.len > 8); // "    1\t" + "Line 1\n"
}
