// src/signal_handlers.zig
//
// Signal handlers for the nalar service daemon.
//
// ## POSIX (Linux/macOS)
//
// Installs a SIGTERM handler that fires the registered shutdown
// callback. Set with SA_RESTART so interrupted syscalls resume
// automatically (no EINTR leaks into the rest of the server).
//
// ## Windows
//
// Registers a HandlerRoutine via `SetConsoleCtrlHandler` that fires
// the same shutdown callback. The handler is invoked for:
//   - CTRL_C_EVENT — user pressed Ctrl-C in the console
//   - CTRL_BREAK_EVENT — user pressed Ctrl-Break in the console
//   - CTRL_CLOSE_EVENT — console window closing (user clicked X)
//   - CTRL_LOGOFF_EVENT — user logging off
//   - CTRL_SHUTDOWN_EVENT — system shutting down
//
// Note: a process started with DETACHED_PROCESS + CREATE_NEW_PROCESS_GROUP
// (which is exactly what daemon.zig::daemonize uses on Windows) is NOT
// in the same console as the parent process. It will NOT receive Ctrl-C
// or Ctrl-Break from the parent's terminal. It CAN still receive:
//   - CTRL_CLOSE_EVENT / CTRL_LOGOFF_EVENT / CTRL_SHUTDOWN_EVENT from the
//     system itself (always relevant for a service daemon)
//   - GenerateConsoleCtrlEvent() from another process in the same group
//
// The HandlerRoutine returns TRUE (1) to indicate "we handled the signal —
// do NOT call the default handler". On Windows the default for
// CTRL_CLOSE_EVENT / CTRL_LOGOFF_EVENT / CTRL_SHUTDOWN_EVENT is to
// terminate the process; returning TRUE prevents that.

const std = @import("std");
const builtin = @import("builtin");

/// Type of callback fired by the SIGTERM/console-ctrl handler.
pub const ShutdownCallback = *const fn () void;

// Module-level storage for the registered callback. There's only ever
// one SIGTERM handler per process, so a single global is sufficient.
var global_callback: ?ShutdownCallback = null;

// =============================================================================
// POSIX signal handler
// =============================================================================

// C calling convention is required so the kernel can invoke us as a
// signal handler. Zig functions default to Zig's calling convention;
// `callconv(.c)` switches to the C ABI. The function itself is just
// a regular Zig function (NOT `extern "c"` which forbids a body).
// The signal parameter type must be the SIG enum, not a raw c_int,
// to match std.c.Sigaction.handler_fn signature.
fn handle_sigterm(_: std.c.SIG) callconv(.c) void {
    if (global_callback) |cb| cb();
}

// =============================================================================
// Windows console-ctrl handler
// =============================================================================

// Compile-time-gated Win32 bindings. On POSIX this struct is materialised
// as empty (struct {}) so the extern decls are never visible to the
// linker and won't cause "undefined symbol" errors.
const win32_apis = if (builtin.os.tag == .windows) struct {
    const BOOL_TRUE: u32 = 1;
    const BOOL_FALSE: u32 = 0;

    // Console ctrl event types. dwCtrlType parameter to HandlerRoutine.
    const CTRL_C_EVENT: u32 = 0;
    const CTRL_BREAK_EVENT: u32 = 1;
    const CTRL_CLOSE_EVENT: u32 = 2;
    const CTRL_LOGOFF_EVENT: u32 = 5;
    const CTRL_SHUTDOWN_EVENT: u32 = 6;

    // SetConsoleCtrlHandler HandlerRoutine callback. Returns BOOL (u32)
    // nonzero = "we handled the signal — do NOT call the default handler".
    const HandlerRoutine = *const fn (dwCtrlType: u32) callconv(.winapi) u32;

    extern "kernel32" fn SetConsoleCtrlHandler(
        handlerRoutine: ?HandlerRoutine,
        add: u32,
    ) callconv(.winapi) u32;
} else struct {};

/// The console-ctrl handler is invoked by the kernel via
/// `SetConsoleCtrlHandler`. We treat every event type the same way:
/// fire the shutdown callback and return TRUE so the OS doesn't fall
/// through to its default handler (which would kill the process).
fn handle_console_ctrl(dwCtrlType: u32) callconv(.winapi) u32 {
    _ = dwCtrlType; // we don't differentiate — every ctrl event = "shut down gracefully"
    if (global_callback) |cb| cb();
    return win32_apis.BOOL_TRUE;
}

// =============================================================================
// Public cross-platform entry point
// =============================================================================

/// Install a SIGTERM-equivalent handler that invokes `callback`.
///
/// POSIX: registers for `SIGTERM` via `std.posix.sigaction` with
/// `SA_RESTART` so interrupted syscalls resume automatically.
///
/// Windows: registers for all console-ctrl events via
/// `SetConsoleCtrlHandler(HandlerRoutine, TRUE)`. The routine fires the
/// callback AND returns TRUE (preventing the OS default handler from
/// killing the process — critical for shutdown handlers like ours).
///
/// Comptime-dispatched on `builtin.os.tag` so the unused platform's
/// code is fully eliminated by the compiler.
pub fn installSigtermHandler(callback: ShutdownCallback) void {
    global_callback = callback;
    switch (builtin.os.tag) {
        .linux, .macos => installSigtermHandlerPosix(),
        .windows => installSigtermHandlerWindows(),
        else => @compileError("signal_handlers.installSigtermHandler: unsupported platform " ++ @tagName(builtin.os.tag)),
    }
}

fn installSigtermHandlerPosix() void {
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

fn installSigtermHandlerWindows() void {
    // Register handle_console_ctrl as a console-ctrl-handler. add=TRUE
    // means "install"; the routine will receive CTRL_C_EVENT,
    // CTRL_BREAK_EVENT, CTRL_CLOSE_EVENT, CTRL_LOGOFF_EVENT,
    // CTRL_SHUTDOWN_EVENT. We treat them all as "graceful shutdown
    // request" and return TRUE from the handler so the OS doesn't
    // fall back to its default (which would kill us).
    //
    // We intentionally DON'T pass a Routine for SetConsoleCtrlHandler's
    // removal API — there's only one daemon process per invocation.
    _ = win32_apis.SetConsoleCtrlHandler(handle_console_ctrl, 1);
}
