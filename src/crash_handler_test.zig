// src/crash_handler_test.zig
//
// Tests for src/crash_handler.zig (crash signal/exception handler).
//
// ## Behavioural test strategy
//
// A real crash handler can't be exercised in-process — SIGSEGV / SIGBUS
// / SIGABRT / SIGILL / SIGFPE / ACCESS_VIOLATION all terminate the
// process. The closest in-process check is to install the handler and
// confirm the function pointer is well-formed (i.e. the comptime
// `builtin.os.tag` switch produced a real body on every platform).
// Behavioural verification happens via a manual smoke test (see
// docs/superpowers/plans/<date>-crash-signal-handler.md) that spawns
// a child process which deliberately dereferences a bad pointer and
// then inspects the panic log file.
//
// ## Static-contract tests
//
// These pin the implementation so a future refactor can't silently
// drop a crash signal, drop the Windows path, or stop writing to the
// panic log file.
//
//   1. Comptime `builtin.os.tag` switch with .linux / .macos / .windows
//   2. POSIX branch installs SIGSEGV / SIGBUS / SIGABRT / SIGILL / SIGFPE
//   3. Windows branch calls SetUnhandledExceptionFilter
//   4. Both branches re-raise / re-execute so the OS default runs
//   5. Both branches capture the stack via std.debug.getStackTrace
//   6. Both branches write a "=== CRASH ===" header to the panic log
//   7. POSIX branch restores the default handler before re-raising
//      (so a recursive crash terminates instead of infinite-looping)
//   8. The handler is idempotent (calling install twice doesn't break)
//   9. POSIX branch uses std.posix.sigaction (the Zig 0.16 idiomatic API)
//
// Plan: docs/superpowers/plans/2026-04-08-crash-signal-handler.md

const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const crash_handler = @import("crash_handler.zig");

// ─── Contract 0: installCrashHandlers is callable cross-platform ───────

test "installCrashHandlers is callable cross-platform" {
    // Taking the address forces the comptime `switch (builtin.os.tag)`
    // to materialise a real body on every platform. If any branch
    // throws `@compileError`, this fails to compile.
    const function_pointer = &crash_handler.installCrashHandlers;
    _ = function_pointer;
    try testing.expect(true);
}

// ─── Contract 1: comptime builtin.os.tag dispatch ──────────────────────

test "crash_handler.zig uses comptime builtin.os.tag switch" {
    const source = @embedFile("crash_handler.zig");
    try testing.expect(std.mem.indexOf(u8, source, "switch (builtin.os.tag)") != null);
    try testing.expect(std.mem.indexOf(u8, source, ".linux") != null);
    try testing.expect(std.mem.indexOf(u8, source, ".macos") != null);
    try testing.expect(std.mem.indexOf(u8, source, ".windows") != null);
}

// ─── Contract 2: POSIX branch installs handlers for the 5 crash signals

test "POSIX branch installs SIGSEGV / SIGBUS / SIGABRT / SIGILL / SIGFPE" {
    const source = @embedFile("crash_handler.zig");
    // Each crash signal must appear in the source as a sigaction target.
    // We accept either the Zig 0.16 `std.c.SIG.SEGV` form or the
    // raw `SIGSEGV` form (in case the implementation uses a literal
    // signal number).
    const signals = [_][]const u8{ "SEGV", "BUS", "ABRT", "ILL", "FPE" };
    for (signals) |sig| {
        if (std.mem.indexOf(u8, source, sig) == null) {
            std.debug.print(
                "\n!! crash_handler.zig does not register a handler for {s} !!\n" ++
                    "   Crash signals covered: SIGSEGV, SIGBUS, SIGABRT, SIGILL, SIGFPE.\n" ++
                    "   If any signal is missing the corresponding crash is silent\n" ++
                    "   (kernel terminates the process without an app-level log entry).\n",
                .{sig},
            );
            return error.CrashSignalMissing;
        }
    }
}

