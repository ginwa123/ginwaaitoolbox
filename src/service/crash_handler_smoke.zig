// src/service/crash_handler_smoke.zig
//
// Tiny standalone binary that exercises src/service/crash_handler.zig
// end-to-end. Used by scripts/crash_handler_smoke.sh to verify the
// production crash
// handler actually runs when a SIGSEGV is delivered.
//
// NOT compiled into the production nalar binary — it's a sibling that
// lives in src/ for code-review visibility but is only built when the
// user runs the smoke script (which does `zig build-exe` directly).

const std = @import("std");
const builtin = @import("builtin");
const nalarcore = @import("nalarcore");

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    var args_iter = try std.process.Args.Iterator.initAllocator(init.minimal.args, allocator);
    defer args_iter.deinit();

    _ = args_iter.next(); // skip argv[0]
    const log_path_arg: []const u8 = args_iter.next() orelse "/tmp/crash_handler_smoke.log";
    const signal_arg: []const u8 = args_iter.next() orelse "SEGV";

    // Use the production crash_handler module — this is what we're verifying.
    nalarcore.crash_handler.setCrashLogPath(log_path_arg);
    nalarcore.crash_handler.installCrashHandlers();

    // Give the signal handler a moment to be installed before we trip it.
    // On POSIX, std.c.nanosleep is the standard async-safe delay. On
    // Windows, installCrashHandlers is synchronous (no sleep needed —
    // the SetUnhandledExceptionFilter call returned before we got here).
    if (builtin.os.tag != .windows) {
        var ts = std.c.timespec{ .sec = 0, .nsec = 50_000_000 };
        _ = std.c.nanosleep(&ts, null);
    }

    std.debug.print("[smoke] crash_handler installed for log='{s}'; triggering {s}\n", .{ log_path_arg, signal_arg });

    // Trigger the requested signal via raise() so the kernel delivers
    // it to our handler. BUS is not defined on Windows (no SIGBUS in
    // MSVC's libc); the test runner skips BUS on Windows.
    if (std.mem.eql(u8, signal_arg, "SEGV")) {
        _ = std.c.raise(std.c.SIG.SEGV);
    } else if (std.mem.eql(u8, signal_arg, "ABRT")) {
        _ = std.c.raise(std.c.SIG.ABRT);
    } else if (std.mem.eql(u8, signal_arg, "BUS")) {
        if (builtin.os.tag == .windows) {
            std.debug.print("[smoke] BUS skipped on Windows (no SIGBUS)\n", .{});
            return;
        }
        _ = std.c.raise(std.c.SIG.BUS);
    } else if (std.mem.eql(u8, signal_arg, "ILL")) {
        _ = std.c.raise(std.c.SIG.ILL);
    } else if (std.mem.eql(u8, signal_arg, "FPE")) {
        _ = std.c.raise(std.c.SIG.FPE);
    } else {
        std.debug.print("[smoke] unknown signal '{s}'\n", .{signal_arg});
        return error.UnknownSignal;
    }

    // raise() returned. If we reach this line, the handler swallowed
    // the signal instead of re-raising — that's a regression.
    std.debug.print("[smoke] FAIL: signal handler swallowed the signal — handler must re-raise\n", .{});
    return error.SignalSwallowed;
}