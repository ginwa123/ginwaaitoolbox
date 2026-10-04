//! Cross-platform process management helpers.
//!
//! Provides portable wrappers around the platform-specific APIs for
//! checking process existence, sending signals, and terminating processes.
//!
//! ## Why this module exists
//!
//! Zig 0.16 changed how process management works cross-platform:
//!
//! 1. **`std.posix.kill`** is gated to POSIX-only targets — on Windows
//!    it triggers a `@compileError` because `std.c.pid_t` is `*anyopaque`
//!    on Windows (Windows has no real "PID" concept in its libc layer).
//!
//! 2. **`std.posix.getcwd`** was removed entirely (Zig 0.16 deleted it
//!    as part of the `std.Io` migration). The replacement requires an
//!    `Io` runtime (`std.Io.Dir.cwd().realPath(io, &buf)`), but many
//!    callers don't have an `Io` in scope — `std.c.getcwd` is the
//!    libc-backed fallback that works without `Io`.
//!
//! 3. **`std.posix.setsockopt`** has a comptime `@compileError("use std.Io
//!    instead")` on Windows — it's not callable cross-platform.
//!
//! This module centralises the platform switch so call sites stay simple:
//!
//! ```zig
//! const ps = pabrikcore.helpers.process_status;
//! if (ps.isProcessRunning(1234)) { ... }
//! const ok = ps.killProcess(1234);  // SIGKILL on POSIX, TerminateProcess on Windows
//! ```
//!
//! ## Platform behavior
//!
//! | Function            | Linux                       | macOS                  | Windows                              |
//! |---------------------|-----------------------------|------------------------|--------------------------------------|
//! | `isProcessRunning`  | `c.kill(pid, 0) == 0`       | `c.kill(pid, 0) == 0`  | `OpenProcess(QUERY_LIMITED) != NULL` |
//! | `killProcess`       | `c.kill(pid, SIGKILL) == 0` | same as Linux          | `TerminateProcess(handle, 1)`        |
//! | `getCurrentProcessIdInt` | `c.getpid()`           | same                    | `GetCurrentProcessId()`              |
//!
//! All functions are safe to call on any platform; the platform switch
//! happens at comptime.

const std = @import("std");
const builtin = @import("builtin");

/// Returns true if a process with the given PID exists and is accessible.
///
/// On Linux/macOS, this is implemented as `kill(pid, 0)` which returns 0
/// if the process exists (and we have permission to signal it) and a
/// non-zero errno otherwise. EPERM (permission denied) is treated as
/// "running" because the process DOES exist — we just can't signal it.
///
/// On Windows, this opens the process with `PROCESS_QUERY_LIMITED_INFORMATION`
/// access (the minimum needed to check existence) and immediately closes
/// the handle. Returns false if the PID doesn't exist OR the caller
/// doesn't have access permission to query it.
pub fn isProcessRunning(pid: i32) bool {
    if (pid <= 0) return false;

    return switch (builtin.os.tag) {
        .linux, .macos => isProcessRunningPosix(pid),
        .windows => isProcessRunningWindows(pid),
        else => @compileError("process_status: unsupported platform " ++ @tagName(builtin.os.tag)),
    };
}

fn isProcessRunningPosix(pid: i32) bool {
    // kill(pid, 0) is a no-op signal that just checks if we can signal the
    // process. Returns 0 on success (process exists + we have permission),
    // -1 with errno=ESRCH if process doesn't exist, or -1 with errno=EPERM
    // if process exists but we can't signal it. Treat both "0" and "EPERM"
    // as "running" — the process exists in both cases.
    const result = std.c.kill(@intCast(pid), @as(std.c.SIG, @enumFromInt(0)));
    if (result == 0) return true;
    // EPERM: process exists but we can't signal it. Still "running".
    const err = std.c.errno(result);
    return err == .PERM;
}

fn isProcessRunningWindows(pid: i32) bool {
    // PROCESS_QUERY_LIMITED_INFORMATION (0x1000) is the minimum access
    // needed to check if a process exists and read a few properties.
    // bInheritHandle=FALSE (0). Returns NULL if the PID doesn't exist
    // or the caller doesn't have access.
    const handle = OpenProcess(WINDOWS_PROCESS_QUERY_LIMITED_INFORMATION, 0, @intCast(pid));
    if (handle == null) return false;
    _ = CloseHandle(handle.?);
    return true;
}

