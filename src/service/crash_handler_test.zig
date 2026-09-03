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

// ─── Better-logger contracts (2026-09-03) ─────────────────────────────
//
// The 2026-09-03 upgrade replaced the raw-hex-only dump with a
// symbolicated report (function + file:line via writeStackTrace, fault
// address + si_code via SA_SIGINFO). These static-contract tests embed
// the implementation source and assert the key mechanisms are present —
// a future refactor that silently drops symbolication or the siginfo
// handler fails closed here instead of regressing to bare addresses.

const impl_src = @embedFile("crash_handler.zig");

test "crash handler symbolicates via writeStackTrace" {
    // The handler must attempt DWARF symbolication, not just print raw
    // hex. If this substring disappears, the log regresses to the
    // pre-2026-09-03 "0x..."-only output the user complained about.
    try testing.expect(std.mem.indexOf(u8, impl_src, "writeStackTrace") != null);
}

test "crash handler uses SA_SIGINFO for fault address" {
    // Without SA_SIGINFO the kernel only delivers the signal number —
    // no si_addr, no si_code, no answer to "WHY did it crash".
    try testing.expect(std.mem.indexOf(u8, impl_src, "SIGINFO") != null);
    try testing.expect(std.mem.indexOf(u8, impl_src, "sigaction") != null);
}

test "crash handler reports fault address and si_code meaning" {
    try testing.expect(std.mem.indexOf(u8, impl_src, "Fault address") != null);
    try testing.expect(std.mem.indexOf(u8, impl_src, "si_code") != null);
    try testing.expect(std.mem.indexOf(u8, impl_src, "SEGV_MAPERR") != null);
}

test "crash handler keeps raw-hex addr2line fallback" {
    // Symbolication can fail (stripped binary, no DWARF) — the raw
    // addresses must ALWAYS be emitted alongside, with an addr2line hint.
    try testing.expect(std.mem.indexOf(u8, impl_src, "addr2line") != null);
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
