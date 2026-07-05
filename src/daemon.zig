// src/daemon.zig
//
// Cross-platform daemonization for the nalar service. On POSIX we use
// the classic double-fork + setsid pattern (per Linux daemon(7)).
// On Windows we use CreateProcess with DETACHED_PROCESS.
//
// The chunk-1 tests that exercise fork/setsid directly are deliberately
// skipped on Windows (the daemon.zig skeleton for Windows is a
// @compileError stub for v1; tracked as a follow-up).
//
// Zig 0.16 API notes:
//   * std.c.fork / setsid are libc wrappers (cross-platform) — the
//     std.os.linux.* equivalents are Linux-syscall-only and fail on
//     macOS where the syscall numbers differ.
//   * fork returns the new child's PID (c_int) in the parent, 0 in
//     the child, or -1 on error.
//   * setsid returns 0 on success, -1 on error.

const std = @import("std");
const builtin = @import("builtin");

pub const DaemonError = error{
    ForkFailed,
    SessionFailed,
    OpenLogFailed,
    MkdirFailed,
    PathTooLong,
};

/// POSIX daemonization: double-fork + setsid. After this returns, the
/// caller is the grandchild (the actual daemon). The original process
/// and the intermediate child have already exited.
///
/// IMPORTANT: this function never returns in the parent paths. It only
/// returns in the grandchild. Callers must NOT depend on receiving a
/// return value to do post-fork work in the parent.
///
/// This function does NOT redirect stdio or change cwd. Call
/// `redirectStdioToLog` afterwards.
///
/// Uses std.c.fork / std.c.setsid (libc wrappers, cross-platform)
/// rather than std.os.linux.fork / std.os.linux.setsid (Linux syscall
/// numbers — wrong on macOS, where the syscall numbers are different).
/// std.c.fork returns c_int: child PID in parent, 0 in child, -1 on error.
pub fn daemonizePosix() DaemonError!void {
    if (builtin.os.tag == .windows) {
        @compileError("daemonizePosix is POSIX-only; use daemonizeWindows on Windows");
    }

    // First fork.
    const pid1 = std.c.fork();
    if (pid1 < 0) return error.ForkFailed;
    if (pid1 > 0) std.process.exit(0); // parent exits immediately

    // In child 1: become session leader.
    if (std.c.setsid() < 0) return error.SessionFailed;

    // Second fork — daemon is no longer session leader, so it can never
    // reacquire a controlling terminal (Linux daemon(7) idiom).
    const pid2 = std.c.fork();
    if (pid2 < 0) return error.ForkFailed;
    if (pid2 > 0) std.process.exit(0); // child 1 exits

    // Grandchild returns. Caller continues here.
}

/// Walk the parent directory chain of `path` and mkdirat each missing
/// component (idempotent: ignores EEXIST). Used by the daemon's
/// redirectStdioToLog to make a fresh `$HOME` work without manual
/// `mkdir -p`. Extracted as a separate function so it can be unit-tested
/// without the stdio redirection side effect.
pub fn mkdirP(path: []const u8) !void {
    if (builtin.os.tag == .windows) {
        @compileError("mkdirP is POSIX-only");
    }
    const parent_dir = std.fs.path.dirname(path) orelse return;
    if (parent_dir.len == 0) return;
    // std.fs.path.componentIterator yields `Component{ .name, .path }` where
    // `.path` is the CUMULATIVE path-so-far (e.g. for "/a/b/c", second
    // component is `.name="b" .path="/a/b"`). Use `.path` directly so we
    // don't have to reconstruct the slash-joined string ourselves.
    //
    // Use std.c.mkdirat (libc wrapper, cross-platform) instead of
    // std.os.linux.mkdirat (Linux syscall number only — wrong on macOS).
    // On Linux AT.FDCWD == -100; on macOS it is -2. The libc layer
    // resolves the value at compile time via the switch in std.c.AT.
    // std.c.mkdirat returns 0 on success, -1 on failure (with errno set).
    var iter = std.fs.path.componentIterator(parent_dir);
    while (iter.next()) |component| {
        var prefix_z: [std.fs.max_path_bytes:0]u8 = undefined;
        if (component.path.len >= prefix_z.len) return error.PathTooLong;
        @memcpy(prefix_z[0..component.path.len], component.path);
        prefix_z[component.path.len] = 0;
        const rc = std.c.mkdirat(std.c.AT.FDCWD, &prefix_z, 0o755);
        if (rc != 0) {
            const err = std.c.errno(rc);
            if (err != .EXIST) return error.MkdirFailed;
        }
    }
}

/// Redirect stdin from /dev/null and stdout/stderr to a log file. Call
/// AFTER `daemonizePosix()` returns. The log file is opened with
/// O_CREAT|O_APPEND so multiple daemon lifetimes (restart cycles)
/// preserve history. Walks the parent directory chain and mkdirat's
/// each missing component (idempotent: ignores EEXIST) so that a fresh
/// `$HOME` (no `~/.local/share/nalar/` yet) works.
pub fn redirectStdioToLog(log_path: []const u8) !void {
    if (builtin.os.tag == .windows) {
        @compileError("redirectStdioToLog is POSIX-only");
    }

    // NUL-terminated copy of log_path for the open syscall.
    var log_path_z: [std.fs.max_path_bytes:0]u8 = undefined;
    if (log_path.len >= log_path_z.len) return error.PathTooLong;
    @memcpy(log_path_z[0..log_path.len], log_path);
    log_path_z[log_path.len] = 0;

    // mkdir -p the parent directory. Without this, a fresh $HOME has
    // no ~/.local/share/nalar/ and the open() below fails.
    try mkdirP(log_path);

    // stdin → /dev/null. std.c.open returns fd_t (i32) on success,
    // -1 on failure (with errno set). We discard the error here —
    // a missing /dev/null is "weird but not fatal" for the daemon.
    const devnull_fd: std.c.fd_t = std.c.open("/dev/null", .{ .ACCMODE = .RDONLY }, 0);
    if (devnull_fd >= 0) {
        _ = std.c.dup2(devnull_fd, 0);
        _ = std.c.close(devnull_fd);
    }

    // stdout/stderr → log_path (append). Use the cross-platform std.c.O
    // packed struct (same field names as std.os.linux.O: ACCMODE, CREAT,
    // APPEND) which compiles identically on Linux and macOS via libc.
    const log_fd: std.c.fd_t = std.c.open(&log_path_z, .{
        .ACCMODE = .WRONLY,
        .CREAT = true,
        .APPEND = true,
    }, 0o644);
    if (log_fd < 0) return error.OpenLogFailed;
    _ = std.c.dup2(log_fd, 1);
    _ = std.c.dup2(log_fd, 2);
    _ = std.c.close(log_fd);
}

/// Check if a process is alive via kill(pid, 0). Returns true for any
/// of: (a) process exists and we can signal it, (b) process exists but
/// we lack permission to signal it (EPERM).
///
/// Returns false if the process does not exist (ESRCH) or the pid is
/// invalid (≤ 0).
pub fn pidAlive(pid: i32) bool {
    if (pid <= 0) return false;
    // libc kill() accepts signal 0 (the "null signal") as a probe for
    // existence/permissions without actually delivering a signal.
    // Zig's std.c.SIG enum doesn't expose signal 0 as a named member,
    // so we @enumFromInt it from 0.
    const rc = std.c.kill(pid, @as(std.c.SIG, @enumFromInt(0)));
    if (rc == 0) return true;
    const errno_val = std.c.errno(rc);
    return errno_val == .PERM;
}