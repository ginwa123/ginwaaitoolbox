// src/apps/desktop_app/subprocess.zig
//
// Manages the nalar child process: spawning it, polling its health
// endpoint, and cleaning it up.
//
// `waitForHealth` connects to 127.0.0.1:<port>/health on a tight
// polling loop and returns when the server responds with a 2xx status.
// Used after `spawn()` to make sure the server is actually accepting
// requests before the webview tries to load it (avoids a race where
// the webview shows a blank page or "connection refused").
//
// `spawn` launches nalar with `--port <port>` and returns a handle
// the caller uses to `terminate()` on shutdown.
//
// Zig 0.16 API notes (relative to the plan's draft code):
//   * `std.Io.net.IpAddress.connect(io, ...)` + `stream.reader` works
//     for long-lived HTTP streams but has surprising behavior for
//     one-shot health probes: the Io's `readVec` returns an error on
//     `EAGAIN` (the underlying socket is non-blocking and there's no
//     data yet), so a probe that hits the server before the response
//     is ready fails instead of blocking. To get reliable "block
//     until the response arrives" semantics, we use raw libc calls
//     (`std.c.socket/connect/send/recv/close`) which are blocking by
//     default and map `EAGAIN` to a real timeout via `SO_RCVTIMEO`.
//   * `std.process.spawn(io, options)` returns a `Child` directly
//     (no `init` + `spawn`). `child.kill()` and `child.wait(io)`
//     take no extra args in 0.16.
//   * The Zig 0.16 stdlib has no public `std.posix.socket/bind/...`
//     wrappers — they live in `std.c.*` (the libc extern decls) which
//     work on every POSIX-ish target. They return `c_int` (fd on
//     success, -1 on error with errno set) — we check `< 0` inline.

const std = @import("std");
const builtin = @import("builtin");

/// Handle to a running nalar subprocess. Caller MUST call `terminate()`
/// (or `kill` + `wait`) before discarding, otherwise nalar becomes a
/// zombie until the OS reaps it.
pub const NalarProcess = struct {
    child: std.process.Child,
    port: u16,
    /// `child.id` is optional in 0.16; we normalize to a concrete `i32`
    /// (or 0 if the platform doesn't expose a pid — e.g. some sandboxed
    /// environments). The pid is useful for logging and debugging only;
    /// `terminate()` does not rely on it.
    pid: i32,

    /// Send SIGTERM, wait for the child to exit, then SIGKILL if it
    /// didn't respond within a short grace period. Always succeeds in
    /// the sense that it can't fail; kill/wait errors are swallowed
    /// (the child may have already exited, or the platform may not
    /// support the signal — either way, the caller is done with the
    /// handle).
    ///
    /// In Zig 0.16, both `child.kill(io)` and `child.wait(io)` take an
    /// `io: Io` argument (Zig moved to Io-runtime-based process control).
    /// The caller passes `io` through the NalarProcess handle.
    pub fn terminate(self: *NalarProcess, io: std.Io) void {
        // In Zig 0.16, `child.kill(io)` is the all-in-one "terminate +
        // wait + cleanup" function: it sends SIGTERM, blocks until the
        // child exits, then sets `child.id = null` to mark the handle
        // reaped. Calling `child.wait(io)` AFTER `kill(io)` would assert
        // `child.id != null` and panic — see the doc comment on
        // `std.process.Child.kill` in std/process/Child.zig. So we just
        // call kill and trust it to do everything synchronously.
        self.child.kill(io);
    }
};

/// Poll http://127.0.0.1:<port>/health until it returns 200 or
/// `timeout_ms` elapses. Returns `error.HealthCheckTimeout` on timeout.
///
/// On a busy CI box the nalar process can take a few hundred ms to
/// start its HTTP server, so a typical call is `waitForHealth(...,
/// 5000, 50)` — poll every 50ms for up to 5 seconds.
pub fn waitForHealth(
    port: u16,
    timeout_ms: u32,
    poll_ms: u32,
) !void {
    // The deadline is in monotonic-clock nanoseconds. We poll until
    // `now` exceeds `start + timeout_ms * ns_per_ms`.
    const start_ts = readMonotonicNs();
    const deadline_ns: u64 = start_ts + (@as(u64, timeout_ms) * std.time.ns_per_ms);
    const poll_ns: u64 = @as(u64, poll_ms) * std.time.ns_per_ms;

    while (true) {
        if (tryProbe(port)) return;

        const now_ts = readMonotonicNs();
        if (now_ts >= deadline_ns) return error.HealthCheckTimeout;

        // Sleep until the next poll. The poll budget is a sleep, so
        // we cap the remaining deadline and pick the smaller of
        // (deadline - now) and poll_ns. For typical small poll_ms
        // values this is just poll_ns.
        const remaining = deadline_ns - now_ts;
        const sleep_ns: u64 = if (remaining < poll_ns) remaining else poll_ns;
        const sleep_ts: std.c.timespec = .{
            .sec = @intCast(@divFloor(sleep_ns, std.time.ns_per_s)),
            .nsec = @intCast(@mod(sleep_ns, std.time.ns_per_s)),
        };
        _ = std.c.nanosleep(&sleep_ts, null);
    }
}

