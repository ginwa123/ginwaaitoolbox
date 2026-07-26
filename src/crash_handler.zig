// src/crash_handler.zig
//
// Crash signal/exception handler — the missing sibling to root.zig's
// `panicHandler`. The panic handler catches Zig-level panics (unreachable,
// index OOB, slice OOB, explicit @panic). This file catches the OS-level
// crash signals that the panic handler cannot reach:
//
//   POSIX:
//     SIGSEGV  — null deref, use-after-free, bad pointer arithmetic
//     SIGBUS   — misaligned access on platforms where it matters
//     SIGABRT  — debug allocator's `Invalid free`, libc abort()
//     SIGILL   — execute of invalid instruction bytes
//     SIGFPE   — divide by zero, integer overflow traps
//
//   Windows:
//     EXCEPTION_ACCESS_VIOLATION     (signal 11 analogue)
//     EXCEPTION_ILLEGAL_INSTRUCTION  (signal 4  analogue)
//     EXCEPTION_INT_DIVIDE_BY_ZERO   (signal 8  analogue)
//     EXCEPTION_STACK_OVERFLOW       (delivered as a UEF)
//     EXCEPTION_BREAKPOINT, etc.
//
// ## What the handler does
//
// 1. Restore the OS default handler for the signal BEFORE attempting any
//    logging. If our own logging code crashes (e.g. fopen fails inside the
//    signal context), the kernel re-delivers the signal to the default
//    handler which terminates the process with a core dump. Without this
//    step, a recursive crash loops forever.
// 2. Capture the current stack trace via `std.debug.getStackTrace`.
// 3. Format the trace + signal/exception metadata and append it to the
//    panic log file (the same file `panicHandler` writes to — see
//    `root.zig::setPanicLogPath`). Best-effort: any allocation failure
//    or fopen failure is silently swallowed.
// 4. Mirror the same content to stderr so the launching terminal sees
//    it.
// 5. Re-raise the signal (POSIX `std.c.raise`) or return
//    `EXCEPTION_EXECUTE_HANDLER` (Windows) so the OS default action
//    runs: terminate the process. Core dumps (if enabled) still happen.
//
// ## Async-signal-safety caveat
//
// Per POSIX.1, only a small set of libc functions are guaranteed
// async-signal-safe (write, _exit, etc.). `fopen` / `fwrite` / `fclose`
// are NOT in that list. We use them anyway — same compromise as
// `root.zig::panicHandler` — because:
//   * Best-effort logging is better than no logging.
//   * On glibc / macOS libc, fopen's internal locks are typically
//     uncontended from a single-threaded signal handler context.
//   * If the log attempt crashes, the default-handler restoration in
//     step 1 catches the recursion.
//
// For a production-grade signal-safe log you'd switch to a pre-opened
// fd + `write(2)` + lock-free ring buffer. That's a follow-up; this
// implementation matches the existing pattern in panicHandler.
//
// ## Setup
//
// Call `installCrashHandlers()` once during startup, AFTER
// `nalarcore.setPanicLogPath()` has been called. The handler reads the
// path via `getCrashLogPath()` — a module-level global set by
// `setCrashLogPath()`. Two globals (the panic handler's and this one)
// avoid a circular `root.zig` ↔ `crash_handler.zig` import.
//
// ## Cross-platform behaviour
//
// Both branches are guarded by `comptime switch (builtin.os.tag)` so
// the unused platform's code is fully eliminated at compile time. The
// test suite's "installCrashHandlers is callable cross-platform"
// contract pins this — taking the function's address forces the
// materialised body on every target.

const std = @import("std");
const builtin = @import("builtin");

// =============================================================================
// Module-level panic log path
// =============================================================================

/// Path to the panic log file. Set by `setCrashLogPath(path)` BEFORE
/// `installCrashHandlers()` is called. Mirrors `root.zig::panic_log_path`
/// but kept separate to avoid a circular import.
var crash_log_path: ?[]const u8 = null;

pub fn setCrashLogPath(path: []const u8) void {
    crash_log_path = path;
}

pub fn getCrashLogPath() ?[]const u8 {
    return crash_log_path;
}

// =============================================================================
// Public entry point
// =============================================================================

/// Install crash signal/exception handlers. Idempotent — calling twice
/// has the same effect as calling once (the second sigaction call
/// overwrites the first handler with the same function pointer).
///
/// On unsupported platforms (anything other than Linux/macOS/Windows)
/// this is a no-op.
pub fn installCrashHandlers() void {
    switch (builtin.os.tag) {
        .linux, .macos => installCrashHandlersPosix(),
        .windows => installCrashHandlersWindows(),
        else => {}, // unsupported — silently no-op
    }
}

// =============================================================================
// POSIX (Linux + macOS)
// =============================================================================

