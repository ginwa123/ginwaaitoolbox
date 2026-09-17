// src/service/signal_handlers_test.zig
//
// Tests for src/service/signal_handlers.zig.
//
// ## POSIX test
//
// Installs the SIGTERM handler, sends SIGTERM to ourselves, and
// verifies the callback fires.
//
// ## Windows test
//
// `SetConsoleCtrlHandler` registers a HandlerRoutine that the OS calls
// when the user hits Ctrl-C / Ctrl-Break in the console, or when the
// system is logging off / shutting down. We can't easily simulate
// CTRL_C_EVENT from a unit test (it would actually kill the test
// runner), so the function pointer / comptime platform switch tests
// cover the Windows path (the function must NOT throw `@compileError`
// on Windows). The behavioral test on Windows would need a separate
// detached child process to actually fire CTRL_C_EVENT into; that's a
// future PR.

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

test "installSigtermHandler is callable cross-platform" {
    // Static contract: just taking the address must compile on every
    // platform. If the function throws @compileError on Windows (or any
    // target), this fails to compile.
    const function_pointer = &signal_handlers.installSigtermHandler;
    _ = function_pointer;
    try testing.expect(true);
}

test "POSIX SIGTERM handler triggers callback" {
    if (builtin.os.tag == .windows) return;
    if (builtin.os.tag != .linux and builtin.os.tag != .macos) return;

    signal_handlers.resetForTests();
    callback_fired.store(false, .release);
    signal_handlers.installSigtermHandler(testCallback);

    // Send SIGTERM to ourselves.
    _ = std.c.kill(std.c.getpid(), std.c.SIG.TERM);

    // Give the handler a chance to run. Zig 0.16 removed std.posix.nanosleep;
    // use libc's nanosleep directly via std.c.
    var ts = std.posix.timespec{ .sec = 0, .nsec = 100_000_000 };
    _ = std.c.nanosleep(&ts, null);

    try testing.expect(callback_fired.load(.acquire));
    signal_handlers.resetForTests();
}

test "POSIX SIGINT handler triggers callback (Ctrl+C graceful shutdown)" {
    if (builtin.os.tag == .windows) return;
    if (builtin.os.tag != .linux and builtin.os.tag != .macos) return;

    signal_handlers.resetForTests();
    callback_fired.store(false, .release);
    signal_handlers.installShutdownHandlers(testCallback);

    // Send SIGINT to ourselves — the foreground Ctrl+C path.
    _ = std.c.kill(std.c.getpid(), std.c.SIG.INT);

    var ts = std.posix.timespec{ .sec = 0, .nsec = 100_000_000 };
    _ = std.c.nanosleep(&ts, null);

    try testing.expect(callback_fired.load(.acquire));
    signal_handlers.resetForTests();
}
