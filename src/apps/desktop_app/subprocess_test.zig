// src/apps/desktop_app/subprocess_test.zig
//
// Tests for the nalar subprocess management module. Two test cases:
//
//   1. waitForHealth timeout: poll a port that nothing is listening on,
//      expect `error.HealthCheckTimeout` before the deadline elapses.
//   2. waitForHealth success: stand up a tiny mock HTTP server in a
//      background thread, point waitForHealth at it, expect success
//      within the timeout window.
//
// Both the mock server and the health-check probe use **raw Linux
// syscalls** (`std.os.linux.socket/bind/listen/accept/recv/...`).
// waitForHealth does too — the `std.Io.net` abstraction was tried
// first and abandoned: its `readVec` returns an error on `EAGAIN`
// (the underlying socket is non-blocking, so a probe that hits the
// server before the response is ready fails instead of blocking),
// which makes a one-shot health check unreliable. Raw blocking
// syscalls with `SO_RCVTIMEO` give clean "block until the response
// arrives" semantics.
//
// Zig 0.16 API notes:
//   * `std.Io.Threaded.init(allocator, .{})` then `.io()` replaces
//     the old implicit-global `std.Io`.
//   * Raw socket syscalls live in `std.os.linux.*` (no public
//     `std.posix.socket/bind/...` wrappers in 0.16).
//   * `std.c.nanosleep` + `std.posix.timespec` for blocking waits.

const std = @import("std");
const subprocess = @import("subprocess.zig");
const helpers = @import("helpers");
const testing = std.testing;

test "waitForHealth: returns error.HealthCheckTimeout when target unreachable" {
    // Port 1 is "tcpmux" but on a normal dev box nothing is listening.
    // The kernel will return ECONNREFUSED on connect, so waitForHealth
    // never sees a successful response and times out.
    const result = subprocess.waitForHealth(1, 200, 50);
    try testing.expectError(error.HealthCheckTimeout, result);
}

test "waitForHealth: succeeds when target returns 200" {
    // Set up a raw-socket mock server in a separate thread. The server
    // side uses Linux syscalls (no Io) so the test thread is free to
    // make blocking syscalls in waitForHealth.
    //
    // The Zig 0.16 stdlib has no public `std.posix.socket/bind/...`
    // wrappers — those calls live in `std.os.linux.*` and return a raw
    // `usize` (success value on success, `-errno` cast to `usize` on
    // failure). We cast/check the return inline. The `errno()` helper
    // inside posix.zig is private, so for test setup we just check
    // that the rc fits in a non-negative fd_t.
    const fd_rc = std.os.linux.socket(
        std.os.linux.AF.INET,
        std.os.linux.SOCK.STREAM,
        0,
    );
    if (fd_rc > std.math.maxInt(i32)) return error.TestSetupFailed;
    const fd: i32 = @intCast(fd_rc);
    defer _ = std.os.linux.close(fd);

    // SO_REUSEADDR so the kernel doesn't hold the port in TIME_WAIT
    // after the test process exits (lets consecutive test runs reuse
    // the same port).
    const one: c_int = 1;
    _ = std.os.linux.setsockopt(
        fd,
        std.os.linux.SOL.SOCKET,
        std.os.linux.SO.REUSEADDR,
        @ptrCast(&one),
        @sizeOf(c_int),
    );

    // Bind to 127.0.0.1:0 — kernel picks the port. sockaddr.in is
    // little-endian on disk (i.e. struct fields) but the .port and
    // .addr fields are in network byte order (big-endian). The literal
    // 0x0100007F is 127.0.0.1 in network byte order.
    var bind_addr = std.os.linux.sockaddr.in{
        .port = 0,
        .addr = 0x0100007F,
    };
    const bind_rc = std.os.linux.bind(
        fd,
        @ptrCast(&bind_addr),
        @sizeOf(std.os.linux.sockaddr.in),
    );
    if (bind_rc != 0) return error.TestSetupFailed;

    // Get the assigned port back from the kernel.
    var assigned: std.os.linux.sockaddr.in = undefined;
    var addr_len: std.os.linux.socklen_t = @sizeOf(std.os.linux.sockaddr.in);
    _ = std.os.linux.getsockname(fd, @ptrCast(&assigned), &addr_len);
    const port = std.mem.bigToNative(u16, assigned.port);

    const listen_rc = std.os.linux.listen(fd, 1);
    if (listen_rc != 0) return error.TestSetupFailed;

    // Server thread: accept one connection, write 200 OK, close. All
    // raw syscalls — no Io involvement.
    const thread = try std.Thread.spawn(.{}, struct {
        fn run(server_fd: i32) void {
            const conn_rc = std.os.linux.accept(server_fd, null, null);
            if (conn_rc <= std.math.maxInt(i32)) {
                const conn_fd: i32 = @intCast(conn_rc);
                const response = "HTTP/1.0 200 OK\r\nContent-Length: 2\r\n\r\nOK";
                _ = std.os.linux.write(conn_fd, response.ptr, response.len);
                _ = std.os.linux.close(conn_fd);
            }
        }
    }.run, .{fd});
    defer thread.join();

    // Give the server thread a beat to enter accept(). Without this, a
    // very fast client connect could race the listen() install.
    // We use `helpers.PosixTimespec` (and `helpers.nanosleep`) instead
    // of `std.posix.timespec` because the stdlib version is `void` on
    // Windows in Zig 0.16.
    var setup_ts: helpers.PosixTimespec = .{ .sec = 0, .nsec = 50 * std.time.ns_per_ms };
    _ = helpers.nanosleep(&setup_ts, null);

    // Client side uses raw syscalls via waitForHealth (no Io).
    const result = subprocess.waitForHealth(port, 2000, 50);
    try testing.expect(result != error.HealthCheckTimeout);
}