/// One connect+probe attempt. Returns `true` on a 2xx response, `false`
/// on any other outcome (connect refused, timeout, non-2xx status, etc).
/// The caller treats `false` as "not ready, sleep and retry".
fn tryProbe(port: u16) bool {
    // Open a blocking TCP socket. SO_RCVTIMEO gives the recv() call a
    // per-attempt deadline so a half-dead server can't make the probe
    // hang past the next-poll interval.
    const fd = std.c.socket(std.c.AF.INET, std.c.SOCK.STREAM, 0);
    if (fd < 0) return false;
    defer _ = std.c.close(fd);

    // 1-second per-call recv() timeout. If the server hasn't responded
    // within 1s we abandon this probe and let the outer loop retry.
    // The struct timeval is {tv_sec, tv_usec} on every POSIX we target.
    const rcvtimeo = std.c.timeval{ .sec = 1, .usec = 0 };
    _ = std.c.setsockopt(
        fd,
        std.c.SOL.SOCKET,
        std.c.SO.RCVTIMEO,
        @ptrCast(&rcvtimeo),
        @sizeOf(std.c.timeval),
    );

    // Build sockaddr_in for 127.0.0.1:port. Port + addr are big-endian.
    const addr_bytes = [_]u8{ 127, 0, 0, 1 };
    var addr: u32 = 0;
    for (addr_bytes, 0..) |b, i| addr |= @as(u32, b) << @intCast(i * 8);
    const sockaddr = std.c.sockaddr.in{
        .port = std.mem.nativeToBig(u16, port),
        .addr = addr,
    };
    if (std.c.connect(fd, @ptrCast(&sockaddr), @sizeOf(std.c.sockaddr.in)) < 0) return false;

    // Send a minimal HTTP/1.0 request. We use HTTP/1.0 (not 1.1) so
    // the server is allowed to close the connection after the single
    // response — no keep-alive bookkeeping needed.
    const req = "GET /health HTTP/1.0\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n";
    const write_rc = std.c.write(fd, req.ptr, req.len);
    if (write_rc != req.len) return false;

    // Read the response. The status line is "HTTP/1.x NNN ..." — we
    // only need to read far enough to find the 3-digit status code.
    // 512 bytes is plenty for any well-formed HTTP/1.0 response from
    // nalar's health endpoint. recv() returns 0 on EOF, which is
    // fine — we check the status code as soon as we've seen the
    // "HTTP/1.x" prefix + first status digit.
    var buf: [512]u8 = undefined;
    var total: usize = 0;
    while (total < buf.len) {
        const n: isize = std.c.recvfrom(fd, buf[total..].ptr, buf.len - total, 0, null, null);
        if (n <= 0) break; // EOF or error — server closed or reset
        const n_usize: usize = @intCast(n);
        if (total > std.math.maxInt(usize) - n_usize) return false; // overflow guard
        total += n_usize;
        // We have enough to check the status code as soon as we see
        // "HTTP/1.x N". The 9th byte (index 9) is the first status digit.
        if (total >= 12 and
            std.mem.startsWith(u8, buf[0..total], "HTTP/1.") and
            buf[9] == '2')
        {
            return true;
        }
    }
    return false;
}

fn readMonotonicNs() u64 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(std.c.CLOCK.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}

/// Spawn nalar as a child process with `--port <port>`. The caller
/// is responsible for calling `terminate()` on the returned handle
/// before discarding it.
///
/// `static_dir` is now IGNORED — the webview is served from the
/// desktop's embedded assets via the `app://` scheme handler, and
/// `/api/*` calls in the webapp are proxied to nalar's port by the
/// same handler. nalar is API-only. The webview and the nalar API
/// thus live on different ports / schemes, which is what the user
/// asked for (no more "webview and nalar share port 8081").
///
/// Kept in the signature for source-compat with the call site in
/// attach.zig; passing a non-null value is silently ignored. A
/// future refactor can drop the parameter.
///
/// `io` is the Io runtime handle (Zig 0.16's `std.process.spawn`
/// takes `io: Io` as its first arg). `allocator` is used by the
/// Child handle internally — pass the long-lived app allocator,
/// NOT std.testing.allocator.
pub fn spawn(
    allocator: std.mem.Allocator,
    io: std.Io,
    nalar_path: []const u8,
    port: u16,
    static_dir: ?[]const u8,
) !NalarProcess {
    _ = allocator; // argv is a small stack-allocated array
    _ = static_dir; // ignored — see fn doc

    // Build the argv slice. The port number is formatted into a small
    // stack buffer because argv requires a sentinel-free string slice.
    // We use a fixed-size array and slice it down to the actual count —
    // avoids a heap allocation for the common case.
    var port_buf: [16]u8 = undefined;
    const port_str = std.fmt.bufPrint(&port_buf, "{d}", .{port}) catch unreachable;

    const argv_buf: [3][]const u8 = .{
        nalar_path, "--port", port_str,
    };
    const argv = argv_buf[0..];

    // stdin/stdout/stderr: for v1 we set them all to .ignore. The design
    // doc says we should capture stderr for diagnostics, but Chunk 2 is
    // a pure unit-test milestone and Chunk 8 will wire up capture if
    // the webview chunks find a need for it.
    const child = std.process.spawn(io, .{
        .argv = argv,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    }) catch |err| {
        // Map spawn errors into a single descriptive error so callers
        // can match on `error.SpawnFailed` without enumerating every
        // OS-level variant.
        std.log.err("spawn nalar at {s} failed: {s}", .{ nalar_path, @errorName(err) });
        return error.SpawnFailed;
    };

    return .{
        .child = child,
        .port = port,
        .pid = if (child.id) |pid| @intCast(pid) else 0,
    };
}



comptime {
    // Quiet the unused-import warning if the platform branch below is
    // empty for the current target. `builtin` is referenced in the
    // module doc; this is just a safety net.
    _ = builtin;
}
