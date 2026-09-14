// src/apps/desktop_app/attach_test.zig
//
// Tests for the desktop's "find nalar" logic.
//
// These tests stand up a real loopback HTTP server on a kernel-picked port
// whose responses are path-aware, plus a hand-rolled state.json, so the
// resolve/probe plumbing is exercised over a real socket without depending
// on whether a nalar binary happens to exist on the host. See
// subprocess_test.zig for the same pattern (kernel-picked port + accept
// loop in a background thread).
//
// The regression these lock in: a server that answers `GET /health` with
// 200 but `GET /` with 404 must NEVER be handed to the webview. That shape
// is exactly what a daemon whose `--static-dir` was deleted looks like —
// the desktop attached to it and rendered a blank "404 Not Found" page.

const std = @import("std");
const testing = std.testing;
const builtin = @import("builtin");
const nalarcore = @import("nalarcore");
const attach = @import("attach.zig");
const subprocess = @import("subprocess.zig");

/// What the mock server pretends to be.
const MockKind = enum {
    /// A working nalar: 200 + HTML at `/`, 200 at `/health`.
    full_app,
    /// The broken shape: 200 at `/health`, `404 Not Found` at `/`.
    health_only,
};

const MockServer = struct {
    fd: i32,
    port: u16,
    thread: std.Thread,
    stop_flag: *std.atomic.Value(bool),

    /// Stop the accept loop deterministically. The loop polls the listening
    /// socket with a timeout and checks the flag, so this always returns
    /// (no relying on shutdown()/close() to wake a blocked accept()).
    fn stop(self: *MockServer) void {
        self.stop_flag.store(true, .release);
        self.thread.join();
        _ = std.os.linux.close(self.fd);
        testing.allocator.destroy(self.stop_flag);
    }
};

/// Bind 127.0.0.1:0, listen, and serve requests in a background thread
/// according to `kind`. Returns the kernel-picked port + the thread handle.
fn bindMockServer(kind: MockKind) !MockServer {
    const fd_rc = std.os.linux.socket(
        std.os.linux.AF.INET,
        std.os.linux.SOCK.STREAM,
        0,
    );
    if (fd_rc > std.math.maxInt(i32)) return error.TestSetupFailed;
    const fd: i32 = @intCast(fd_rc);

    // SO_REUSEADDR so the kernel doesn't hold the port in TIME_WAIT after
    // the test exits (lets consecutive test runs reuse the port).
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

    const listen_rc = std.os.linux.listen(fd, 8);
    if (listen_rc != 0) {
        _ = std.os.linux.close(fd);
        return error.TestSetupFailed;
    }

    const stop_flag = try testing.allocator.create(std.atomic.Value(bool));
    stop_flag.* = std.atomic.Value(bool).init(false);

    const thread = try std.Thread.spawn(.{}, struct {
        fn run(server_fd: i32, mock_kind: MockKind, flag: *std.atomic.Value(bool)) void {
            while (!flag.load(.acquire)) {
                // Poll first so the stop flag is observed even when no
                // client ever connects again.
                var pfd = [_]std.posix.pollfd{.{
                    .fd = server_fd,
                    .events = std.posix.POLL.IN,
                    .revents = 0,
                }};
                const ready = std.posix.poll(&pfd, 50) catch continue;
                if (ready == 0) continue;

                const conn_rc = std.os.linux.accept(server_fd, null, null);
                switch (std.posix.errno(conn_rc)) {
                    .SUCCESS => {},
                    // Spurious wakeups: keep serving.
                    .INTR, .AGAIN => continue,
                    // Anything else (including the loop being torn down):
                    // give up rather than spin.
                    else => return,
                }
                const conn_fd: i32 = @intCast(conn_rc);
                serveOne(conn_fd, mock_kind);
                _ = std.os.linux.close(conn_fd);
            }
        }
    }.run, .{ fd, kind, stop_flag });

    // Give the thread time to enter poll()/accept() before the client
    // attempts to connect (without this, a fast client can win the race
    // against listen()).
    var ts: std.posix.timespec = .{ .sec = 0, .nsec = 50 * std.time.ns_per_ms };
    _ = std.c.nanosleep(&ts, null);

    return .{ .fd = fd, .port = port, .thread = thread, .stop_flag = stop_flag };
}

