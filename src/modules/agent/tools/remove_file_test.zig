const std = @import("std");
const remove_file = @import("remove_file.zig");

test "execute_remove_file - empty path returns error" {
    const allocator = std.testing.allocator;
    const input = remove_file.RemoveFileInput{ .path = "" };
    const result = try remove_file.execute_remove_file_to_string(allocator, input);
    defer allocator.free(result);

    try std.testing.expect(std.mem.indexOf(u8, result, "<deleted>false</deleted>") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "path cannot be empty") != null);
}

test "execute_remove_file - non-existent path returns error" {
    const allocator = std.testing.allocator;
    const input = remove_file.RemoveFileInput{ .path = "/tmp/nonexistent_12345.txt" };
    const result = try remove_file.execute_remove_file_to_string(allocator, input);
    defer allocator.free(result);

    try std.testing.expect(std.mem.indexOf(u8, result, "<deleted>false</deleted>") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "Path not found") != null);
}

test "execute_remove_file - deletes existing file" {
    const allocator = std.testing.allocator;
    const test_path = "/tmp/remove_file_test_12345.txt";

    const file = try std.fs.cwd().createFile(test_path, .{});
    file.close();

    const input = remove_file.RemoveFileInput{ .path = test_path };
    const result = try remove_file.execute_remove_file_to_string(allocator, input);
    defer allocator.free(result);

    try std.testing.expect(std.mem.indexOf(u8, result, "<deleted>true</deleted>") != null);

    // Verify file is actually deleted
    try std.testing.expectError(error.FileNotFound, std.fs.cwd().openFile(test_path, .{}));
}

test "execute_remove_file - cannot delete directory without recursive" {
    const allocator = std.testing.allocator;
    const test_dir = "/tmp/remove_file_dir_12345";
    try std.fs.cwd().makeDir(test_dir);
    defer _ = std.fs.cwd().deleteDir(test_dir) catch {};

    const input = remove_file.RemoveFileInput{ .path = test_dir };
    const result = try remove_file.execute_remove_file_to_string(allocator, input);
    defer allocator.free(result);

    try std.testing.expect(std.mem.indexOf(u8, result, "<deleted>false</deleted>") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "Path is a directory") != null);

    // Verify directory still exists
    try std.testing.expectError(error.PathAlreadyExists, std.fs.cwd().makeDir(test_dir));
}

test "execute_remove_file - recursive deletes empty directory" {
    const allocator = std.testing.allocator;
    const test_dir = "/tmp/remove_file_recursive_dir_12345";
    try std.fs.cwd().makeDir(test_dir);
    defer _ = std.fs.cwd().deleteDir(test_dir) catch {};

    const input = remove_file.RemoveFileInput{ .path = test_dir, .recursive = true };
    const result = try remove_file.execute_remove_file_to_string(allocator, input);
    defer allocator.free(result);

    try std.testing.expect(std.mem.indexOf(u8, result, "<deleted>true</deleted>") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "<recursive>true</recursive>") != null);

    // Verify directory is deleted
    try std.testing.expectError(error.FileNotFound, std.fs.cwd().openDir(test_dir, .{}));
}

test "execute_remove_file - recursive deletes directory with files inside" {
    const allocator = std.testing.allocator;
    const test_dir = "/tmp/remove_file_recursive_test_12345";
    const file1_path = test_dir ++ "/file1.txt";
    const file2_path = test_dir ++ "/file2.txt";

    // Create directory with files inside
    try std.fs.cwd().makeDir(test_dir);
    defer _ = std.fs.cwd().deleteTree(test_dir) catch {};

    const file1 = try std.fs.cwd().createFile(file1_path, .{});
    file1.close();
    const file2 = try std.fs.cwd().createFile(file2_path, .{});
    file2.close();

    const input = remove_file.RemoveFileInput{ .path = test_dir, .recursive = true };
    const result = try remove_file.execute_remove_file_to_string(allocator, input);
    defer allocator.free(result);

    try std.testing.expect(std.mem.indexOf(u8, result, "<deleted>true</deleted>") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "<recursive>true</recursive>") != null);

    // Verify directory and files are deleted
    try std.testing.expectError(error.FileNotFound, std.fs.cwd().openDir(test_dir, .{}));
}

test "execute_remove_file - recursive deletes nested directory" {
    const allocator = std.testing.allocator;
    const test_dir = "/tmp/remove_file_nested_test_12345";
    const nested_dir = test_dir ++ "/subdir/nested";
    const file_path = nested_dir ++ "/deep_file.txt";

    // Create nested structure
    try std.fs.cwd().makePath(nested_dir);
    defer _ = std.fs.cwd().deleteTree(test_dir) catch {};

    const file = try std.fs.cwd().createFile(file_path, .{});
    file.close();

    const input = remove_file.RemoveFileInput{ .path = test_dir, .recursive = true };
    const result = try remove_file.execute_remove_file_to_string(allocator, input);
    defer allocator.free(result);

    try std.testing.expect(std.mem.indexOf(u8, result, "<deleted>true</deleted>") != null);

    // Verify everything is deleted
    try std.testing.expectError(error.FileNotFound, std.fs.cwd().openDir(test_dir, .{}));
}
