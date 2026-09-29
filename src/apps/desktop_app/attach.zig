// src/apps/desktop_app/attach.zig
//
// Desktop's "find nalar" logic (Chunk 4 of the decoupled-nalar-service plan).
//
// On launch, the desktop probes for a running nalar daemon that can serve
// the webapp and attaches the webview. If none is found and --no-auto-start
// is NOT set, the desktop spawns a detached nalar via `subprocess.spawn`
// and waits for it to come up.
//
// "Can serve the webapp" is deliberately stronger than "is running": a
// daemon answers /health with 200 even when its --static-dir no longer
// exists, and attaching to such a daemon opens the webview on
// `404 Not Found`. Every candidate must pass `probeWebapp` (2xx on GET /
// with an HTML body) before we hand it to the webview, and a freshly
// spawned child must pass it too before we return it.
//
// The desktop never signals nalar on close — closing the window does
// NOT stop the daemon. Only `nalar service stop` (a separate CLI
// invocation) ends the daemon's life.

const std = @import("std");
const builtin = @import("builtin");
const nalarcore = @import("nalarcore");
const helpers = @import("helpers");
const subprocess = @import("subprocess.zig");
const path_resolve = @import("path_resolve.zig");
const port = @import("port.zig");

pub const AttachOptions = struct {
    /// Path to the nalar state file (from `state_file.defaultStatePath`).
    /// The desktop reads this to find an existing daemon's host+port.
    state_path: []const u8,
    /// Port to probe as a fallback if no state file exists. Default 8081.
    default_port: u16 = 8081,
    /// When true, refuse to auto-spawn nalar if none is running; the
    /// caller surfaces an actionable error to the user.
    no_auto_start: bool = false,
    /// Path to the nalar binary (used by the auto-spawn path).
    /// Optional — when null, we attempt to spawn using `path_resolve`
    /// against the desktop's own location.
    nalar_path: ?[]const u8 = null,
    /// The desktop's own executable path. Used by `path_resolve` to
    /// check if `nalar` lives next to the desktop binary. Optional —
    /// when null, the auto-spawn path skips the "next-to-self"
    /// resolution strategy and goes straight to $PATH lookup.
    self_exe_path: ?[]const u8 = null,
    /// $PATH string (colon-separated on Unix). Required for the $PATH
    /// resolution strategy when `nalar_path` is null AND there's no
    /// nalar next to the desktop binary.
    path_env: []const u8 = "",
    /// Absolute path to the extracted webapp assets. When the auto-spawn
    /// path fires, the spawned nalar is started with `--static-dir <this>`
    /// so it serves the desktop's webapp at `/`. When attaching to an
    /// existing nalar, this field is ignored (the user manages their
    /// own nalar's static-dir). Always provided by main.zig; treat as
    /// non-null in the auto-spawn path.
    static_dir: []const u8 = "",
};

pub const AttachTarget = struct {
    host: []const u8,
    port: u16,
    /// Whether the desktop spawned a fresh daemon to satisfy this
    /// attach. `we_spawned = true` means the daemon outlives the
    /// desktop; `false` means we attached to one the user started
    /// independently.
    we_spawned: bool,
};

pub const AttachError = error{
    AutoStartDisabled,
    AutoSpawnFailed,
    NalarNotFound,
    OutOfMemory,
};

/// Probe state.json, then the default port, then auto-spawn as needed.
/// Returns the AttachTarget. Never returns "we_spawned=true" without
/// having actually launched a daemon — the caller can trust this.
///
/// A server is only attachable when it serves the WEBAPP (`probeWebapp`),
/// not merely when it answers `/health`. A daemon whose `--static-dir`
/// vanished is still "healthy" while answering `GET /` with
/// `404 Not Found`; attaching the webview to it is the blank-page bug
/// this guards against. When the only daemon around is unusable we fall
/// through to the auto-spawn path instead of giving up.
pub fn resolveAttachTarget(
    allocator: std.mem.Allocator,
    io: std.Io,
    opts: AttachOptions,
) AttachError!AttachTarget {
    // 1. State file: read it, check the pid is alive, probe the port.
    if (try nalarcore.state_file.readStateFile(allocator, io, opts.state_path)) |state| {
        defer nalarcore.state_file.freeState(allocator, state);
        if (isUsableWebappServer(state.host, state.port, io)) {
            // Caller now owns state.host — it outlives this function. We
            // can't pass a slice into a returned struct without making a
            // copy; for v1, copy the strings.
            const host_dup = try allocator.dupe(u8, state.host);
            errdefer allocator.free(host_dup);
            return .{
                .host = host_dup,
                .port = state.port,
                .we_spawned = false,
            };
        }
    }
    // 2. Fallback: probe the well-known port. The host string is
    //    duped so the caller can free it with the same allocator it
    //    would use for the state-file success path (matches the
    //    ownership convention — the returned AttachTarget is always
    //    caller-owned).
    if (isUsableWebappServer("127.0.0.1", opts.default_port, io)) {
        return .{
            .host = try allocator.dupe(u8, "127.0.0.1"),
            .port = opts.default_port,
            .we_spawned = false,
        };
    }
    // 3. Auto-spawn (unless disabled).
    if (opts.no_auto_start) return error.AutoStartDisabled;
    return try autoSpawnAndWaitForHealth(allocator, io, opts);
}

