// src/service/crash_handler_test.zig
//
// Tests for src/service/crash_handler.zig (crash signal/exception handler).
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
// Plan: docs/superpowers/plans/2026-04-08-crash-signal-handler.md

const std = @import("std");
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
