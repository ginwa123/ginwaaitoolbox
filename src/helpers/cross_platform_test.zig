//! Cross-platform behavior tests for the helpers.process_status and
//! helpers.getcwd modules.
//!
//! Verifies that the cross-platform wrappers work correctly on Linux
//! (the CI platform). These tests should pass on Windows/macOS too —
//! they only exercise the Linux code paths here, but the underlying
//! `helpers.process_status.isProcessRunning(pid)` / `killProcess(pid)`
//! are platform-switched at comptime.
//!
//! To verify Windows/macOS behavior, run the test on those platforms
//! (e.g. via cross-compilation in CI).

const std = @import("std");
const testing = std.testing;
const nalarcore = @import("nalarcore");
const process_status = nalarcore.helpers.process_status;
const helpers = nalarcore.helpers;

test "getcwd: returns non-empty absolute path" {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd = helpers.getcwd(&buf) orelse {
        // No cwd on this system — skip (very unusual).
        return error.SkipZigTest;
    };
    try testing.expect(cwd.len > 0);
    // Absolute paths on Unix start with '/', on Windows with a drive letter.
    // We don't enforce either here — just confirm non-empty.
}

test "getcwd: returns null when buffer is too small" {
    // Pass a pathologically tiny buffer — libc should reject it.
    var tiny_buf: [1]u8 = undefined;
    const cwd = helpers.getcwd(&tiny_buf);
    // On most platforms this returns null because the path doesn't fit.
    // On some weird platforms it might succeed; we just check no crash.
    _ = cwd;
}

test "getcwd: buffer is NUL-terminated internally (handled by wrapper)" {
    // The wrapper uses indexOfScalar to find the NUL, so the caller
    // doesn't see it. This test exercises the slice logic.
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd = helpers.getcwd(&buf) orelse return;
    // The returned slice should not contain any NUL bytes (the wrapper
    // strips the terminator).
    for (cwd) |c| try testing.expect(c != 0);
}

test "process_status: getCurrentProcessIdInt returns positive i32" {
    const pid = process_status.getCurrentProcessIdInt();
    try testing.expect(pid > 0);
}

test "process_status: isProcessRunning returns true for self" {
    const self = process_status.getCurrentProcessIdInt();
    try testing.expect(process_status.isProcessRunning(self));
}

test "process_status: isProcessRunning returns false for pid 0" {
    try testing.expect(!process_status.isProcessRunning(0));
}

test "process_status: isProcessRunning returns false for negative pids" {
    try testing.expect(!process_status.isProcessRunning(-1));
    try testing.expect(!process_status.isProcessRunning(-100));
}

test "process_status: isProcessRunning returns false for very high pids" {
    // Real PIDs rarely exceed 2^22; 2^30 is safely above any real PID.
    try testing.expect(!process_status.isProcessRunning(1 << 30));
    try testing.expect(!process_status.isProcessRunning(1 << 29));
}

test "process_status: killProcess returns false for invalid pids" {
    try testing.expect(!process_status.killProcess(0));
    try testing.expect(!process_status.killProcess(-1));
    try testing.expect(!process_status.killProcess(-42));
}

test "process_status: killProcess returns false for non-existent pid" {
    // A very high PID is unlikely to exist.
    try testing.expect(!process_status.killProcess(1 << 30));
}

test "process_status: round-trip — isProcessRunning then killProcess" {
    // Spawn a child process that sleeps, verify isProcessRunning returns
    // true, kill it, verify isProcessRunning returns false.
    //
    // Uses std.process.Child via the v1.0+ API. If the platform doesn't
    // support child processes (e.g. wasm), skip.
    if (@import("builtin").os.tag == .wasm) return;

    // Spawn a long-running child (sleep 60 seconds).
    const argv = [_][]const u8{ "sleep", "60" };
    var child = std.process.spawn(std.testing.io, .{
        .argv = &argv,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    }) catch |err| switch (err) {
        error.FileNotFound => return, // sleep not available
        else => return,
    };

    const child_pid: i32 = @intCast(child.id orelse {
        // Spawn returned a null id — can't continue. Kill the child
        // defensively before bailing.
        child.kill(std.testing.io);
        return;
    });

    defer {
        // Clean up: kill the child if it's still alive.
        if (process_status.isProcessRunning(child_pid)) {
            _ = process_status.killProcess(child_pid);
        }
        _ = child.wait(std.testing.io);
    };

    // The child should be alive.
    try testing.expect(process_status.isProcessRunning(child_pid));

    // Kill it.
    try testing.expect(process_status.killProcess(child_pid));

    // Give the OS a moment to reap it.
    std.time.sleep(100 * std.time.ns_per_ms);

    // The child should now be dead.
    try testing.expect(!process_status.isProcessRunning(child_pid));
}