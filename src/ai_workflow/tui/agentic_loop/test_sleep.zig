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
const helpers = @import("helpers");

// Win32 kernel32 `Sleep` — declared at module scope to match the
// project's existing pattern (src/helpers/mod.zig:86). The decl is
// a no-op at link time on POSIX — kernel32.dll only exists on Windows
// — and the call site is guarded by `builtin.os.tag` so the linker
// never sees an unresolved Sleep symbol on POSIX.
extern "kernel32" fn Sleep(dw_milliseconds: u32) callconv(.winapi) void;

/// Sleep for at least `sec` seconds + `nsec` nanoseconds. Cross-platform.
pub fn sleep(sec: u32, nsec: u32) void {
    if (comptime builtin.os.tag == .windows) {
        // Win32 Sleep takes a DWORD (u32) of milliseconds. Round UP —
        // we want at LEAST the requested duration, not less.
        const ms: u64 = @as(u64, sec) * 1_000 + @as(u64, nsec) / 1_000_000;
        // Sleep(0) yields the rest of the current time slice — close
        // enough to a "yield" semantics. Saturate at u32 max so a huge
        // `sec` doesn't wrap to 0.
        const ms_dword: u32 = if (ms == 0) 0 else std.math.cast(u32, ms) orelse std.math.maxInt(u32);
        Sleep(ms_dword);
    } else {
        sleepPosix(sec, nsec);
    }
}

fn sleepPosix(sec: u32, nsec: u32) void {
    // POSIX: nanosleep with a 1-second + 0-nanosecond argument
    // covers the test's "bump DATETIME granularity" need.
    //
    // We use the project-wide `helpers.PosixTimespec` struct
    // (defined in src/helpers/mod.zig) — its fields are typed
    // `Clong` (an i64 on POSIX, i32 on Windows) but `@intCast` to
    // the field's actual type (inferred from the struct decl) keeps
    // the cast portable without spelling out the alias here.
    var ts: helpers.PosixTimespec = .{
        .sec = @intCast(sec),
        .nsec = @intCast(nsec),
    };
    _ = helpers.nanosleep(&ts, null);
}