/// Forcefully terminates a process with the given PID.
///
/// On Linux/macOS, sends SIGKILL (signal 9) which cannot be caught or
/// ignored by the target process. This is the equivalent of "kill -9
/// <pid>" from the shell.
///
/// On Windows, opens the process with `PROCESS_TERMINATE` access and
/// calls `TerminateProcess` with exit code 1.
///
/// Returns true on success (signal sent / process terminated), false if
/// the process doesn't exist or we don't have permission to terminate it.
pub fn killProcess(pid: i32) bool {
    if (pid <= 0) return false;

    return switch (builtin.os.tag) {
        .linux, .macos => killProcessPosix(pid),
        .windows => killProcessWindows(pid),
        else => @compileError("process_status: unsupported platform " ++ @tagName(builtin.os.tag)),
    };
}

fn killProcessPosix(pid: i32) bool {
    // SIGKILL = 9. Cannot be caught/ignored/blocked.
    const result = std.c.kill(@intCast(pid), @as(std.c.SIG, @enumFromInt(9)));
    return result == 0;
}

fn killProcessWindows(pid: i32) bool {
    // OpenProcess returns NULL if PID doesn't exist or we don't have access.
    const handle = OpenProcess(WINDOWS_PROCESS_TERMINATE, 0, @intCast(pid));
    if (handle == null) return false;
    // TerminateProcess returns nonzero on success, 0 on failure.
    const ok = TerminateProcess(handle.?, 1) != 0;
    _ = CloseHandle(handle.?);
    return ok;
}

/// Returns the current process's PID as an `i32`.
///
/// On POSIX, returns `getpid()`. On Windows, returns
/// `GetCurrentProcessId()` (DWORD = u32, cast to i32 — Windows PIDs
/// are positive and well within i32 range on real systems).
///
/// This is the integer-returning version of `helpers.process.getCurrentProcessId`
/// (which returns `std.c.pid_t` and is *not* directly comparable to
/// `i32` on Windows because `std.c.pid_t` is `*anyopaque` there). Use
/// this function from code that needs to compare PIDs as integers
/// (e.g. `if (target_pid == self_pid)`).
pub fn getCurrentProcessIdInt() i32 {
    return switch (builtin.os.tag) {
        // POSIX: std.c.getpid returns pid_t = i32. The cast is a no-op.
        .linux, .macos => @intCast(std.c.getpid()),
        // Windows: std.c.pid_t is *anyopaque (Windows libc has no real pid_t).
        // Use the Win32 GetCurrentProcessId() which returns DWORD = u32.
        .windows => @intCast(std.os.windows.GetCurrentProcessId()),
        else => @compileError("process_status: unsupported platform " ++ @tagName(builtin.os.tag)),
    };
}

// === Windows-only API declarations ===
// These live in kernel32.dll which is part of the default Windows API
// set — Zig auto-links it. We can't use @cImport because the Windows
// SDK headers have circular includes that 0.16's clang can't parse;
// declaring just the three functions we need is much simpler and
// works for all Windows targets (msvc, gnu, llvm).

const WINDOWS_PROCESS_QUERY_LIMITED_INFORMATION: u32 = 0x1000;
const WINDOWS_PROCESS_TERMINATE: u32 = 0x0001;

extern "c" fn OpenProcess(dwDesiredAccess: u32, bInheritHandle: u32, dwProcessId: u32) ?*anyopaque;
extern "c" fn TerminateProcess(hProcess: *anyopaque, uExitCode: u32) i32;
extern "c" fn CloseHandle(hObject: *anyopaque) i32;

// === Tests ===

test "isProcessRunning: current process is always running" {
    const self_pid = getCurrentProcessIdInt();
    try std.testing.expect(isProcessRunning(self_pid));
}

test "isProcessRunning: pid 0 is invalid" {
    try std.testing.expect(!isProcessRunning(0));
}

test "isProcessRunning: negative pid is invalid" {
    try std.testing.expect(!isProcessRunning(-1));
}

test "isProcessRunning: extremely high pid doesn't exist" {
    // Real PIDs rarely exceed 2^22. Use 2^30 to be safe on all platforms.
    try std.testing.expect(!isProcessRunning(1 << 30));
}

test "killProcess: pid 0 is invalid" {
    try std.testing.expect(!killProcess(0));
}

test "killProcess: negative pid is invalid" {
    try std.testing.expect(!killProcess(-1));
}

test "killProcess: extremely high pid doesn't exist" {
    try std.testing.expect(!killProcess(1 << 30));
}

test "getCurrentProcessIdInt returns positive int" {
    const pid = getCurrentProcessIdInt();
    try std.testing.expect(pid > 0);
}