/// Read the request line, then answer according to `kind`. `/health` is
/// always 200 — the point of these fixtures is that health alone is not
/// a sufficient signal.
fn serveOne(conn_fd: i32, kind: MockKind) void {
    var req: [512]u8 = undefined;
    var req_len: usize = 0;
    while (req_len < req.len) {
        const n_rc = std.os.linux.read(conn_fd, req[req_len..].ptr, req.len - req_len);
        if (n_rc <= 0) break;
        req_len += @intCast(n_rc);
        if (std.mem.indexOf(u8, req[0..req_len], "\r\n\r\n") != null) break;
    }
    const wants_health = std.mem.indexOf(u8, req[0..req_len], "/health") != null;

    const resp: []const u8 = if (wants_health)
        "HTTP/1.0 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nOK"
    else if (kind == .full_app)
        "HTTP/1.0 200 OK\r\nContent-Type: text/html\r\nContent-Length: 21\r\nConnection: close\r\n\r\n<!DOCTYPE html><html>"
    else
        "HTTP/1.0 404 Not Found\r\nContent-Length: 9\r\nConnection: close\r\n\r\nNot Found";
    _ = std.os.linux.write(conn_fd, resp.ptr, resp.len);
}

/// Write a state.json into `tmp`'s dir and return its owned absolute path.
fn writeStateFile(
    allocator: std.mem.Allocator,
    tmp: *std.testing.TmpDir,
    port: u16,
) ![]u8 {
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_len = try tmp.dir.realPath(testing.io, &dir_buf);
    const path = try std.fs.path.join(allocator, &.{ dir_buf[0..dir_len], "state.json" });
    errdefer allocator.free(path);

    const json = try std.fmt.allocPrint(
        allocator,
        \\{{"pid":{d},"port":{d},"host":"127.0.0.1","started_at":0,"version":"x","static_dir":null}}
    ,
        .{ std.c.getpid(), port },
    );
    defer allocator.free(json);

    try std.Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = path, .data = json });
    return path;
}

/// Fake `nalar` binary used by the auto-spawn test. It binds the port in
/// `--port`, answers every request with 200 + HTML (so both the health poll
/// and the webapp check pass), and exits on its own after a few seconds so
/// the test cannot leak a process.
///
/// Exposed as a script rather than a stub executable so the test exercises
/// the real spawn path: argv shape, readiness polling, and the post-spawn
/// "does it actually serve the app?" verification.
const fake_nalar_script =
    \\#!/usr/bin/env python3
    \\import socket, sys, time
    \\
    \\argv = sys.argv[1:]
    \\port = int(argv[argv.index("--port") + 1])
    \\
    \\srv = socket.socket()
    \\srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    \\srv.bind(("127.0.0.1", port))
    \\srv.listen(8)
    \\srv.settimeout(0.5)
    \\
    \\body = b"<!DOCTYPE html><html><body>fake nalar</body></html>"
    \\headers = (
    \\    b"HTTP/1.0 200 OK\r\nContent-Type: text/html\r\nContent-Length: "
    \\    + str(len(body)).encode()
    \\    + b"\r\nConnection: close\r\n\r\n"
    \\)
    \\
    \\deadline = time.time() + 5.0
    \\while time.time() < deadline:
    \\    try:
    \\        conn, _addr = srv.accept()
    \\    except socket.timeout:
    \\        continue
    \\    try:
    \\        conn.recv(4096)
    \\        conn.sendall(headers + body)
    \\    except Exception:
    \\        pass
    \\    finally:
    \\        conn.close()
    \\srv.close()
    \\
;

