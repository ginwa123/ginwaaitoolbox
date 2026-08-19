//! Portable sleep helper for tests that need to wait across the
//! second-granularity boundary of SQLite's `DATETIME` column (used
//! by `save_memory`, `agent_memories`, and `retry_delay_ms` tests
//! to ensure an UPDATE bumps `updated_at`).
//!
//! Zig 0.16's std.c.timespec is broken on Windows because the
//! upstream timespec switch in std/c.zig falls through to the
//! `else => void` arm — `time_t` is itself `void` on Windows
//! (`switch (native_os) { ..., else => void }`). Result: `timespec.sec`
//! is typed `void` on Windows and the test won't compile:
//!
//!   src\...\agent_memories.zig:563:31: error: expected type 'void',
//!                                          found 'comptime_int'
//!     var ts = std.c.timespec{ .sec = 1, .nsec = 0 };
//!
//! Windows doesn't have `nanosleep` in libc either. The Win32
//! equivalent is `Sleep` (kernel32.dll) which takes milliseconds.
//! This helper picks the right call per OS via comptime branches.
//!
//! Usage:
//!     const test_sleep = @import("test_sleep.zig");
//!     test_sleep.sleep(sec: u32, nsec: u32) void;
const std = @import("std");
const builtin = @import("builtin");

/// Sleep for at least `sec` seconds + `nsec` nanoseconds. Cross-platform.
pub fn sleep(sec: u32, nsec: u32) void {
    if (comptime builtin.os.tag == .windows) {
        sleepWindows(sec, nsec);
    } else {
        sleepPosix(sec, nsec);
    }
}

fn sleepWindows(sec: u32, nsec: u32) void {
    // Win32 Sleep takes a DWORD (u32) of milliseconds. Round UP — we
    // want at LEAST the requested duration, not less.
    const ms: u64 = @as(u64, sec) * 1_000 + @as(u64, nsec) / 1_000_000;
    // Sleep(0) yields the rest of the current time slice — close
    // enough to a "yield" semantics. Saturate at u32 max so a huge
    // `sec` doesn't wrap to 0.
    const ms_dword: u32 = if (ms == 0) 0 else std.math.cast(u32, ms) orelse std.math.maxInt(u32);
    // Win32 signature: void WINAPI Sleep(DWORD dwMilliseconds);
    // (DWORD == u32). Use `callconv(.winapi)` + uppercase `Sleep` to
    // match the project's existing kernel32 bindings pattern (see
    // src/helpers/mod.zig:86) — Zig's symbol name is case-sensitive at
    // the ABI level even though the COFF linker itself is case-
    // insensitive, so matching the conventional casing avoids a
    // spurious symbol-not-found on some linkers.
    //
    // The decl is nested inside a struct so the `extern "kernel32"`
    // linker string is only parsed on Windows. Putting it at module
    // scope would fail to compile on POSIX (kernel32.dll doesn't
    // exist — Zig refuses to recognise the linker string).
    const Sleep = struct {
        extern "kernel32" fn Sleep(dw_milliseconds: u32) callconv(.winapi) void;
    };
    Sleep.Sleep(ms_dword);
}

fn sleepPosix(sec: u32, nsec: u32) void {
    // POSIX: nanosleep with a 1-second + 0-nanosecond argument
    // covers the test's "bump DATETIME granularity" need.
    //
    // Zig 0.16's std.c.timespec SEC field type on POSIX is `time_t`
    // (a `c_long` alias) and NSEC is `c_long`. We cast to those
    // exact types so the struct literal type-checks on every POSIX
    // (Linux/BSD/macOS c_long=i64 — same signed width; the cast is
    // a no-op at runtime).
    const SecT = @TypeOf(@as(std.c.timespec, undefined).sec);
    const NsecT = @TypeOf(@as(std.c.timespec, undefined).nsec);
    var ts = std.c.timespec{
        .sec = @as(SecT, @intCast(sec)),
        .nsec = @as(NsecT, @intCast(nsec)),
    };
    _ = std.c.nanosleep(&ts, null);
}