/// True when `port` hosts a nalar that actually serves the webapp.
/// Logs (loudly) why a merely-healthy server was rejected, because the
/// user's next question is always "my nalar is running, why did it
/// start a second one?".
fn isUsableWebappServer(host: []const u8, backend_port: u16, io: std.Io) bool {
    if (!probeHealth(host, backend_port, io)) return false;
    if (subprocess.probeWebapp(backend_port)) return true;
    std.log.warn(
        "nalar on port {d} is alive but does not serve the webapp at / (GET / is not HTML) — ignoring it",
        .{backend_port},
    );
    return false;
}

fn probeHealth(host: []const u8, backend_port: u16, io: std.Io) bool {
    _ = host;
    _ = io;
    // 1-second connect+GET /health probe. Returns true on 2xx, false
    // otherwise. Health alone is NOT enough to attach — see
    // `isUsableWebappServer`.
    return subprocess.probeHealth(backend_port);
}

fn autoSpawnAndWaitForHealth(
    allocator: std.mem.Allocator,
    io: std.Io,
    opts: AttachOptions,
) AttachError!AttachTarget {
    // 1. Resolve nalar's absolute path. Order is: explicit
    //    `--nalar-path` flag → next to self → $PATH lookup.
    const nalar_path = blk: {
        const explicit = opts.nalar_path orelse null;
        const self_exe = opts.self_exe_path orelse ".";
        const resolved = path_resolve.resolve(
            allocator,
            explicit,
            self_exe,
            opts.path_env,
        );
        break :blk resolved orelse {
            std.log.err("Cannot find 'nalar' binary.", .{});
            std.log.err("Hint: launch the desktop from a directory containing nalar, OR", .{});
            std.log.err("      run `nalar service start --port {d}` in a terminal first.", .{
                opts.default_port,
            });
            return error.NalarNotFound;
        };
    };
    defer allocator.free(nalar_path);

    // 2. Pick a port the child can actually bind. Prefer the well-known
    //    one (keeps 8081 / --attach-port working), but if something else
    //    holds it — typically a nalar that does not serve the webapp,
    //    which steps 1/2 above refused to attach to — take an ephemeral
    //    port instead. Spawning into an occupied port would fail to bind
    //    while the squatter's own `/health` kept answering our readiness
    //    probe, so we'd report success for a port we don't own.
    const spawn_port = chooseSpawnPort(allocator, io, opts.default_port);

    std.log.info("No usable nalar daemon found — spawning a new one at {s} --port {d} (static dir: {s})", .{
        nalar_path,
        spawn_port,
        if (opts.static_dir.len > 0) opts.static_dir else "(none)",
    });

    // 3. Spawn the child process. Pass `opts.static_dir` so the spawned
    //    nalar serves the webapp at `/`. If static_dir is empty (caller
    //    didn't provide one), `nalar` only serves API endpoints and the
    //    webapp check in step 5 below fails — which is the honest answer
    //    for a desktop that exists to show the webapp. In practice
    //    main.zig always populates this with a persistent dir.
    var child = subprocess.spawn(
        allocator,
        io,
        nalar_path,
        spawn_port,
        if (opts.static_dir.len > 0) opts.static_dir else null,
    ) catch |err| {
        std.log.err("Spawning nalar at {s} failed: {s}", .{ nalar_path, @errorName(err) });
        std.log.err("Hint: the desktop doesn't manage nalar's lifecycle.", .{});
        std.log.err("      If `nalar service start` is more reliable, prefer that.", .{});
        return error.AutoSpawnFailed;
    };

    // 4. Wait for /health to respond with 200. The child is now running;
    //    if the desktop closes, the child is NOT auto-terminated (that's
    //    the chunk 4 architectural commitment — desktop doesn't signal
    //    nalar on close). The child becomes a long-lived daemon the user
    //    has to stop manually via `nalar service stop` — which is
    //    precisely why its --static-dir must be a persistent directory.
    subprocess.waitForHealth(spawn_port, 5_000, 100) catch |err| {
        std.log.err("Spawned nalar but /health never came up: {s}", .{@errorName(err)});
        // Don't leak the orphan: kill it before bailing.
        child.terminate(io);
        return error.AutoSpawnFailed;
    };

    // 5. Verify the child can serve the APP, not just /health. Handing
    //    the webview a URL that 404s is exactly the bug this path exists
    //    to prevent, so fail loudly (and don't leave a useless daemon
    //    behind) instead of opening a blank window.
    if (!subprocess.probeWebapp(spawn_port)) {
        std.log.err(
            "Spawned nalar on port {d} but it does not serve the webapp at / — refusing to open a 404 window.",
            .{spawn_port},
        );
        std.log.err("Check that the webapp dir contains index.html and is readable.", .{});
        child.terminate(io);
        return error.AutoSpawnFailed;
    }

    // 6. Persist state.json so the NEXT launch finds this daemon via step 1
    //    instead of spawning a duplicate. Without this, every launch that
    //    lands on an ephemeral port is invisible to the next one (which
    //    only probes the state file + the well-known port), so each
    //    `--browser` click leaks another detached daemon — e.g. :51165
    //    then :8081 side by side. Best-effort: the daemon is already
    //    healthy and usable, so a write failure only warns.
    const state: nalarcore.state_file.State = .{
        .pid = child.pid,
        .port = spawn_port,
        .host = "127.0.0.1",
        .started_at = helpers.unixTimestamp(),
        .version = "0.4.0",
        .static_dir = if (opts.static_dir.len > 0) opts.static_dir else null,
    };
    nalarcore.state_file.writeStateFile(allocator, io, opts.state_path, state) catch |err| {
        std.log.warn(
            "Spawned nalar on port {d} but could not write state file {s}: {s} — the next launch may spawn a duplicate",
            .{ spawn_port, opts.state_path, @errorName(err) },
        );
    };

    return .{
        .host = try allocator.dupe(u8, "127.0.0.1"),
        .port = spawn_port,
        .we_spawned = true,
    };
}

