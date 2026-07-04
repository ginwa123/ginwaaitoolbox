// src/apps/desktop_app/attach_test.zig
//
// Tests for the desktop's "find nalar" logic.
//
// These tests use a raw-syscall mock HTTP server (kernel-picked port)
// and a hand-rolled state.json so the resolve/probe plumbing can be
// exercised without depending on whether a real nalar daemon happens
// to be running on the host. See subprocess_test.zig for the same
// pattern (kernel-picked port + accept-loop in a thread) — extracted
// rather than shared to keep the modules independently testable.

const std = @import("std");
const testing = std.testing;
const builtin = @import("builtin");
const nalarcore = @import("nalarcore");
const attach = @import("attach.zig");

/// Bind a TCP socket on 127.0.0.1:0, listen, run a one-shot accept loop
/// in a background thread that writes a single HTTP 200 response for
/// any incoming request, and return the kernel-picked port + the
/// thread handle (caller is responsible for joining it).
///
/// Returns `null` on any setup failure (the caller should treat this
/// as a deferred error so test bodies can stay focused on the
/// assertion shape).
fn bindMockHealthServer() !struct { port: u16, thread: std.Thread } {
    const fd_rc = std.os.linux.socket(
        std.os.linux.AF.INET,
        std.os.linux.SOCK.STREAM,
        0,
    );
    if (fd_rc > std.math.maxInt(i32)) return error.TestSetupFailed;
    const fd: i32 = @intCast(fd_rc);

    // SO_REUSEADDR so the kernel doesn't hold the port in TIME_WAIT
    // after the test exits (lets consecutive test runs reuse the port).
    const one: c_int = 1;
    _ = std.os.linux.setsockopt(
        fd,
        std.os.linux.SOL.SOCKET,
        std.os.linux.SO.REUSEADDR,
        @ptrCast(&one),
        @sizeOf(c_int),
    );

    var bind_addr = std.os.linux.sockaddr.in{ .port = 0, .addr = 0x0100007F };
    const bind_rc = std.os.linux.bind(
        fd,
        @ptrCast(&bind_addr),
        @sizeOf(std.os.linux.sockaddr.in),
    );
    if (bind_rc != 0) {
        _ = std.os.linux.close(fd);
        return error.TestSetupFailed;
    }

    var assigned: std.os.linux.sockaddr.in = undefined;
    var addr_len: std.os.linux.socklen_t = @sizeOf(std.os.linux.sockaddr.in);
    _ = std.os.linux.getsockname(fd, @ptrCast(&assigned), &addr_len);
    const port = std.mem.bigToNative(u16, assigned.port);

    const listen_rc = std.os.linux.listen(fd, 4);
    if (listen_rc != 0) {
        _ = std.os.linux.close(fd);
        return error.TestSetupFailed;
    }

    const thread = try std.Thread.spawn(.{}, struct {
        fn run(server_fd: i32) void {
            // Two accepts: one for the health probe, one extra in case
            // resolveAttachTarget probes twice (state file + fallback
            // port). Each accept → write 200 → close.
            var accepts_left: u8 = 4;
            while (accepts_left > 0) : (accepts_left -= 1) {
                const conn_rc = std.os.linux.accept(server_fd, null, null);
                if (conn_rc > std.math.maxInt(i32)) continue;
                const conn_fd: i32 = @intCast(conn_rc);
                const resp = "HTTP/1.0 200 OK\r\nContent-Length: 2\r\n\r\nOK";
                _ = std.os.linux.write(conn_fd, resp.ptr, resp.len);
                _ = std.os.linux.close(conn_fd);
            }
            _ = std.os.linux.close(server_fd);
        }
    }.run, .{fd});

    // Give the server thread time to enter accept() before the client
    // attempts to connect (without this, a fast client can win the race
    // against listen()).
    var ts: std.posix.timespec = .{ .sec = 0, .nsec = 50 * std.time.ns_per_ms };
    _ = std.c.nanosleep(&ts, null);

    return .{ .port = port, .thread = thread };
}

test "resolveAttachTarget returns state-file port when probe succeeds" {
    if (builtin.os.tag == .windows) return; // mock server uses raw linux syscalls
    const allocator = testing.allocator;

    // 1. Stand up a mock /health server on a kernel-picked port. We'll
    // point the state file at this port so probeHealth should succeed.
    var srv = try bindMockHealthServer();
    defer srv.thread.join();

    // 2. Write a state.json pointing at the mock server. We use a
    // different port in the JSON than the file's "host" implies —
    // probeHealth ignores the host and uses port only, but we keep
    // them consistent for realism.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_len = try tmp.dir.realPath(testing.io, &dir_buf);
    const tmp_dir_path = dir_buf[0..dir_len];

    const path = try allocator.alloc(u8, tmp_dir_path.len + 1 + "state.json".len);
    defer allocator.free(path);
    @memcpy(path[0..tmp_dir_path.len], tmp_dir_path);
    path[tmp_dir_path.len] = '/';
    @memcpy(path[tmp_dir_path.len + 1..], "state.json");

    const json = try std.fmt.allocPrint(allocator,
        \\{{"pid":{d},"port":{d},"host":"127.0.0.1","started_at":0,"version":"x","static_dir":null}}
    , .{ std.c.getpid(), srv.port });
    defer allocator.free(json);

    try std.Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = path, .data = json });

    // 3. resolveAttachTarget should read the state file, probe the
    // mock server, and return with the state file's port+host. The
    // --no-auto-start flag short-circuits the auto-spawn fallback so
    // we don't need a real nalar binary on disk.
    const result = try attach.resolveAttachTarget(allocator, testing.io, .{
        .state_path = path,
        .default_port = srv.port, // a different fallback (not used)
        .no_auto_start = true,
    });
    defer allocator.free(result.host);
    try testing.expectEqual(@as(u16, srv.port), result.port);
    try testing.expectEqualStrings("127.0.0.1", result.host);
    try testing.expect(!result.we_spawned);
}

test "resolveAttachTarget returns AutoStartDisabled when --no-auto-start and no nalar" {
    if (builtin.os.tag == .windows) return;
    const allocator = testing.allocator;

    // Use a tmp path that does NOT exist; the read returns null
    // immediately. The fallback port (65535) is unreachable. With
    // --no-auto-start, the helper returns AutoStartDisabled without
    // ever consulting autoSpawnAndWaitForHealth.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_len = try tmp.dir.realPath(testing.io, &dir_buf);
    const tmp_dir_path = dir_buf[0..dir_len];

    const path = try allocator.alloc(u8, tmp_dir_path.len + 1 + "state.json".len);
    defer allocator.free(path);
    @memcpy(path[0..tmp_dir_path.len], tmp_dir_path);
    path[tmp_dir_path.len] = '/';
    @memcpy(path[tmp_dir_path.len + 1..], "state.json");

    const result = attach.resolveAttachTarget(allocator, testing.io, .{
        .state_path = path,
        .default_port = 65535,
        .no_auto_start = true,
    });
    try testing.expectError(error.AutoStartDisabled, result);
}
