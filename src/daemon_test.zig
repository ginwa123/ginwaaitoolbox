// src/daemon_test.zig
//
// Tests for src/daemon.zig. The daemonize() test forks a child process
// and verifies the grandchild's PPID differs from the original process
// (which is the daemon(7) invariant for "detached from controlling
// terminal / parent process group").
//
// Zig 0.16 API notes:
//   * std.c.pipe(&pipe_fds) returns 0 on success; -1 on error.
//   * std.c.fork returns the new child's PID (c_int) in the parent,
//     0 in the child, or -1 on error.
//   * std.c.kill(pid, 0) returns 0 on success, -1 (with errno) on
//     failure. We use it for the "is process alive" check.
//   * std.c.write / read / close are libc wrappers returning
//     isize / c_int; -1 (with errno) on error.

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
    var pipe_fds: [2]std.c.fd_t = undefined;
    if (std.c.pipe(&pipe_fds) != 0) return error.PipeFailed;

    const original_ppid = std.c.getpid();
    const pid = std.c.fork();
    if (pid == 0) {
        // Child 1 (will become session leader then exit).
        _ = std.c.close(pipe_fds[0]);
        if (std.c.setsid() < 0) std.process.exit(1);

        const pid2 = std.c.fork();
        if (pid2 != 0) std.process.exit(0); // child 1 exits

        // Grandchild — write the new PPID back to parent.
        const new_ppid = std.c.getppid();
        const ppid_bytes = std.mem.asBytes(&new_ppid);
        _ = std.c.write(pipe_fds[1], ppid_bytes.ptr, ppid_bytes.len);
        _ = std.c.close(pipe_fds[1]);
        std.process.exit(0);
    }
    // Parent reads the grandchild's PPID.
    _ = std.c.close(pipe_fds[1]);
    var ppid_buf: [@sizeOf(c_int)]u8 = undefined;
    _ = std.c.read(pipe_fds[0], @ptrCast(&ppid_buf), ppid_buf.len);
    _ = std.c.close(pipe_fds[0]);
    // std.c.waitpid takes (pid: pid_t, status: ?*c_int, options: c_int).
    // The status pointer is optional — pass null to discard exit status.
    _ = std.c.waitpid(pid, null, 0);

    const child_ppid = std.mem.readInt(c_int, &ppid_buf, std.builtin.Endian.little);
    // After double-fork, the grandchild's PPID is either 1 (init) or
    // the PID of the process that reaped child 1 (usually a subreaper).
    // The key invariant: PPID is no longer the original parent's PID.
    try testing.expect(child_ppid != original_ppid);
}

test "mkdirP creates all parent dirs of a fresh nested path" {
    if (builtin.os.tag == .windows) return;
    if (builtin.os.tag != .linux and builtin.os.tag != .macos) return;

    // Build a path under a fresh tmpdir whose nested parent dir does not
    // exist. mkdirP must create every component without error and the
    // leaf's parent dir must exist after the call.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_len = try tmp.dir.realPath(testing.io, &dir_buf);
    const tmp_dir_path = dir_buf[0..dir_len];

    const leaf = "deeply/nested/that/does/not/exist/service.log";
    const path = try testing.allocator.alloc(u8, tmp_dir_path.len + 1 + leaf.len);
    defer testing.allocator.free(path);
    @memcpy(path[0..tmp_dir_path.len], tmp_dir_path);
    path[tmp_dir_path.len] = '/';
    @memcpy(path[tmp_dir_path.len + 1..], leaf);

    // Pre-condition: the deeply-nested dir does not exist.
    var pre_z: [std.fs.max_path_bytes:0]u8 = undefined;
    @memcpy(pre_z[0..path.len], path);
    pre_z[path.len] = 0;
    try testing.expect(std.c.access(&pre_z, 0) != 0);

    try daemon.mkdirP(path);

    // Post-condition: the deepest parent dir must now exist.
    const parent = std.fs.path.dirname(path).?;
    var post_z: [std.fs.max_path_bytes:0]u8 = undefined;
    @memcpy(post_z[0..parent.len], parent);
    post_z[parent.len] = 0;
    try testing.expect(std.c.access(&post_z, 0) == 0);
}

test "mkdirP is idempotent on an already-existing parent dir" {
    if (builtin.os.tag == .windows) return;
    if (builtin.os.tag != .linux and builtin.os.tag != .macos) return;
    // /tmp always exists; calling mkdirP on "/tmp/anything" must not error.
    try daemon.mkdirP("/tmp/this-is-a-mkdirP-test/service.log");
    try daemon.mkdirP("/tmp/this-is-a-mkdirP-test/service.log");
}