fn installCrashHandlersPosix() void {
    // The set of crash signals we want to log. Order doesn't matter.
    const signals = [_]std.c.SIG{
        std.c.SIG.SEGV,
        std.c.SIG.BUS,
        std.c.SIG.ABRT,
        std.c.SIG.ILL,
        std.c.SIG.FPE,
    };

    for (signals) |sig| {
        var sa: std.c.Sigaction = .{
            .handler = .{ .handler = handleCrashSignal },
            .mask = std.mem.zeroes(std.c.sigset_t),
            .flags = std.c.SA.RESTART,
        };
        // std.posix.sigaction returns void in Zig 0.16 — do NOT wrap in try.
        // The 2nd arg is `?*const Sigaction`; we have a mutable pointer.
        std.posix.sigaction(sig, &sa, null);
    }
}

/// POSIX crash handler. Runs in signal context — only async-signal-safe
/// (or best-effort) operations allowed. See file header for caveats.
fn handleCrashSignal(sig: std.c.SIG) callconv(.c) void {
    // STEP 1 — restore the OS default handler BEFORE logging. If our
    // logger crashes inside this handler, the kernel re-delivers the
    // signal to the default action (terminate + core dump) instead of
    // re-entering us. Critical: do this BEFORE any allocation / I/O.
    var sa: std.c.Sigaction = .{
        .handler = .{ .handler = std.c.SIG.DFL },
        .mask = std.mem.zeroes(std.c.sigset_t),
        .flags = 0,
    };
    std.posix.sigaction(sig, &sa, null);

    // STEP 2 — capture the stack trace and build the log content.
    // Uses page_allocator (best-effort — OOM is silently dropped).
    //
    // Zig 0.16's std.debug API replaced getStackTrace / formatStackTrace
    // with captureCurrentStackTrace (returns addresses) + writeStackTrace
    // (takes Io.Terminal). The Terminal-based writers aren't safe to call
    // from signal context (they lock stderr), so we capture the addresses
    // here and format them ourselves — the resulting log has raw hex
    // addresses rather than source-file:line annotations, which is still
    // useful for post-mortem debugging with `addr2line` or `llvm-symbolizer`.
    const signal_name = @tagName(sig);
    const header = std.fmt.allocPrint(std.heap.page_allocator,
        \\=== CRASH: received signal {s} (signal number {d}) ===
    , .{ signal_name, @intFromEnum(sig) }) catch "=== CRASH: received signal (name unavailable) ===\n";
    defer std.heap.page_allocator.free(header);

    var stack_buf: std.ArrayList(u8) = .empty;
    defer stack_buf.deinit(std.heap.page_allocator);
    var addr_buf: [32]usize = undefined;
    const stack = std.debug.captureCurrentStackTrace(.{}, &addr_buf);

    // Format each line into a fixed stack buffer with std.fmt.bufPrint
    // (no per-line allocation) then appendSlice into the heap-backed
    // ArrayList. Signal-safer than calling ArrayList.print.
    var line_buf: [256]u8 = undefined;
    const header_line = std.fmt.bufPrint(&line_buf,
        "Stack trace ({d} frames):\n", .{stack.return_addresses.len})
        catch "Stack trace (...)\n";
    stack_buf.appendSlice(std.heap.page_allocator, header_line) catch {};

    for (stack.return_addresses) |ra| {
        const frame_line = std.fmt.bufPrint(&line_buf,
            "  0x{x:0>16}\n", .{ra}) catch continue;
        stack_buf.appendSlice(std.heap.page_allocator, frame_line) catch {};
    }

    const footer = "\n=============\n";

    // STEP 3 — append to the panic log file (best-effort). If we
    // can't open the file we still try stderr, then re-raise.
    if (crash_log_path) |path| {
        // std.c.fopen requires a NUL-terminated string ([*:0]const u8),
        // but our path is just []const u8. Copy into a stack buffer
        // and append a NUL — no heap allocation in signal context.
        var path_z: [std.Io.Dir.max_path_bytes + 1]u8 = undefined;
        if (path.len < path_z.len) {
            @memcpy(path_z[0..path.len], path);
            path_z[path.len] = 0;
            // @ptrCast from *fixed-u8 to [*:0]const u8 — safe because we
            // just wrote the NUL sentinel at path_z[path.len].
            const path_z_ptr: [*:0]const u8 = @ptrCast(&path_z);
            if (std.c.fopen(path_z_ptr, "a")) |file| {
                defer _ = std.c.fclose(file);
                _ = std.c.fwrite(header.ptr, 1, header.len, file);
                _ = std.c.fwrite(stack_buf.items.ptr, 1, stack_buf.items.len, file);
                _ = std.c.fwrite(footer.ptr, 1, footer.len, file);
            }
        }
    }

    // STEP 4 — mirror to stderr for terminal visibility.
    std.debug.print("{s}\n{s}{s}", .{ header, stack_buf.items, footer });

    // STEP 5 — re-raise so the OS default action runs (terminate +
    // core dump). std.c.raise returns c_int (0 on success, -1 on
    // failure). If raise fails we still need to terminate cleanly
    // — fall through to _Exit which IS async-signal-safe.
    if (std.c.raise(sig) != 0) {
        std.c._Exit(128 + @as(c_int, @intCast(@intFromEnum(sig))));
    }
    unreachable;
}

