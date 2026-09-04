// src/service/crash_handler_test.zig
//
// Tests for src/service/crash_handler.zig (crash signal/exception handler).
//
// A real crash handler can't be exercised in-process — SIGSEGV / SIGBUS
// / SIGABRT / SIGILL / SIGFPE / ACCESS_VIOLATION all terminate the
// process. So this file tests the handler's pure building blocks
// BEHAVIORALLY (call the function, assert on the returned value), not
// via source-text contracts. End-to-end verification (a child process
// that really crashes) lives outside the test suite:
//
//   scripts/crash_handler_smoke.sh
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

// ─── signalDescription: one-liner per crash signal ────────────────────

test "signalDescription names each crash signal" {
    try testing.expect(std.mem.indexOf(u8, crash_handler.signalDescription(std.c.SIG.SEGV), "invalid memory reference") != null);
    // SIGBUS doesn't exist on Windows (see crash_handler.zig) — skip.
    if (comptime builtin.os.tag != .windows) {
        try testing.expect(std.mem.indexOf(u8, crash_handler.signalDescription(std.c.SIG.BUS), "bus error") != null);
    }
    try testing.expect(std.mem.indexOf(u8, crash_handler.signalDescription(std.c.SIG.ABRT), "abort") != null);
    try testing.expect(std.mem.indexOf(u8, crash_handler.signalDescription(std.c.SIG.ILL), "illegal instruction") != null);
    try testing.expect(std.mem.indexOf(u8, crash_handler.signalDescription(std.c.SIG.FPE), "arithmetic") != null);
}

// ─── siCodeMeaning: hardware sub-reason decoding ──────────────────────

test "siCodeMeaning decodes hardware sub-reasons" {
    const SEGV = std.c.SIG.SEGV;
    try testing.expect(std.mem.indexOf(u8, crash_handler.siCodeMeaning(SEGV, 1), "MAPERR") != null);
    try testing.expect(std.mem.indexOf(u8, crash_handler.siCodeMeaning(SEGV, 2), "ACCERR") != null);
    if (comptime builtin.os.tag != .windows) {
        try testing.expect(std.mem.indexOf(u8, crash_handler.siCodeMeaning(std.c.SIG.BUS, 1), "ADRALN") != null);
    }
    try testing.expect(std.mem.indexOf(u8, crash_handler.siCodeMeaning(std.c.SIG.ILL, 1), "ILLOPC") != null);
    try testing.expect(std.mem.indexOf(u8, crash_handler.siCodeMeaning(std.c.SIG.FPE, 1), "INTDIV") != null);
}

test "siCodeMeaning treats non-positive codes as sender codes" {
    // kill()/raise()/abort()-delivered signals carry a sender identity
    // (SI_TKILL=-6, SI_USER=0), not a hardware sub-reason. The decoder
    // must say so instead of "unknown SEGV code".
    const SEGV = std.c.SIG.SEGV;
    try testing.expect(std.mem.indexOf(u8, crash_handler.siCodeMeaning(SEGV, -6), "sender") != null);
    try testing.expect(std.mem.indexOf(u8, crash_handler.siCodeMeaning(SEGV, 0), "sender") != null);
    try testing.expect(std.mem.indexOf(u8, crash_handler.siCodeMeaning(std.c.SIG.ABRT, -6), "sender") != null);
}

// ─── classifyFaultAddr: address buckets ───────────────────────────────

test "classifyFaultAddr buckets fault addresses" {
    try testing.expectEqualStrings("NULL dereference", crash_handler.classifyFaultAddr(0));
    try testing.expect(std.mem.indexOf(u8, crash_handler.classifyFaultAddr(0x10), "near-NULL") != null);
    try testing.expect(std.mem.indexOf(u8, crash_handler.classifyFaultAddr(0x5000), "low address") != null);
    try testing.expect(std.mem.indexOf(u8, crash_handler.classifyFaultAddr(0xdeadbeef), "wild/unmapped") != null);
}

// ─── faultAddrFromSiginfo / siCodeFromSiginfo: siginfo extraction ─────

test "faultAddrFromSiginfo and siCodeFromSiginfo extract siginfo fields" {
    // Linux-only: the test constructs the Linux siginfo_t shape
    // (fields.sigfault.addr). Other platforms have a different layout.
    if (builtin.os.tag != .linux) return error.SkipZigTest;

    var info = std.mem.zeroes(std.posix.siginfo_t);
    info.code = 1;
    info.fields = .{ .sigfault = .{
        .addr = @ptrFromInt(0xdeadbeef),
        .addr_lsb = 0,
        .first = .{ .pkey = 0 },
    } };

    try testing.expectEqual(@as(usize, 0xdeadbeef), crash_handler.faultAddrFromSiginfo(&info));
    try testing.expectEqual(@as(i32, 1), crash_handler.siCodeFromSiginfo(&info));
}

// ─── formatRawAddrs: deterministic hex formatting ─────────────────────

test "formatRawAddrs formats one hex line per address" {
    const addrs = [_]usize{ 0x1, 0xabcdef };
    const out = crash_handler.formatRawAddrs(testing.allocator, &addrs);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("  0x0000000000000001\n  0x0000000000abcdef\n", out);
}

test "formatRawAddrs of empty trace is empty" {
    const out = crash_handler.formatRawAddrs(testing.allocator, &.{});
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("", out);
}

// ─── symbolicateStack: DWARF symbolication ────────────────────────────

test "symbolicateStack returns null for an empty trace" {
    // writeStackTrace prints "(empty stack trace)" for zero frames —
    // the helper treats that as "no symbolication", not a section.
    const empty: std.debug.StackTrace = .{ .return_addresses = &.{}, .skipped = .none };
    try testing.expect(crash_handler.symbolicateStack(testing.allocator, &empty) == null);
}

test "symbolicateStack symbolicates a live trace" {
    // Capture a real stack in-test and symbolicate it. In a Debug
    // build with debug info this must succeed and mention addresses;
    // the smoke script covers the in-handler path end-to-end.
    var addr_buf: [16]usize = undefined;
    const stack = std.debug.captureCurrentStackTrace(.{}, &addr_buf);
    try testing.expect(stack.return_addresses.len > 0);
    const sym = crash_handler.symbolicateStack(testing.allocator, &stack) orelse {
        // Stripped/ReleaseFast binary without DWARF — nothing to check.
        if (builtin.mode != .Debug) return error.SkipZigTest;
        try testing.expect(false); // Debug must symbolicate
        return;
    };
    defer testing.allocator.free(sym);
    try testing.expect(std.mem.indexOf(u8, sym, "0x") != null);
}

// ─── Behavioural coverage (out-of-process) ────────────────────────────
//
//   scripts/crash_handler_smoke.sh
//
// It compiles a tiny `crash_trigger.zig` helper into a standalone binary,
// invokes it (which dereferences a bad pointer), waits for the kernel
// to deliver SIGSEGV, then greps the panic log for "=== CRASH ===".
// See the script for the exact invocation.
