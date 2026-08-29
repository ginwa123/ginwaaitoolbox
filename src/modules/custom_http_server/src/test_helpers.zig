// src/modules/custom_http_server/src/test_helpers.zig
//
// Cross-platform test helpers for the custom_http_server test suite.
// Tests that need to create connected socket pairs, cast fd_t → i32
// for the production API, or call Windows-only kernel32 functions
// (CreatePipe) get their primitives from here so the per-file
// duplication stays minimal.
//
// All OS branches are gated with `comptime if` so the runtime path
// for Linux/macOS is bit-identical to the prior POSIX code — no
// behavioral change on those platforms.

const std = @import("std");
const posix = std.posix;
const builtin = @import("builtin");

/// Windows-only kernel32 CreatePipe shim. The kernel32 import library
/// IS shipped with Zig's MinGW toolchain, so this just-works without
/// an extra linkSystemLibrary call. The libc `pipe` doesn't exist on
/// Windows MSVCRT (it has `_pipe` instead), but Zig doesn't ship a
/// msvcrt import lib, so `_pipe` would fail with "DLL import library
/// for -lmsvcrt not found". CreatePipe is the portable cross-platform
/// path.
const win = if (builtin.os.tag == .windows) struct {
    extern "kernel32" fn CreatePipe(
        hReadPipe: ?*std.os.windows.HANDLE,
        hWritePipe: ?*std.os.windows.HANDLE,
        lpPipeAttributes: ?*anyopaque,
        nSize: c_uint,
    ) callconv(.winapi) c_int;
} else struct {};

/// Create a pair of connected fds for tests. Cross-platform:
/// socketpair(AF_UNIX, SOCK_STREAM) on POSIX; CreatePipe on Windows
/// (no AF_UNIX socketpair(2) in Winsock).
///
/// Returns `[2]std.c.fd_t` — `i32` on POSIX, `*anyopaque` (HANDLE)
/// on Windows. Tests that need to pass these into the production
/// SseManager API (which still takes `i32` everywhere) cast via
/// `toI32` below.
///
/// Convention: `fds[0]` is the WRITE end (write here, read from the
/// other side); `fds[1]` is the READ end. POSIX socketpair returns
/// bidirectional sockets so the convention is enforced by the caller;
/// Windows CreatePipe is unidirectional (fds[0] = read end of the
/// returned handle), so we SWAP them here to match the POSIX caller
/// convention. Without the swap, tests that do `write(fds[0]); read(fds[1])`
/// would block on Windows because they're writing to a read-only end.
pub fn createSocketPair() ![2]std.c.fd_t {
    if (comptime builtin.os.tag == .windows) {
        var fds: [2]std.c.fd_t = undefined;
        var read_h: std.os.windows.HANDLE = undefined;
        var write_h: std.os.windows.HANDLE = undefined;
        const ok = win.CreatePipe(&read_h, &write_h, null, 4096);
        if (ok == 0) return error.PipeFailed;
        fds[0] = @ptrCast(write_h); // Write end first (POSIX convention)
        fds[1] = @ptrCast(read_h);  // Read end second
        return fds;
    } else {
        var fds: [2]std.c.fd_t = undefined;
        const rc = posix.system.socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0, &fds);
        if (rc < 0) return error.SocketFailed;
        return fds;
    }
}

/// Close both ends of a pair created by createSocketPair. Cross-platform
/// via std.c.close (POSIX `close` on Linux/macOS, MSVCRT `_close` on
/// Windows).
pub fn closeSocketPair(pair: [2]std.c.fd_t) void {
    _ = std.c.close(pair[0]);
    _ = std.c.close(pair[1]);
}

/// Cast an fd_t to the i32 that the production SseManager API still
/// expects. On Linux/macOS this is a no-op (fd_t is i32). On Windows
/// HANDLE values are small integers assigned sequentially by the kernel
/// (typically < 2^31) so @intCast is safe for testing; if Windows ever
/// returns a >2^31 handle the test would crash here, which is the
/// correct signal that the production API needs an fd_t migration.
pub fn toI32(fd: std.c.fd_t) i32 {
    if (comptime builtin.os.tag == .windows) {
        return @intCast(@intFromPtr(fd));
    } else {
        return @intCast(fd);
    }
}

/// Close an fd with cross-platform handling. Use this for sock_fds
/// from `Address.init` (which is `SocketFd = i32`) instead of
/// `std.c.close(addr.sock_fd)` directly — std.c.close on Windows takes
/// fd_t (= *anyopaque) and a plain i32 wouldn't compile.
///
/// On Linux/macOS this is a no-op cast; on Windows it wraps the
/// small integer into the fd_t pointer type via @ptrFromInt + bitCast.
pub fn closeI32Fd(fd: i32) void {
    _ = std.c.close(if (comptime builtin.os.tag == .windows)
        @ptrFromInt(@as(usize, @bitCast(@as(isize, fd))))
    else
        @intCast(fd));
}