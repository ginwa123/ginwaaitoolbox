const std = @import("std");
const fs = std.fs;

/// Tests for sandbox creation functionality in session_create handler
/// These tests verify the getDataAppsDir and createSandbox helper functions.

/// Helper function being tested (copied from session_create.zig for testing)
fn getDataAppsDir(allocator: std.mem.Allocator) ![]u8 {
    const home = std.posix.getenv("HOME") orelse {
        return error.HomeNotFound;
    };
    return std.fs.path.join(allocator, &[_][]const u8{
        home,
        ".local",
        "share",
        "nalar",
        "data",
        "apps",
    });
}

/// Helper function being tested (copied from session_create.zig for testing)
fn createSandbox(allocator: std.mem.Allocator, session_id: []const u8) ![]u8 {
    const data_apps_dir = try getDataAppsDir(allocator);
    defer allocator.free(data_apps_dir);

    // Create the data/apps directory and all parent directories if they don't exist
    try std.fs.cwd().makePath(data_apps_dir);

    // Generate a unique folder name using session_id
    const sandbox_name = try allocator.dupe(u8, session_id);
    errdefer allocator.free(sandbox_name);

    const sandbox_path = try std.fs.path.join(allocator, &[_][]const u8{
        data_apps_dir,
        sandbox_name,
    });
    errdefer allocator.free(sandbox_path);

    // Create the sandbox directory (ignore if already exists)
    std.fs.makeDirAbsolute(sandbox_path) catch |err| {
        if (err != error.PathAlreadyExists) {
            return err;
        }
    };

    return sandbox_path;
}

test "getDataAppsDir returns correct path" {
    const allocator = std.testing.allocator;
    const home = std.posix.getenv("HOME") orelse {
        return error.SkipZigTest;
    };

    const expected_path = try std.fs.path.join(allocator, &[_][]const u8{
        home,
        ".local",
        "share",
        "nalar",
        "data",
        "apps",
    });
    defer allocator.free(expected_path);

    const result = try getDataAppsDir(allocator);
    defer allocator.free(result);

    try std.testing.expectEqualStrings(expected_path, result);
}

test "getDataAppsDir fails when HOME is not set" {
    // If HOME is not set, getDataAppsDir should fail with HomeNotFound
    if (std.posix.getenv("HOME") == null) {
        const result = getDataAppsDir(std.testing.allocator);
        try std.testing.expectError(error.HomeNotFound, result);
    }
    // If HOME is set, this test is skipped (not applicable)
}

test "createSandbox creates directory in data/apps" {
    const allocator = std.testing.allocator;
    const test_session_id = "test-sandbox-session-123";

    // Get the expected sandbox path
    const data_apps_dir = try getDataAppsDir(allocator);
    defer allocator.free(data_apps_dir);

    const expected_sandbox_path = try std.fs.path.join(allocator, &[_][]const u8{
        data_apps_dir,
        test_session_id,
    });
    defer allocator.free(expected_sandbox_path);

    // Create the sandbox
    const sandbox_path = try createSandbox(allocator, test_session_id);
    defer allocator.free(sandbox_path);

    // Verify the path is correct
    try std.testing.expectEqualStrings(expected_sandbox_path, sandbox_path);

    // Verify the directory exists - just try to open it, if it fails the test fails
    _ = fs.openDirAbsolute(sandbox_path, .{ .iterate = true }) catch return error.DirectoryNotFound;

    // Clean up - remove the test sandbox
    try fs.deleteDirAbsolute(sandbox_path);
}

test "createSandbox uses session_id as folder name" {
    const allocator = std.testing.allocator;
    const test_session_id = "my-unique-session-id-456";

    const sandbox_path = try createSandbox(allocator, test_session_id);
    defer allocator.free(sandbox_path);

    // Check that the folder name is the session_id
    const folder_name = fs.path.basename(sandbox_path);
    try std.testing.expectEqualStrings(test_session_id, folder_name);

    // Clean up
    try fs.deleteDirAbsolute(sandbox_path);
}

test "createSandbox is idempotent (directory already exists)" {
    const allocator = std.testing.allocator;
    const test_session_id = "idempotent-test-session-789";

    // Create sandbox first time
    const sandbox_path1 = try createSandbox(allocator, test_session_id);
    defer allocator.free(sandbox_path1);

    // Create sandbox second time - should not fail (error.PathAlreadyExists is handled)
    const sandbox_path2 = try createSandbox(allocator, test_session_id);
    defer allocator.free(sandbox_path2);

    // Both should return the same path
    try std.testing.expectEqualStrings(sandbox_path1, sandbox_path2);

    // Clean up
    try fs.deleteDirAbsolute(sandbox_path1);
}