/// Materialise `fake_nalar_script` in `tmp`'s dir, mark it executable, and
/// return its owned absolute path.
fn writeFakeNalar(allocator: std.mem.Allocator, tmp: *std.testing.TmpDir) ![]u8 {
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_len = try tmp.dir.realPath(testing.io, &dir_buf);
    const path = try std.fs.path.join(allocator, &.{ dir_buf[0..dir_len], "fake-nalar" });
    errdefer allocator.free(path);

    try std.Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = path, .data = fake_nalar_script });

    var path_buf: [std.fs.max_path_bytes:0]u8 = undefined;
    if (path.len >= path_buf.len) return error.PathTooLong;
    @memcpy(path_buf[0..path.len], path);
    path_buf[path.len] = 0;
    if (std.c.chmod(&path_buf, 0o755) != 0) return error.ChmodFailed;
    return path;
}

fn fileExists(path: []const u8) bool {
    var buf: [std.fs.max_path_bytes:0]u8 = undefined;
    if (path.len >= buf.len) return false;
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;
    return std.c.access(&buf, std.c.F_OK) == 0;
}

test "probeWebapp: 200 + HTML is servable, 200 /health + 404 at / is not" {
    if (builtin.os.tag == .windows) return; // mock server uses raw linux syscalls
    var app = try bindMockServer(.full_app);
    defer app.stop();
    var broken = try bindMockServer(.health_only);
    defer broken.stop();

    // Both look healthy to the old check...
    try testing.expect(subprocess.probeHealth(app.port));
    try testing.expect(subprocess.probeHealth(broken.port));

    // ...but only the real one can serve the app.
    try testing.expect(subprocess.probeWebapp(app.port));
    try testing.expect(!subprocess.probeWebapp(broken.port));
}

test "resolveAttachTarget attaches to a daemon that serves the webapp" {
    if (builtin.os.tag == .windows) return;
    const allocator = testing.allocator;

    var srv = try bindMockServer(.full_app);
    defer srv.stop();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const state_path = try writeStateFile(allocator, &tmp, srv.port);
    defer allocator.free(state_path);

    // --no-auto-start short-circuits the spawn fallback so the test needs
    // no nalar binary on disk; a successful attach is the only way to get
    // a target back.
    const result = try attach.resolveAttachTarget(allocator, testing.io, .{
        .state_path = state_path,
        .default_port = srv.port,
        .no_auto_start = true,
    });
    defer allocator.free(result.host);
    try testing.expectEqual(@as(u16, srv.port), result.port);
    try testing.expectEqualStrings("127.0.0.1", result.host);
    try testing.expect(!result.we_spawned);
}

test "resolveAttachTarget refuses a daemon whose static dir is gone (health 200, / 404)" {
    if (builtin.os.tag == .windows) return;
    const allocator = testing.allocator;

    // This is the exact shape of the reported bug: a detached nalar whose
    // --static-dir was deleted. /health is 200, / is 404 Not Found.
    var srv = try bindMockServer(.health_only);
    defer srv.stop();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const state_path = try writeStateFile(allocator, &tmp, srv.port);
    defer allocator.free(state_path);

    // With auto-start disabled the only acceptable outcomes are "error" —
    // attaching would mean opening the webview onto a 404 page.
    const result = attach.resolveAttachTarget(allocator, testing.io, .{
        .state_path = state_path,
        .default_port = srv.port,
        .no_auto_start = true,
    });
    try testing.expectError(error.AutoStartDisabled, result);
}

test "resolveAttachTarget falls through to a fresh spawn when the only daemon 404s /" {
    if (builtin.os.tag == .windows) return;
    if (!fileExists("/usr/bin/env")) return error.SkipZigTest; // fake nalar needs python3
    const allocator = testing.allocator;

    var srv = try bindMockServer(.health_only);
    defer srv.stop();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const state_path = try writeStateFile(allocator, &tmp, srv.port);
    defer allocator.free(state_path);

    // Stand-in for the real nalar binary: a script that binds the --port it
    // is given and answers everything with 200 + HTML, then exits on its own
    // so the test can't leak a process.
    const fake_nalar = try writeFakeNalar(allocator, &tmp);
    defer allocator.free(fake_nalar);

    // Auto-start is ON and the only daemon around 404s `/`. The desktop must
    // skip that daemon and spawn its own on a DIFFERENT port — the port the
    // squatter holds can't be bound, and its /health would have masked the
    // failure.
    const result = try attach.resolveAttachTarget(allocator, testing.io, .{
        .state_path = state_path,
        .default_port = srv.port,
        .no_auto_start = false,
        .nalar_path = fake_nalar,
    });
    defer allocator.free(result.host);

    try testing.expect(result.we_spawned);
    try testing.expect(result.port != srv.port);

    // The returned target must actually serve the app — that is the whole
    // contract: the webview is only ever pointed at an app-serving URL.
    try testing.expect(subprocess.probeWebapp(result.port));

    // The unusable daemon must have been left alone, not killed.
    try testing.expect(subprocess.probeHealth(srv.port));
}

