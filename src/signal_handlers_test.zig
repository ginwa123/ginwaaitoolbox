// src/signal_handlers_test.zig
//
// Tests for src/signal_handlers.zig. The POSIX test installs the SIGTERM
// handler, sends SIGTERM to ourselves, and verifies the callback fires.

const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const signal_handlers = @import("signal_handlers.zig");

// Module-level atomic for the test callback to set. Using std.atomic.Value
// ensures the compiler doesn't optimize away the read in the assertion.
var callback_fired: std.atomic.Value(bool) = .init(false);

fn testCallback() void {
    callback_fired.store(true, .release);
}

test "POSIX SIGTERM handler triggers callback" {
    if (builtin.os.tag == .windows) return;
    if (builtin.os.tag != .linux and builtin.os.tag != .macos) return;

    callback_fired.store(false, .release);
    signal_handlers.installSigtermHandler(testCallback);

    // Send SIGTERM to ourselves.
    _ = std.c.kill(std.c.getpid(), std.c.SIG.TERM);

    // Give the handler a chance to run. Zig 0.16 removed std.posix.nanosleep;
    // use libc's nanosleep directly via std.c.
    var ts = std.posix.timespec{ .sec = 0, .nsec = 100_000_000 };
    _ = std.c.nanosleep(&ts, null);

    try testing.expect(callback_fired.load(.acquire));
}