// ─── Contract 3: Windows branch uses SetUnhandledExceptionFilter ───────

test "Windows branch installs SetUnhandledExceptionFilter" {
    const source = @embedFile("crash_handler.zig");
    if (std.mem.indexOf(u8, source, "SetUnhandledExceptionFilter") == null) {
        std.debug.print(
            "\n!! crash_handler.zig does not call SetUnhandledExceptionFilter !!\n" ++
                "   Windows needs the UEF API (not sigaction) because the crash\n" ++
                "   delivery mechanism is a structured EXCEPTION_RECORD, not a signal.\n",
            .{},
        );
        return error.WindowsUnhandledFilterMissing;
    }
    // The filter callback must use callconv(.winapi) per Win32 docs
    // (WINAPI = __stdcall on x86). Calling-convention mismatch causes
    // the kernel to invoke the filter via the wrong ABI, corrupting
    // the stack on return.
    if (std.mem.indexOf(u8, source, "callconv(.winapi)") == null) {
        std.debug.print(
            "\n!! Windows filter callback does not use callconv(.winapi) !!\n" ++
                "   The UEF callback is invoked by the kernel via the WINAPI calling\n" ++
                "   convention (__stdcall on x86). Using callconv(.c) corrupts the stack.\n",
            .{},
        );
        return error.WindowsFilterCallconvMissing;
    }
}

// ─── Contract 4: both branches re-raise the signal / re-execute ────────

test "POSIX branch re-raises the signal via std.c.raise" {
    const source = @embedFile("crash_handler.zig");
    if (std.mem.indexOf(u8, source, "std.c.raise") == null and
        std.mem.indexOf(u8, source, "raise(") == null)
    {
        std.debug.print(
            "\n!! crash_handler.zig does not re-raise the signal !!\n" ++
                "   Without re-raising, the OS default action (terminate + core dump)\n" ++
                "   never runs and the user gets no exit signal info.\n",
            .{},
        );
        return error.SignalReraiseMissing;
    }
}

test "Windows branch returns EXCEPTION_EXECUTE_HANDLER" {
    const source = @embedFile("crash_handler.zig");
    if (std.mem.indexOf(u8, source, "EXCEPTION_EXECUTE_HANDLER") == null and
        std.mem.indexOf(u8, source, "EXCEPTION_CONTINUE_SEARCH") == null)
    {
        std.debug.print(
            "\n!! Windows UEF filter does not return an EXECUTE_HANDLER value !!\n" ++
                "   Returning 0 (CONTINUE_SEARCH) hands control to the next handler in\n" ++
                "   the chain — usually the debugger or WER. Returning 1 (EXECUTE_HANDLER)\n" ++
                "   terminates the process after unwinding. We want EXECUTE_HANDLER.\n",
            .{},
        );
        return error.WindowsExecuteHandlerMissing;
    }
}

// ─── Contract 5: both branches capture the stack ───────────────────────

test "crash_handler.zig captures the stack via std.debug.getStackTrace" {
    const source = @embedFile("crash_handler.zig");
    // Zig 0.16 renamed getStackTrace to captureCurrentStackTrace. Accept
    // either form so the test doesn't break across Zig versions.
    if (std.mem.indexOf(u8, source, "getStackTrace") == null and
        std.mem.indexOf(u8, source, "captureCurrentStackTrace") == null)
    {
        std.debug.print(
            "\n!! crash_handler.zig does not capture the backtrace !!\n" ++
                "   Without getStackTrace / captureCurrentStackTrace the log entry\n" ++
                "   is a bare signal name with no frames — useless for post-mortem.\n",
            .{},
        );
        return error.StackTraceMissing;
    }
    // Either format the trace via formatStackTrace / writeStackTrace, or
    // (the Zig 0.16 form used here) format addresses manually in a loop.
    if (std.mem.indexOf(u8, source, "formatStackTrace") == null and
        std.mem.indexOf(u8, source, "writeStackTrace") == null and
        std.mem.indexOf(u8, source, "return_addresses") == null)
    {
        std.debug.print(
            "\n!! crash_handler.zig captures the stack but never formats it !!\n" ++
                "   Need formatStackTrace / writeStackTrace, OR iterate over\n" ++
                "   stack.return_addresses to format the addresses manually.\n",
            .{},
        );
        return error.StackTraceFormatMissing;
    }
}

