const std = @import("std");
const testing = std.testing;
const builtin = @import("builtin");
const notifications = @import("notifications.zig");

// ---------------------------------------------------------------------------
// truncateBody: pure helper, no OS-specific code
// ---------------------------------------------------------------------------

test "truncateBody returns input unchanged when shorter than max" {
    const allocator = testing.allocator;
    {
        const result = try notifications.truncateBody(allocator, "hello", 140);
        defer allocator.free(result);
        try testing.expectEqualStrings("hello", result);
    }
    {
        const result = try notifications.truncateBody(allocator, "", 140);
        defer allocator.free(result);
        try testing.expectEqualStrings("", result);
    }
}

test "truncateBody cuts to max-1 chars and appends an ellipsis" {
    const allocator = testing.allocator;
    var long: [500]u8 = undefined;
    @memset(&long, 'x');
    const result = try notifications.truncateBody(allocator, &long, 10);
    defer allocator.free(result);
    try testing.expectEqual(@as(usize, 10), result.len);
    try testing.expect(std.mem.endsWith(u8, result, "…"));
}

test "truncateBody at the boundary returns the original (no ellipsis)" {
    const allocator = testing.allocator;
    var input_buf: [140]u8 = undefined;
    @memset(&input_buf, 'x');
    const result = try notifications.truncateBody(allocator, &input_buf, 140);
    defer allocator.free(result);
    try testing.expectEqual(@as(usize, 140), result.len);
    try testing.expectEqualStrings(&input_buf, result);
}

// ---------------------------------------------------------------------------
// buildCommand: per-OS argv construction (skipped on non-matching OS)
// ---------------------------------------------------------------------------

test "buildCommand on Linux returns notify-send as the first arg" {
    if (builtin.os.tag != .linux) return;
    const allocator = testing.allocator;
    const cmd = try notifications.buildCommand(allocator, "Title", "Body text");
    defer {
        for (cmd) |arg| allocator.free(arg);
        allocator.free(cmd);
    }
    try testing.expect(cmd.len >= 4);
    try testing.expectEqualStrings("notify-send", cmd[0]);
    try testing.expectEqualStrings("--app-name=nalar", cmd[1]);
    try testing.expectEqualStrings("Title", cmd[2]);
    try testing.expectEqualStrings("Body text", cmd[3]);
}

test "buildCommand on macOS returns osascript with display notification script" {
    if (builtin.os.tag != .macos) return;
    const allocator = testing.allocator;
    const cmd = try notifications.buildCommand(allocator, "Title", "Body");
    defer {
        for (cmd) |arg| allocator.free(arg);
        allocator.free(cmd);
    }
    try testing.expectEqualStrings("osascript", cmd[0]);
    try testing.expectEqualStrings("-e", cmd[1]);
    try testing.expect(std.mem.indexOf(u8, cmd[2], "display notification") != null);
    try testing.expect(std.mem.indexOf(u8, cmd[2], "Title") != null);
}

test "buildCommand on Windows returns powershell with the notification" {
    if (builtin.os.tag != .windows) return;
    const allocator = testing.allocator;
    const cmd = try notifications.buildCommand(allocator, "Title", "Body");
    defer {
        for (cmd) |arg| allocator.free(arg);
        allocator.free(cmd);
    }
    try testing.expectEqualStrings("powershell", cmd[0]);
    try testing.expectEqualStrings("-NoProfile", cmd[1]);
    try testing.expect(std.mem.indexOf(u8, cmd[3], "Title") != null);
    try testing.expect(std.mem.indexOf(u8, cmd[3], "Body") != null);
}

test "buildCommand truncates body longer than 140 chars" {
    const allocator = testing.allocator;
    var long: [500]u8 = undefined;
    @memset(&long, 'x');
    const cmd = try notifications.buildCommand(allocator, "T", &long);
    defer {
        for (cmd) |arg| allocator.free(arg);
        allocator.free(cmd);
    }
    // Every argv item should be at most ~200 chars (some platforms wrap).
    for (cmd) |arg| {
        try testing.expect(arg.len <= 200);
    }
    // The body should be the last item and end with the ellipsis.
    const body_arg = cmd[cmd.len - 1];
    try testing.expectEqual(@as(usize, 140), body_arg.len);
    try testing.expect(std.mem.endsWith(u8, body_arg, "…"));
}

// ---------------------------------------------------------------------------
// notifyWithPath: tests the BinaryNotFound error path without needing notify-send
// ---------------------------------------------------------------------------

test "notifyWithPath returns BinaryNotFound when the binary does not exist" {
    const allocator = testing.allocator;
    const result = notifications.notifyWithPath(testing.io, allocator, "/nonexistent/path/notify-send", "T", "B");
    try testing.expectError(error.BinaryNotFound, result);
}

test "notifyWithPath returns BinaryNotFound for an empty path" {
    const allocator = testing.allocator;
    const result = notifications.notifyWithPath(testing.io, allocator, "", "T", "B");
    try testing.expectError(error.BinaryNotFound, result);
}
