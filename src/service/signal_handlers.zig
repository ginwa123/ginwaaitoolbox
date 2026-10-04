// src/service/signal_handlers.zig
//
// Signal handlers for the pabrik service daemon.
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
// one shutdown handler per process, so a single global is sufficient.
var global_callback: ?ShutdownCallback = null;

// Counts received shutdown signals. The first SIGINT/SIGTERM runs the
// graceful callback (close listener, drain, stop workers). A second
// signal while shutdown is already in flight force-exits so a hung
// drain can never trap the user (standard Ctrl+C-twice UX).
var shutdown_signal_count: std.atomic.Value(u8) = .init(0);

// =============================================================================
// POSIX signal handler
// =============================================================================

// C calling convention is required so the kernel can invoke us as a
// signal handler. Zig functions default to Zig's calling convention;
// `callconv(.c)` switches to the C ABI. The function itself is just
// a regular Zig function (NOT `extern "c"` which forbids a body).
// The signal parameter type must be the SIG enum, not a raw c_int,
// to match std.c.Sigaction.handler_fn signature.
//
// Handles both SIGTERM (daemon `service stop`, docker stop, systemd)
// and SIGINT (foreground Ctrl+C). Only async-signal-safe work happens
// here: an atomic increment plus the registered callback, which must
// itself stay signal-safe (in practice: `GinwaServer.shutdown()` —
// a bool store plus shutdown(2)/close(2), both async-signal-safe).
fn handle_shutdown_signal(_: std.c.SIG) callconv(.c) void {
    const count = shutdown_signal_count.fetchAdd(1, .seq_cst);
    if (count >= 1) {
        // Second signal while graceful shutdown is already running:
        // force-exit so a stuck drain can't trap the process.
        std.process.exit(130);
    }
    if (global_callback) |cb| cb();
}

// Kept for the old name — same handler, now shared by SIGTERM+SIGINT.
fn handle_sigterm(sig: std.c.SIG) callconv(.c) void {
    handle_shutdown_signal(sig);
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
/// Second event while a drain is in flight force-exits (Ctrl+C-twice).
fn handle_console_ctrl(dwCtrlType: u32) callconv(.winapi) u32 {
    _ = dwCtrlType; // we don't differentiate — every ctrl event = "shut down gracefully"
    const count = shutdown_signal_count.fetchAdd(1, .seq_cst);
    if (count >= 1) std.process.exit(130);
    if (global_callback) |cb| cb();
    return win32_apis.BOOL_TRUE;
}

// =============================================================================
// Public cross-platform entry point
// =============================================================================

/// Install a SIGTERM-equivalent handler that invokes `callback`.
///
/// POSIX: registers for BOTH `SIGTERM` (daemon `service stop`, docker
/// stop, systemd) and `SIGINT` (foreground Ctrl+C) via
/// `std.posix.sigaction` with `SA_RESTART` so interrupted syscalls
/// resume automatically.
///
/// Windows: registers for all console-ctrl events via
/// `SetConsoleCtrlHandler(HandlerRoutine, TRUE)`. The routine fires the
/// callback AND returns TRUE (preventing the OS default handler from
/// killing the process — critical for shutdown handlers like ours).
///
/// Comptime-dispatched on `builtin.os.tag` so the unused platform's
/// code is fully eliminated by the compiler.
///
/// The callback runs IN SIGNAL CONTEXT — it must stay async-signal-safe
/// (no allocation, no logging, no mutex). `GinwaServer.shutdown()` meets
/// that bar (bool store + shutdown(2)/close(2)). A second signal while
/// the first is still draining force-exits with code 130.
pub fn installSigtermHandler(callback: ShutdownCallback) void {
    global_callback = callback;
    // Reset the two-hit counter so reinstalling (tests, restarts)
    // starts from a clean first-signal state.
    shutdown_signal_count.store(0, .seq_cst);
    switch (builtin.os.tag) {
        .linux, .macos => installShutdownHandlersPosix(),
        .windows => installSigtermHandlerWindows(),
        else => @compileError("signal_handlers.installSigtermHandler: unsupported platform " ++ @tagName(builtin.os.tag)),
    }
}

/// Preferred alias — same as `installSigtermHandler`, named for what it
/// does (graceful shutdown on SIGINT+SIGTERM / console-ctrl).
pub const installShutdownHandlers = installSigtermHandler;

/// Reset test-only state (callback + signal counter) without touching
/// the installed sigactions. Unit tests call this between cases so one
/// test's SIGINT doesn't trip the next test's two-hit force-exit.
pub fn resetForTests() void {
    global_callback = null;
    shutdown_signal_count.store(0, .seq_cst);
}

fn installShutdownHandlersPosix() void {
    // std.posix.sigaction expects std.c.Sigaction (the libc struct).
    // Using std.os.linux.Sigaction produces a type-mismatch error
    // because the flag/mask types differ slightly between libc and
    // the raw syscall header.
    var sa: std.c.Sigaction = .{
        .handler = .{ .handler = handle_shutdown_signal },
        .mask = std.mem.zeroes(std.c.sigset_t),
        .flags = std.c.SA.RESTART,
    };
    // std.posix.sigaction returns void in Zig 0.16 — do NOT wrap in try.
    // The 2nd arg is `?*const Sigaction`; we have a mutable pointer.
    // Register BOTH: SIGTERM (service stop / docker / systemd) and
    // SIGINT (foreground Ctrl+C) share one graceful callback.
    std.posix.sigaction(std.c.SIG.TERM, &sa, null);
    std.posix.sigaction(std.c.SIG.INT, &sa, null);
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

// ===== Tests merged from signal_handlers_test.zig (2026-09-29 flatten) =====

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

const testing = std.testing;

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
    const function_pointer = &installSigtermHandler;
    _ = function_pointer;
    try testing.expect(true);
}

test "POSIX SIGTERM handler triggers callback" {
    if (builtin.os.tag == .windows) return;
    if (builtin.os.tag != .linux and builtin.os.tag != .macos) return;

    resetForTests();
    callback_fired.store(false, .release);
    installSigtermHandler(testCallback);

    // Send SIGTERM to ourselves.
    _ = std.c.kill(std.c.getpid(), std.c.SIG.TERM);

    // Give the handler a chance to run. Zig 0.16 removed std.posix.nanosleep;
    // use libc's nanosleep directly via std.c.
    var ts = std.posix.timespec{ .sec = 0, .nsec = 100_000_000 };
    _ = std.c.nanosleep(&ts, null);

    try testing.expect(callback_fired.load(.acquire));
    resetForTests();
}

test "POSIX SIGINT handler triggers callback (Ctrl+C graceful shutdown)" {
    if (builtin.os.tag == .windows) return;
    if (builtin.os.tag != .linux and builtin.os.tag != .macos) return;

    resetForTests();
    callback_fired.store(false, .release);
    installShutdownHandlers(testCallback);

    // Send SIGINT to ourselves — the foreground Ctrl+C path.
    _ = std.c.kill(std.c.getpid(), std.c.SIG.INT);

    var ts = std.posix.timespec{ .sec = 0, .nsec = 100_000_000 };
    _ = std.c.nanosleep(&ts, null);

    try testing.expect(callback_fired.load(.acquire));
    resetForTests();
}