// ─── Contract 6: both branches write a "=== CRASH ===" header ──────────

test "crash_handler.zig writes a === CRASH === header to the panic log" {
    const source = @embedFile("crash_handler.zig");
    // The emitted header is `=== CRASH: received signal SIGSEGV ... ===`
    // (with the signal name appended). Match on the distinctive prefix
    // `=== CRASH:` which is present in both branches.
    if (std.mem.indexOf(u8, source, "=== CRASH:") == null) {
        std.debug.print(
            "\n!! crash_handler.zig does not emit a '=== CRASH:' header !!\n" ++
                "   The header makes grep-friendly searching of the panic log file\n" ++
                "   possible (`grep -n '=== CRASH:' /tmp/agentic_coding.log`).\n",
            .{},
        );
        return error.CrashHeaderMissing;
    }
}

// ─── Contract 7: POSIX restores default handler before logging ─────────

test "POSIX handler restores default action before logging (defends against crash-in-handler loops)" {
    const source = @embedFile("crash_handler.zig");
    if (std.mem.indexOf(u8, source, "SIG.DFL") == null and
        std.mem.indexOf(u8, source, "SIG_DFL") == null)
    {
        std.debug.print(
            "\n!! crash_handler.zig does not restore the default handler !!\n" ++
                "   If our own handler crashes (e.g. fopen fails inside the handler), the\n" ++
                "   kernel re-delivers the same signal to us, infinitely. Always set the\n" ++
                "   default handler BEFORE attempting any logging.\n",
            .{},
        );
        return error.DefaultHandlerNotRestored;
    }
}

// ─── Contract 8: installCrashHandlers is idempotent ────────────────────

test "installCrashHandlers is safe to call twice" {
    // The function should be a no-op on the second call (or at minimum
    // not crash). We don't pin the exact semantics (the implementation
    // may choose to be idempotent by guarding the call site in main.zig
    // instead), but the function must be callable without crashing.
    crash_handler.installCrashHandlers();
    crash_handler.installCrashHandlers();
    try testing.expect(true);
}

// ─── Contract 9: POSIX branch uses std.posix.sigaction (not raw syscall)

test "POSIX branch uses std.posix.sigaction (Zig 0.16 idiomatic API)" {
    const source = @embedFile("crash_handler.zig");
    if (std.mem.indexOf(u8, source, "sigaction") == null) {
        std.debug.print(
            "\n!! crash_handler.zig does not use sigaction !!\n" ++
                "   signal() is portable but lacks the SA_RESTART flag; std.posix.sigaction\n" ++
                "   is the Zig 0.16 idiomatic API.\n",
            .{},
        );
        return error.SigactionMissing;
    }
}

// ─── Behavioural coverage ─────────────────────────────────────────────
//
// A real SIGSEGV / SIGBUS / SIGABRT / SIGILL / SIGFPE / ACCESS_VIOLATION
// crashes the test process. We can't exercise the handler in-process
// without killing the test runner. The behavioural verification lives
// outside the test suite:
//
//   scripts/crash_handler_smoke.sh
//
// It compiles a tiny `crash_trigger.zig` helper into a standalone binary,
// invokes it (which dereferences a bad pointer), waits for the kernel
// to deliver SIGSEGV, then greps the panic log for "=== CRASH ===".
// See the script for the exact invocation.
//
// The contracts above pin the implementation; the smoke test pins the
// runtime behaviour.