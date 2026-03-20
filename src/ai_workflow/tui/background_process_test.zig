const std = @import("std");

// Test struct definition directly - avoids importing modules with relative imports
const ProcessInfo = struct {
    session_id: []const u8,
    pid: u32,
    command: []const u8,
    log_path: []const u8,
    started_at: i64,
    status: []const u8,
};

// Direct implementations of functions we want to test (copied from background_process.zig for testing)
fn isProcessRunning(pid: u32) bool {
    // kill(pid, 0) returns error or void - check if process exists
    std.posix.kill(@intCast(pid), 0) catch return false;
    return true;
}

fn killProcess(pid: u32) bool {
    // Try SIGTERM first (15)
    std.posix.kill(@intCast(pid), 15) catch {
        // If SIGTERM fails, try SIGKILL (9)
        std.posix.kill(@intCast(pid), 9) catch return false;
        return true;
    };
    return true;
}

test "ProcessInfo struct fields" {
    const info = ProcessInfo{
        .session_id = "test-session",
        .pid = 12345,
        .command = "echo hello",
        .log_path = "/tmp/test.log",
        .started_at = 1234567890,
        .status = "running",
    };

    try std.testing.expectEqualStrings("test-session", info.session_id);
    try std.testing.expectEqual(@as(u32, 12345), info.pid);
    try std.testing.expectEqualStrings("echo hello", info.command);
    try std.testing.expectEqualStrings("/tmp/test.log", info.log_path);
    try std.testing.expectEqual(@as(i64, 1234567890), info.started_at);
    try std.testing.expectEqualStrings("running", info.status);
}

test "isProcessRunning with non-existent PID" {
    // Use a very high PID that definitely doesn't exist
    const result = isProcessRunning(999999999);
    try std.testing.expectEqual(false, result);
}

test "killProcess with non-existent PID" {
    // Try to kill a PID that doesn't exist - should return false
    const result = killProcess(999999999);
    try std.testing.expectEqual(false, result);
}