test "resolveAttachTarget refuses a 404-ing daemon on the fallback port too" {
    if (builtin.os.tag == .windows) return;
    const allocator = testing.allocator;

    var srv = try bindMockServer(.health_only);
    defer srv.stop();

    // No state file at all: the code falls back to probing the well-known
    // port, which is where the leftover daemon from the previous launch
    // lives.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_len = try tmp.dir.realPath(testing.io, &dir_buf);
    const state_path = try std.fs.path.join(allocator, &.{ dir_buf[0..dir_len], "absent.json" });
    defer allocator.free(state_path);

    const result = attach.resolveAttachTarget(allocator, testing.io, .{
        .state_path = state_path,
        .default_port = srv.port,
        .no_auto_start = true,
    });
    try testing.expectError(error.AutoStartDisabled, result);
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
    const path = try std.fs.path.join(allocator, &.{ dir_buf[0..dir_len], "state.json" });
    defer allocator.free(path);

    const result = attach.resolveAttachTarget(allocator, testing.io, .{
        .state_path = path,
        .default_port = 65535,
        .no_auto_start = true,
    });
    try testing.expectError(error.AutoStartDisabled, result);
}

test "auto-spawn persists state.json so the next launch attaches instead of spawning" {
    if (builtin.os.tag == .windows) return;
    if (!fileExists("/usr/bin/env")) return error.SkipZigTest; // fake nalar needs python3
    const allocator = testing.allocator;

    // Squatter on the well-known port: healthy but serves no webapp, so the
    // first launch must skip it and spawn its own daemon on an ephemeral
    // port (the :51165 half of the reported bug).
    var squatter = try bindMockServer(.health_only);
    defer squatter.stop();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_len = try tmp.dir.realPath(testing.io, &dir_buf);
    const state_path = try std.fs.path.join(allocator, &.{ dir_buf[0..dir_len], "state.json" });
    defer allocator.free(state_path);

    const fake_nalar = try writeFakeNalar(allocator, &tmp);
    defer allocator.free(fake_nalar);

    // First launch: no state file, well-known port unusable → spawn.
    const first = try attach.resolveAttachTarget(allocator, testing.io, .{
        .state_path = state_path,
        .default_port = squatter.port,
        .no_auto_start = false,
        .nalar_path = fake_nalar,
    });
    defer allocator.free(first.host);
    try testing.expect(first.we_spawned);
    try testing.expect(first.port != squatter.port);

    // The spawn must have recorded itself: the state file on disk points at
    // the freshly spawned port. Without this, the next launch only probes
    // the state file (stale/missing) + the well-known port and spawns a
    // SECOND daemon (the :8081 half of the reported bug).
    const recorded = try nalarcore.state_file.readStateFile(allocator, testing.io, state_path);
    try testing.expect(recorded != null);
    const state = recorded.?;
    defer nalarcore.state_file.freeState(allocator, state);
    try testing.expectEqual(first.port, state.port);

    // Second launch: with auto-start disabled (so a spawn is impossible),
    // the desktop must attach to the recorded daemon — proving the state
    // file alone is enough to avoid a duplicate.
    const second = try attach.resolveAttachTarget(allocator, testing.io, .{
        .state_path = state_path,
        .default_port = squatter.port,
        .no_auto_start = true,
    });
    defer allocator.free(second.host);
    try testing.expect(!second.we_spawned);
    try testing.expectEqual(first.port, second.port);
}