// =============================================================================
// Windows
// =============================================================================

/// Bind the Win32 SetUnhandledExceptionFilter API. The filter callback
/// receives a pointer to `EXCEPTION_POINTERS` (exception record +
/// context) for the crash.
const win32_apis = if (builtin.os.tag == .windows) struct {
    /// EXCEPTION_EXECUTE_HANDLER is the value the UEF returns to tell
    /// the kernel "I've handled it; unwind and terminate". NOT exposed
    /// by `std.os.windows` in Zig 0.16 — declared here per WinNT.h.
    pub const EXCEPTION_EXECUTE_HANDLER: c_long = 1;

    /// Function pointer type for SetUnhandledExceptionFilter's callback.
    /// Returns LONG (c_long); WINAPI = __stdcall on x86 = callconv(.winapi)
    /// in Zig 0.16.
    pub const UnhandledExceptionFilterFn = *const fn (
        exception_info: *std.os.windows.EXCEPTION_POINTERS,
    ) callconv(.winapi) c_long;

    extern "kernel32" fn SetUnhandledExceptionFilter(
        filter: ?UnhandledExceptionFilterFn,
    ) callconv(.winapi) ?UnhandledExceptionFilterFn;
} else struct {};

fn installCrashHandlersWindows() void {
    _ = win32_apis.SetUnhandledExceptionFilter(handleWindowsException);
}

/// Windows unhandled exception filter. Runs in exception-dispatch
/// context — equivalent to a signal handler for crash purposes.
///
/// Returns `EXCEPTION_EXECUTE_HANDLER` (1) so the kernel unwinds
/// handlers and terminates the process. We can't "re-raise" on Windows
/// (the UEF is the last filter in the chain) — returning 0
/// (EXCEPTION_CONTINUE_SEARCH) would hand control to WER / the
/// debugger, which is rarely what the user wants from a server.
fn handleWindowsException(exception_info: *std.os.windows.EXCEPTION_POINTERS) callconv(.winapi) c_long {
    const code = exception_info.ExceptionRecord.ExceptionCode;
    const addr = @intFromPtr(exception_info.ExceptionRecord.ExceptionAddress);

    // Build a header that names the Windows exception code + the
    // crashing address. Most common codes:
    //   0xC0000005  EXCEPTION_ACCESS_VIOLATION  (SIGSEGV equivalent)
    //   0xC000001D  EXCEPTION_ILLEGAL_INSTRUCTION (SIGILL equivalent)
    //   0xC0000094  EXCEPTION_INT_DIVIDE_BY_ZERO (SIGFPE equivalent)
    //   0xC00000FD  EXCEPTION_STACK_OVERFLOW
    const header = std.fmt.allocPrint(std.heap.page_allocator,
        \\=== CRASH: Windows exception 0x{x:0>8} at address 0x{x} ===
    , .{ code, addr }) catch "=== CRASH: Windows exception (details unavailable) ===\n";
    defer std.heap.page_allocator.free(header);

    var stack_buf: std.ArrayList(u8) = .empty;
    defer stack_buf.deinit(std.heap.page_allocator);
    var addr_buf: [32]usize = undefined;
    const stack = std.debug.captureCurrentStackTrace(.{}, &addr_buf);

    var line_buf: [256]u8 = undefined;
    const header_line = std.fmt.bufPrint(&line_buf,
        "Stack trace ({d} frames):\n", .{stack.return_addresses.len})
        catch "Stack trace (...)\n";
    stack_buf.appendSlice(std.heap.page_allocator, header_line) catch {};

    for (stack.return_addresses) |ra| {
        const frame_line = std.fmt.bufPrint(&line_buf,
            "  0x{x:0>16}\n", .{ra}) catch continue;
        stack_buf.appendSlice(std.heap.page_allocator, frame_line) catch {};
    }

    const footer = "\n=============\n";

    if (crash_log_path) |path| {
        var path_z: [std.Io.Dir.max_path_bytes + 1]u8 = undefined;
        if (path.len < path_z.len) {
            @memcpy(path_z[0..path.len], path);
            path_z[path.len] = 0;
            const path_z_ptr: [*:0]const u8 = @ptrCast(&path_z);
            if (std.c.fopen(path_z_ptr, "a")) |file| {
                defer _ = std.c.fclose(file);
                _ = std.c.fwrite(header.ptr, 1, header.len, file);
                _ = std.c.fwrite(stack_buf.items.ptr, 1, stack_buf.items.len, file);
                _ = std.c.fwrite(footer.ptr, 1, footer.len, file);
            }
        }
    }

    std.debug.print("{s}\n{s}{s}", .{ header, stack_buf.items, footer });

    return win32_apis.EXCEPTION_EXECUTE_HANDLER;
}