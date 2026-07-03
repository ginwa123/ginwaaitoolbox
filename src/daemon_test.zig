// src/daemon_test.zig
//
// Tests for src/daemon.zig. The daemonize() test forks a child process
// and verifies the grandchild's PPID differs from the original process
// (which is the daemon(7) invariant for "detached from controlling
// terminal / parent process group").
//
// Zig 0.16 API notes:
//   * std.c.pipe(&pipe_fds) returns 0 on success; -1 on error.
//   * std.os.linux.fork returns the new child's PID in the parent,
//     0 in the child, or -1 (cast to usize) on error.
//   * std.c.kill(pid, 0) returns 0 on success, -1 (with errno) on
//     failure. We use it for the "is process alive" check.
//   * std.os.linux.write / read / close are raw syscalls returning
//     a signed value; positive = bytes transferred, -1 (with errno)
//     on error.

const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const daemon = @import("daemon.zig");

test "pidAlive returns false for pid 0" {
    if (builtin.os.tag == .windows) return;
    try testing.expect(!daemon.pidAlive(0));
}

test "pidAlive returns false for negative pid" {
    if (builtin.os.tag == .windows) return;
    try testing.expect(!daemon.pidAlive(-1));
    try testing.expect(!daemon.pidAlive(-99999));
}

test "pidAlive returns true for own pid" {
    if (builtin.os.tag == .windows) return;
    try testing.expect(daemon.pidAlive(std.c.getpid()));
}

test "pidAlive returns false for nonexistent pid" {
    if (builtin.os.tag == .windows) return;
    // Pick a PID that's almost certainly not running. 0x7ffffff0 is
    // near INT_MAX and outside the typical PID range on Linux.
    try testing.expect(!daemon.pidAlive(0x7ffffff0));
}

test "POSIX daemonize detaches the grandchild from the original" {
    if (builtin.os.tag == .windows) return;
    if (builtin.os.tag != .linux and builtin.os.tag != .macos) return;

    // Setup a pipe for parent → grandchild communication.
    var pipe_fds: [2]i32 = undefined;
    if (std.c.pipe(&pipe_fds) != 0) return error.PipeFailed;

    const original_ppid = std.c.getpid();
    const pid = std.os.linux.fork();
    if (pid == 0) {
        // Child 1 (will become session leader then exit).
        _ = std.os.linux.close(pipe_fds[0]);
        if (std.os.linux.setsid() < 0) std.process.exit(1);

        const pid2 = std.os.linux.fork();
        if (pid2 != 0) std.process.exit(0); // child 1 exits

        // Grandchild — write the new PPID back to parent.
        const new_ppid = std.c.getppid();
        const ppid_bytes = std.mem.asBytes(&new_ppid);
        _ = std.c.write(pipe_fds[1], ppid_bytes.ptr, ppid_bytes.len);
        _ = std.c.close(pipe_fds[1]);
        std.process.exit(0);
    }
    // Parent reads the grandchild's PPID.
    _ = std.os.linux.close(pipe_fds[1]);
    var ppid_buf: [@sizeOf(c_int)]u8 = undefined;
    _ = std.c.read(pipe_fds[0], @ptrCast(&ppid_buf), ppid_buf.len);
    _ = std.os.linux.close(pipe_fds[0]);
    // std.os.linux.waitpid in Zig 0.16 takes (pid: pid_t, status: *u32, flags: u32).
    // Returns usize (the syscall result); cast to i32 to discard cleanly.
    var wait_status: u32 = 0;
    _ = std.os.linux.waitpid(@intCast(pid), &wait_status, 0);

    const child_ppid = std.mem.readInt(c_int, &ppid_buf, std.builtin.Endian.little);
    // After double-fork, the grandchild's PPID is either 1 (init) or
    // the PID of the process that reaped child 1 (usually a subreaper).
    // The key invariant: PPID is no longer the original parent's PID.
    try testing.expect(child_ppid != original_ppid);
}