
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
    // Every argv item should be bounded by the platform's argv-item length
    // limit. Linux notify-send takes 4 short args (< 200 chars). macOS
    // osascript takes a single -e script that includes the body, so the
    // script length is "display notification \"...\" with title \"T\"" ≈
    // 200 + body_len. Windows PowerShell takes a single -Command script
    // that embeds the body via format string — the script is the
    // longest (≈ 175 + title + body_len ≈ 316 with title="T" and
    // body_len=140). 400 chars is comfortably above all of these.
    const max_arg_len: usize = if (builtin.os.tag == .windows) 400 else 350;
    for (cmd) |arg| {
        try testing.expect(arg.len <= max_arg_len);
    }
    // The body (truncated to 140 chars + ellipsis "…") should be present
    // in the command's output. On Linux/macOS the body is a separate argv
    // item; on Windows it's embedded in the PowerShell script. We check
    // for its presence across the entire command (concatenated) so the
    // assertion works on every platform.
    var all_args: std.ArrayList(u8) = .empty;
    defer all_args.deinit(allocator);
    for (cmd) |arg| {
        try all_args.appendSlice(allocator, arg);
        try all_args.append(allocator, '\n');
    }
    // The body should appear in the rendered command as 137 'x' chars
    // (MAX_BODY_LEN=140 minus ellipsis_len=3) followed by the ellipsis.
    // This confirms truncation kicked in and the body was correctly
    // embedded in the command.
    var expected_body_buf: [notifications.MAX_BODY_LEN]u8 = undefined;
    @memset(expected_body_buf[0 .. notifications.MAX_BODY_LEN - 3], 'x');
    @memcpy(
        expected_body_buf[notifications.MAX_BODY_LEN - 3 ..][0..3],
        "…",
    );
    const expected_body_substr: []const u8 = &expected_body_buf;
    try testing.expect(std.mem.indexOf(u8, all_args.items, expected_body_substr) != null);
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

// ---------------------------------------------------------------------------
// notifyWithPath positive path: spawn /bin/true (exits immediately) to
// verify the spawn-and-reap pipeline works. Without the reaper thread,
// /bin/true exits so fast that we can't observe the bug from inside
// the test process.
// ---------------------------------------------------------------------------

test "notifyWithPath with /bin/true returns success and does not leak" {
    if (builtin.os.tag == .windows) return; // /bin/true not on Windows
    const allocator = testing.allocator;
    // /bin/true exits immediately. If the function blocks on a
    // synchronous child.wait, the test still passes (the wait is
    // microseconds).
    try notifications.notifyWithPath(testing.io, allocator, "/bin/true", "T", "B");
    // No explicit assertion needed: returning from notifyWithPath
    // without error is the success criterion.
}