/// Prefer `preferred` unless something is already listening there, in
/// which case hand back an ephemeral free port.
fn chooseSpawnPort(allocator: std.mem.Allocator, io: std.Io, preferred: u16) u16 {
    if (port.isFree(allocator, io, preferred)) return preferred;
    const free = port.findFree(allocator, io) catch {
        // Couldn't probe for a free port — try the preferred one anyway
        // rather than refusing to start at all.
        std.log.warn("Could not allocate a free port; trying {d} anyway", .{preferred});
        return preferred;
    };
    if (free.port == preferred) return preferred;
    // Tell the user how to get back to the well-known port — otherwise
    // every launch keeps spawning a fresh daemon on a random port because
    // the squatter never goes away. The spawned daemon's port is recorded
    // in the state file (step 6 of the auto-spawn path) so the next launch
    // attaches to it instead of spawning again.
    std.log.warn(
        "Port {d} is already in use by a server that does not serve the webapp; spawning on {d} instead",
        .{ preferred, free.port },
    );
    std.log.warn(
        "To stop that server and go back to port {d}, run:  nalar service stop  (or kill the process listening on {d})",
        .{ preferred, preferred },
    );
    return free.port;
}

// ===== Tests merged from attach_test.zig (2026-09-29 flatten) =====
// Tests for the desktop's "find nalar" logic.
//
// These tests stand up a real loopback HTTP server on a kernel-picked port
// whose responses are path-aware, plus a hand-rolled state.json, so the
// resolve/probe plumbing is exercised over a real socket without depending
// on whether a nalar binary happens to exist on the host. See
// subprocess.zig for the same pattern (kernel-picked port + accept
// loop in a background thread).
//
// The regression these lock in: a server that answers `GET /health` with
// 200 but `GET /` with 404 must NEVER be handed to the webview. That shape
// is exactly what a daemon whose `--static-dir` was deleted looks like —
// the desktop attached to it and rendered a blank "404 Not Found" page.

const testing = std.testing;

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
    // Named `bound_port`, not `port`: this file's module scope already has
    // `const port = @import("port.zig")` and Zig rejects a local that
    // shadows a container-level declaration.
    const bound_port = std.mem.bigToNative(u16, assigned.port);

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

    return .{ .fd = fd, .port = bound_port, .thread = thread, .stop_flag = stop_flag };
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
    port_num: u16,
) ![]u8 {
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_len = try tmp.dir.realPath(testing.io, &dir_buf);
    const path = try std.fs.path.join(allocator, &.{ dir_buf[0..dir_len], "state.json" });
    errdefer allocator.free(path);

    const json = try std.fmt.allocPrint(
        allocator,
        \\{{"pid":{d},"port":{d},"host":"127.0.0.1","started_at":0,"version":"x","static_dir":null}}
    ,
        .{ std.c.getpid(), port_num },
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
    const result = try resolveAttachTarget(allocator, testing.io, .{
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
    const result = resolveAttachTarget(allocator, testing.io, .{
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
    const result = try resolveAttachTarget(allocator, testing.io, .{
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

    const result = resolveAttachTarget(allocator, testing.io, .{
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

    const result = resolveAttachTarget(allocator, testing.io, .{
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
    const first = try resolveAttachTarget(allocator, testing.io, .{
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
    const second = try resolveAttachTarget(allocator, testing.io, .{
        .state_path = state_path,
        .default_port = squatter.port,
        .no_auto_start = true,
    });
    defer allocator.free(second.host);
    try testing.expect(!second.we_spawned);
    try testing.expectEqual(first.port, second.port);
}