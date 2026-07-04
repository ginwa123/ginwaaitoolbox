// src/signal_handlers.zig
//
// Signal handlers for the nalar service daemon. Currently implements
// SIGTERM handling on POSIX (used for graceful shutdown when `nalar
// service stop` is called or the user sends SIGTERM via the OS).
//
// Windows handler (CTRL_C_EVENT / CTRL_BREAK_EVENT) is a stub for v1.
// See the design doc for the full Windows console-ctrl-handler path.

const std = @import("std");
const builtin = @import("builtin");

/// Type of callback fired by the SIGTERM/console-ctrl handler.
pub const ShutdownCallback = *const fn () void;

// Module-level storage for the registered callback. There's only ever
// one SIGTERM handler per process, so a single global is sufficient.
var global_callback: ?ShutdownCallback = null;

// C calling convention is required so the kernel can invoke us as a
// signal handler. Zig functions default to Zig's calling convention;
// `callconv(.c)` switches to the C ABI. The function itself is just
// a regular Zig function (NOT `extern "c"` which forbids a body).
// The signal parameter type must be the SIG enum, not a raw c_int,
// to match std.c.Sigaction.handler_fn signature.
fn handle_sigterm(_: std.c.SIG) callconv(.c) void {
    if (global_callback) |cb| cb();
}

/// Install a SIGTERM handler that invokes `callback`. Caller is the
/// daemon process. The handler is set with SA_RESTART so interrupted
/// syscalls resume automatically (no EINTR leaks into the rest of the
/// server).
///
/// On Windows, this is a compile-time error — the handler is set via
/// `SetConsoleCtrlHandler` instead (out of scope for v1).
pub fn installSigtermHandler(callback: ShutdownCallback) void {
    if (builtin.os.tag == .windows) {
        @compileError("Windows console-ctrl-handler is not implemented (Chunk 2 follow-up)");
    }
    global_callback = callback;

    // std.posix.sigaction expects std.c.Sigaction (the libc struct).
    // Using std.os.linux.Sigaction produces a type-mismatch error
    // because the flag/mask types differ slightly between libc and
    // the raw syscall header.
    var sa: std.c.Sigaction = .{
        .handler = .{ .handler = handle_sigterm },
        .mask = std.mem.zeroes(std.c.sigset_t),
        .flags = std.c.SA.RESTART,
    };
    // std.posix.sigaction returns void in Zig 0.16 — do NOT wrap in try.
    // The 2nd arg is `?*const Sigaction`; we have a mutable pointer.
    std.posix.sigaction(std.c.SIG.TERM, &sa, null);
}