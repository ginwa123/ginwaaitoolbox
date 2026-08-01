//! Regression tests for HTTP/1.1 chunked-transfer-encoding in
//! `sse_manager.zig` (Tasks 1 & 2 of
//! `docs/superpowers/plans/2026-06-19-fix-sse-incomplete-chunked-encoding.md`).
//!
//! NOTE: this file lives next to `sse_manager_test.zig` but is a
//! separate file because `sse_manager_test.zig` is currently dead in
//! this branch — it uses `std.Io.init()` which doesn't compile on
//! Zig 0.16, and the project's root test runner only imports
//! `test_session_lifecycle.zig` from this module, not
//! `sse_manager_test.zig`. This file is registered in
//! `src/root.zig` (line 401) so it runs as part of the project-wide
//! `zig build test` step.

const std = @import("std");
const posix = std.posix;
const sse_manager = @import("sse_manager.zig");
const SseManager = sse_manager.SseManager;
const builtin = @import("builtin");
const is_windows = builtin.os.tag == .windows;

fn closeFd(fd: i32) void {
    if (is_windows) return; // Sockets are HANDLE on Windows; fd is meaningless
    _ = posix.system.close(fd);
}

fn readFd(fd: i32, buf: []u8, len: usize) isize {
    if (is_windows) return 0; // Not used on Windows (tests skip)
    // posix.system.read takes ([*]u8, usize); pass the slice's pointer
    // (single-pointer-many-items, not the slice header) and the count.
    return posix.system.read(fd, buf.ptr, len);
}

fn createSocketPair() ![2]i32 {
    if (builtin.os.tag == .windows) {
        // On Windows, sockets are HANDLE (*anyopaque), not i32 file descriptors.
        // The entire test suite relies on POSIX socketpair semantics which are
        // not available on Windows. Skip these tests on Windows.
        return error.SkipZigTest;
    } else {
        var fds: [2]i32 = undefined;
        // AF_UNIX (1), SOCK_STREAM (1), protocol 0. socketpair returns
        // 0 on success, -1 on failure.
        const rc = posix.system.socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0, &fds);
        if (rc != 0) return error.SocketPairFailed;
        return fds;
    }
}

// ============================================================================
// Task 1: writeChunkedFrame / sendChunked / sendTerminatingChunk
// ============================================================================

test "writeChunkedFrame: writes <hex len>\\r\\n<data>\\r\\n" {
    const pair = try createSocketPair();
    defer _ = closeFd(pair[0]);
    defer _ = closeFd(pair[1]);

    try sse_manager.writeChunkedFrame(pair[0], "event: ping\ndata: 1\n\n");

    // Read on the OTHER end of the socketpair and assert the chunked frame.
    // Data is 21 bytes → hex len "15" → "15\r\n" (4) + data (21) + "\r\n" (2) = 27.
    var buf: [64]u8 = undefined;
    const n = readFd(pair[1], &buf, buf.len);
    try std.testing.expect(n == 27);
    try std.testing.expectEqualSlices(u8, "15\r\nevent: ping\ndata: 1\n\n\r\n", buf[0..@intCast(n)]);
}

test "writeChunkedFrame: empty data writes 0\\r\\n\\r\\n (chunked terminator)" {
    const pair = try createSocketPair();
    defer _ = closeFd(pair[0]);
    defer _ = closeFd(pair[1]);

    try sse_manager.writeChunkedFrame(pair[0], "");

    var buf: [16]u8 = undefined;
    const n = readFd(pair[1], &buf, buf.len);
    try std.testing.expect(n == 5);
    try std.testing.expectEqualSlices(u8, "0\r\n\r\n", buf[0..@intCast(n)]);
}

test "SseClient: sendEvent writes <hex len>\\r\\n<data>\\r\\n" {
    const pair = try createSocketPair();
    defer _ = closeFd(pair[0]);
    defer _ = closeFd(pair[1]);

    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();

    const id: [16]u8 = .{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16 };
    var client: sse_manager.SseClient = .init(id, pair[0], std.testing.allocator, threaded.io());
    // Suppress the per-client arena cleanup on scope-exit (it would
    // double-free the fd that `closeFd(pair[0])` above
    // also closes). The test only needs `client.sendEvent` to write
    // the chunked frame; we explicitly call `forceDestroy` to close
    // the fd without deinitialising the arena.
    defer client.forceDestroy();
    try client.sendEvent("event: ping\ndata: 1\n\n");

    var buf: [64]u8 = undefined;
    const n = readFd(pair[1], &buf, buf.len);
    try std.testing.expect(n == 27);
    try std.testing.expectEqualSlices(u8, "15\r\nevent: ping\ndata: 1\n\n\r\n", buf[0..@intCast(n)]);
}

test "SseManager: sendChunked on missing client returns ClientNotFound" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    var mgr = try SseManager.init(std.testing.allocator, std.testing.allocator, threaded.io());
    defer mgr.deinit();

    var bogus: [16]u8 = undefined;
    @memset(&bogus, 0xAB);
    const err = mgr.sendChunked(bogus, "data: x\n\n") catch |e| e;
    try std.testing.expectEqual(error.ClientNotFound, err);
}

// ============================================================================
// Task 2: removeClient sends the chunked-encoding terminator before closing
// ============================================================================

test "SseManager: removeClient sends the terminating chunk (0\\r\\n\\r\\n) before close" {
    // Regression test for the
    // `net::ERR_INCOMPLETE_CHUNKED_ENCODING 200 (OK)` browser error: every
    // SSE connection must end with `0\r\n\r\n` so the peer's chunked-
    // decoder can finalize cleanly. `removeClient` is responsible for
    // flushing the terminator before closing the fd.
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();

    // Wrap the server_allocator in an ArenaAllocator so the hash map's
    // backing memory is freed when the arena is deinit'd (SseManager.deinit
    // calls clearRetainingCapacity which keeps the storage around, and
    // DebugAllocator flags the residual as a leak otherwise).
    var server_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer server_arena.deinit();
    const server_allocator = server_arena.allocator();

    var mgr = try SseManager.init(std.testing.allocator, server_allocator, threaded.io());
    defer mgr.deinit();

    const pair = try createSocketPair();
    // We do NOT close pair[0] here — removeClient's sendTerminatingChunk
    // will write to it, and then deinit() will close it. We only own
    // the read end.
    defer _ = closeFd(pair[1]);

    // Use registerClientForTest so the random-id path (which requires
    // being on the Io thread) is bypassed.
    const id = try mgr.registerClientForTest(pair[0], .{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16 });

    // Send one event so the peer has a chunked frame on the wire.
    try mgr.sendChunked(id, "event: ping\ndata: 1\n\n");

    // removeClient must (a) flush the terminator, then (b) close the fd.
    mgr.removeClient(id, .test_only);

    // Read everything available on the peer end. Expected sequence:
    //   "15\r\nevent: ping\ndata: 1\n\n\r\n0\r\n\r\n"
    //  =  4 + 21 + 2 + 5 = 32 bytes.
    //  (the hex length "15" is 2 chars, then \r\n, then the 21-byte
    //  data, then \r\n trailer, then the 5-byte terminator "0\r\n\r\n")
    var buf: [64]u8 = undefined;
    // posix.system.read takes ([*]u8, usize), so we pass `&buf` (which
    // coerces from *[64]u8 to [*]u8) and `buf.len`. We do best-effort:
    // the close from removeClient causes the remaining bytes to be
    // available; we may need one or two reads to drain the kernel
    // buffer.
    var total: usize = 0;
    while (total < 32) {
        const n = readFd(pair[1], &buf, buf.len - total);
        if (n <= 0) break;
        total += @intCast(n);
    }

    try std.testing.expect(total == 32);
    try std.testing.expectEqualSlices(
        u8,
        "15\r\nevent: ping\ndata: 1\n\n\r\n0\r\n\r\n",
        buf[0..total],
    );
}

// ============================================================================
// Task 3: HTTP response headers declare Transfer-Encoding: chunked
// ============================================================================
//
// Regression guard for
// `net::ERR_INCOMPLETE_CHUNKED_ENCODING 200 (OK)` in the browser.
//
// Per RFC 9112 §6, an HTTP/1.1 response with neither `Content-Length` nor
// `Transfer-Encoding` is implicitly framed by connection-close. For an
// SSE stream we never close the connection voluntarily, so we MUST declare
// chunked encoding in the response headers. Without this declaration,
// intermediaries (Vite, nginx, Cloudflare, ALB) misinterpret the response
// and surface `ERR_INCOMPLETE_CHUNKED_ENCODING` on disconnect.
//
// We test this via static source-check (the pattern used by 12+ other
// tests in this codebase, e.g.
// `src/ai_workflow/tui/http_handlers/git_pr_create_test.zig`). A
// behavioural GinwaServer-level test would require spinning up a real
// Io runtime + concurrent group + accepting socket, which is brittle for
// a unit test and out of scope for this task. The source-check is the
// canonical regression guard for "header X is present on response Y".

const HTTP_SERVER_PATH = "src/modules/custom_http_server/src/http_server.zig";

fn readHttpServerSource(allocator: std.mem.Allocator) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        HTTP_SERVER_PATH,
        allocator,
        .limited(64 * 1024),
    );
}

test "HTTP server: SSE response declares Transfer-Encoding: chunked" {
    // Regression for `net::ERR_INCOMPLETE_CHUNKED_ENCODING`. The SSE
    // response headers in the `.sse =>` arm of `GinwaServer.handle` must
    // include `Transfer-Encoding: chunked` so HTTP/1.1 intermediaries
    // forward the body using chunked-decoding semantics.
    const source = try readHttpServerSource(std.testing.allocator);
    defer std.testing.allocator.free(source);

    if (std.mem.indexOf(u8, source, "Transfer-Encoding: chunked") == null) {
        std.debug.print("\n!! http_server.zig missing Transfer-Encoding: chunked !!\n", .{});
        return error.TransferEncodingChunkedMissing;
    }
}

test "HTTP server: SSE response sets X-Accel-Buffering: no" {
    // Regression for `net::ERR_INCOMPLETE_CHUNKED_ENCODING` under Vite /
    // nginx / Cloudflare / ALB. `X-Accel-Buffering: no` is the de-facto
    // standard signal to disable response buffering so SSE chunks reach
    // the client as soon as the server writes them.
    const source = try readHttpServerSource(std.testing.allocator);
    defer std.testing.allocator.free(source);

    if (std.mem.indexOf(u8, source, "X-Accel-Buffering: no") == null) {
        std.debug.print("\n!! http_server.zig missing X-Accel-Buffering: no !!\n", .{});
        return error.XAccelBufferingMissing;
    }
}

test "HTTP server: SSE response says Connection: close (NOT keep-alive)" {
    // Regression for the "SSE drops every 30s" bug under Vite / WebKitGTK /
    // WKWebView. Sending `Connection: keep-alive` on an SSE response is a
    // lie — the connection is never reused for a follow-up request — and
    // Node.js's HTTP server stamps `Keep-Alive: timeout=5` on keep-alive
    // responses, which some browsers enforce aggressively (closing the
    // upstream socket ~5s after the last heartbeat). Empirically this
    // matches the user's reported pattern of heartbeats stopping after
    // ~30s in the browser DevTools. The correct header is `Connection:
    // close` — telling intermediaries this stream ends when the socket
    // closes — combined with `Transfer-Encoding: chunked` (so HTTP/1.1
    // knows the body is chunk-bounded rather than connection-bounded).
    //
    // NOTE: We search for the literal header NAME without the trailing
    // `\r\n` because in the Zig source the `\r\n` is an escape sequence
    // (4 source bytes: `\`, `r`, `\`, `n`) rather than 2 real CR+LF
    // bytes. That's enough to disambiguate from comments / docstrings.
    const source = try readHttpServerSource(std.testing.allocator);
    defer std.testing.allocator.free(source);

    // The SSE arm must declare `Connection: close`.
    if (std.mem.indexOf(u8, source, "\"Connection: close\\r\\n\"") == null) {
        std.debug.print("\n!! http_server.zig SSE arm missing '\"Connection: close\\\\r\\\\n\"' string literal !!\n", .{});
        return error.SseConnectionCloseMissing;
    }
    // The SSE arm must NOT declare `Connection: keep-alive`.
    if (std.mem.indexOf(u8, source, "\"Connection: keep-alive\\r\\n\"") != null) {
        std.debug.print("\n!! http_server.zig SSE arm still sends 'Connection: keep-alive' (causes ~30s drop under Vite) !!\n", .{});
        return error.SseConnectionKeepAliveStillPresent;
    }
}

// ============================================================================
// Task 4 (long-period fix #1): sendHeartbeat must take the SseManager lock
// when snapshotting client pointers.
//
// Bug history: the lock was COMMENTED OUT in sendHeartbeat, while
// broadcast/broadcastTyped correctly take it. Under concurrent
// registerClient/removeClient activity, the unlocked iterator could
// be invalidated mid-iteration and the captured `entry.value_ptr.*`
// could read freed memory (use-after-free). On a long-idle page with
// many connections, the corruption surfaces as a half-flushed chunked
// terminator, which the browser reports as
// `net::ERR_INCOMPLETE_CHUNKED_ENCODING 200 (OK)` once the connection
// finally drops.
//
// This is a static source-check (matching the project's established
// pattern for "guard against revert" tests, see the 12+ tests in
// `src/ai_workflow/tui/http_handlers/`). We assert the function body
// contains BOTH the lock acquisition AND the matching unlock — guards
// against someone re-commenting the lock again.
// ============================================================================

const SSE_MANAGER_PATH = "src/modules/custom_http_server/src/sse_manager.zig";

fn readSseManagerSource(allocator: std.mem.Allocator) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        SSE_MANAGER_PATH,
        allocator,
        .limited(64 * 1024),
    );
}

test "SseManager: sendHeartbeat takes the manager lock during the client snapshot" {
    const source = try readSseManagerSource(std.testing.allocator);
    defer std.testing.allocator.free(source);

    // Find the `fn sendHeartbeat` declaration and look at the next ~8 KiB
    // of body. Anything outside that window is irrelevant — we only care
    // that the lock is held while iterating `self.clients`, not the
    // IO loop after the snapshot. The 8 KiB window comfortably covers any
    // function body in this codebase (the longest observed is ~2.4 KiB).
    const decl = std.mem.indexOf(u8, source, "fn sendHeartbeat(") orelse {
        std.debug.print("\n!! sse_manager.zig missing `fn sendHeartbeat` !!\n", .{});
        return error.SendHeartbeatMissing;
    };
    const window_end = @min(decl + 8192, source.len);
    const body = source[decl..window_end];

    if (std.mem.indexOf(u8, body, "self.lock.lock(self.io)") == null) {
        std.debug.print(
            "\n!! sse_manager.zig: sendHeartbeat does not take `self.lock.lock(self.io)` !!\n" ++
                "   The lock MUST be held while iterating `self.clients`; an unlocked iteration\n" ++
                "   is a use-after-free race with concurrent registerClient/removeClient.\n",
            .{},
        );
        return error.SendHeartbeatLockMissing;
    }
    if (std.mem.indexOf(u8, body, "self.lock.unlock(self.io)") == null) {
        std.debug.print(
            "\n!! sse_manager.zig: sendHeartbeat does not release `self.lock` !!\n" ++
                "   The lock acquired during the client snapshot must be released before the\n" ++
                "   IO loop, otherwise the manager deadlocks on the next registerClient.\n",
            .{},
        );
        return error.SendHeartbeatUnlockMissing;
    }
    // Also guard against the lock being COMMENTED OUT — the regression
    // that motivated this fix was exactly `// self.lock.lock(...)` with
    // a leading `//`. A grep for the bare call is not enough; we check
    // the prefix lines too.
    if (std.mem.indexOf(u8, body, "// self.lock.lock(self.io)") != null or
        std.mem.indexOf(u8, body, "// self.lock.unlock(self.io)") != null)
    {
        std.debug.print(
            "\n!! sse_manager.zig: sendHeartbeat lock is commented out !!\n" ++
                "   Uncomment the `self.lock.lock(self.io)` / `self.lock.unlock(self.io)` lines.\n",
            .{},
        );
        return error.SendHeartbeatLockCommentedOut;
    }
}

// ============================================================================
// Task 5 (long-period fix #2): acceptClient must set SO_KEEPALIVE on every
// accepted SSE socket.
//
// Bug history: the previous acceptClient returned the fd without
// enabling TCP keepalive. On Linux, the default `tcp_keepalive_time`
// is 7200s (2 hours), so a silently-dropped connection (Wi-Fi loss,
// NAT table expiry, half-open TCP after a peer crash) was not detected
// at the kernel level. The server kept heartbeating into a dead socket
// for up to 2 hours; when the connection finally closed, the
// application-level heartbeat races (see Task 4 test above) could
// produce a half-flushed chunked terminator, which the browser reports
// as `net::ERR_INCOMPLETE_CHUNKED_ENCODING 200 (OK)`.
//
// Settings mirror `Agent.apply_tcp_keepalive`
// (`src/modules/agent/Agent.zig:793`) so outbound LLM conns and
// inbound browser conns fail at the same rate:
//   keepidle  = 10s, keepintvl = 5s, keepcnt = 3
//   → dead-conn detection in ~25s.
// ============================================================================

test "HTTP server: acceptClient sets SO_KEEPALIVE on accepted sockets" {
    const source = try readHttpServerSource(std.testing.allocator);
    defer std.testing.allocator.free(source);

    // Find the `fn acceptClient` declaration and check the next ~8 KiB
    // of body — anything outside that window is irrelevant. The 8 KiB
    // window comfortably covers any function body in this codebase (the
    // longest observed is ~2.4 KiB for `acceptClient` itself, with
    // verbose keepalive comment). We assert that the function body
    // contains both the SO_KEEPALIVE setup AND the TCP keepalive timer
    // configuration (KEEPIDLE / KEEPINTVL / KEEPCNT), so a future
    // refactor that drops any of these is caught.
    const decl = std.mem.indexOf(u8, source, "fn acceptClient(") orelse {
        std.debug.print("\n!! http_server.zig missing `fn acceptClient` !!\n", .{});
        return error.AcceptClientMissing;
    };
    const window_end = @min(decl + 8192, source.len);
    const body = source[decl..window_end];

    if (std.mem.indexOf(u8, body, "posix.SO.KEEPALIVE") == null and
        std.mem.indexOf(u8, body, "SO.KEEPALIVE") == null)
    {
        std.debug.print(
            "\n!! http_server.zig: acceptClient does not set SO_KEEPALIVE !!\n" ++
                "   Without TCP keepalive, silent network drops (Wi-Fi loss, NAT timeout)\n" ++
                "   are not detected at the kernel level for up to 2 hours (Linux default).\n" ++
                "   Add `posix.setsockopt(fd, posix.SOL.SOCKET, posix.SO.KEEPALIVE, ...)`\n" ++
                "   right after `socket.accept(...)` returns.\n",
            .{},
        );
        return error.SoKeepaliveMissing;
    }
    if (std.mem.indexOf(u8, body, "posix.TCP.KEEPIDLE") == null and
        std.mem.indexOf(u8, body, "TCP.KEEPIDLE") == null)
    {
        std.debug.print(
            "\n!! http_server.zig: acceptClient missing TCP_KEEPIDLE !!\n" ++
                "   SO_KEEPALIVE alone uses the system default (7200s on Linux). For an SSE\n" ++
                "   server that must detect dead clients within ~25s, override TCP_KEEPIDLE.\n",
            .{},
        );
        return error.TcpKeepidleMissing;
    }
    if (std.mem.indexOf(u8, body, "posix.TCP.KEEPINTVL") == null and
        std.mem.indexOf(u8, body, "TCP.KEEPINTVL") == null)
    {
        std.debug.print(
            "\n!! http_server.zig: acceptClient missing TCP_KEEPINTVL !!\n" ++
                "   Without an explicit probe interval, the OS uses the system default.\n",
            .{},
        );
        return error.TcpKeepintvlMissing;
    }
    if (std.mem.indexOf(u8, body, "posix.TCP.KEEPCNT") == null and
        std.mem.indexOf(u8, body, "TCP.KEEPCNT") == null)
    {
        std.debug.print(
            "\n!! http_server.zig: acceptClient missing TCP_KEEPCNT !!\n" ++
                "   Without an explicit probe count, the OS uses the system default.\n",
            .{},
        );
        return error.TcpKeepcntMissing;
    }
}

// ============================================================================
// Task 3: SSE Manager FD-leak regression tests
// (`docs/superpowers/plans/2026-06-30-fix-sse-fd-leak.md`)
// ============================================================================

test "SseManager: poll reaper subscribes to POLL.NVAL (static contract)" {
    // The FD leak that produced `ProcessFdQuotaExceeded` after long
    // nalar uptimes was caused by the poll reaper NOT subscribing to
    // POLL.NVAL. The kernel returns POLL.NVAL when a process holds an
    // FD whose underlying socket has been fully reaped — the classic
    // "orphan sock FD" signature seen in the leaked-FD audit (`lsof`
    // showed 1011 such FDs). Without subscription, the reaper's
    // `revents == 0` early-exit silently skips the FD, leaking it for
    // the process lifetime.
    //
    // This is a static-contract test (matches the convention in the
    // other test files in this directory: the project has no
    // behavioural test harness for standing up `startEventLoop` from
    // a unit test, and the same Threaded-Io + spawned-thread pattern
    // hangs on this Zig 0.16 Io runtime). Behavioural verification is
    // deferred to the manual smoke test in the plan.
    const source = @embedFile("../../../../src/modules/custom_http_server/src/sse_manager.zig");

    // Subscription: the `for (my_fds.items)` block must request
    // POLL.NVAL in addition to POLL.IN and POLL.HUP.
    const events_pos = std.mem.indexOf(u8, source, ".events = posix.POLL.IN | posix.POLL.HUP") orelse
        std.mem.indexOf(u8, source, ".events = posix.POLL.IN | posix.POLL.HUP | posix.POLL.NVAL") orelse 0;
    if (events_pos == 0 or
        std.mem.indexOf(u8, source, "posix.POLL.IN | posix.POLL.HUP | posix.POLL.NVAL") == null)
    {
        std.debug.print(
            "\n!! sse_manager.zig poll subscription missing POS | POLL.NVAL !!\n" ++
                "   Without POLL.NVAL the reaper cannot see orphan-sock FDs and they leak.\n",
            .{},
        );
        return error.PollNvalMissing;
    }

    // Reaping branch: the `(poll_err | poll_hup)` test must also
    // check `poll_nval`.
    if (std.mem.indexOf(u8, source, "poll_err | poll_hup | poll_nval") == null) {
        std.debug.print(
            "\n!! sse_manager.zig poll reaping branch missing poll_nval !!\n" ++
                "   Even with subscription, orphan FDs are not reaped unless checked.\n",
            .{},
        );
        return error.PollNvalCheckMissing;
    }
}

test "SseManager: heartbeat sharding uses id[0] mod LOOP_COUNT (static contract)" {
    // The sendHeartbeat shard rule must match the runEventLoop shard
    // rule (`id[0] % LOOP_COUNT == loop_id`). Heartbeat and poll
    // disagreed on ownership (heartbeat used a `global_idx` counter),
    // so a client could be polled by one loop and heartbeated by
    // another. While every client was still covered (the modulo spans
    // all residue classes), the sharding rule divergence made the
    // ownership model fragile to future refactors and made the
    // periodic sweep helper's invariants opaque.
    const source = @embedFile("../../../../src/modules/custom_http_server/src/sse_manager.zig");

    if (std.mem.indexOf(u8, source, "if (entry.value_ptr.*.id[0] % LOOP_COUNT == loop_id)") == null) {
        std.debug.print(
            "\n!! sse_manager.zig: sendHeartbeat sharding must match runEventLoop !!\n" ++
                "   Expected: `entry.value_ptr.*.id[0] % LOOP_COUNT == loop_id`\n",
            .{},
        );
        return error.HeartbeatShardingMismatch;
    }

    // Reverse-direction guard: the buggy `global_idx` rule must be gone.
    if (std.mem.indexOf(u8, source, "if (global_idx % LOOP_COUNT == loop_id)") != null) {
        std.debug.print(
            "\n!! sse_manager.zig: sendHeartbeat still uses global_idx shard !!\n" ++
                "   The global_idx counter depends on hashmap iteration order.\n",
            .{},
        );
        return error.HeartbeatShardingStillGlobalIdx;
    }
}

test "SseManager: last_heartbeat updated only on successful write (static contract)" {
    // The `last_heartbeat` field is consulted by `sweepStaleClients`
    // to detect stale clients. If it's updated BEFORE the write,
    // failed heartbeats record a fresh timestamp, hiding staleness
    // from the sweep — defeating its purpose as a safety net.
    //
    // Verify by source check: the heartbeat write loop body must put
    // `last_heartbeat = timestamp()` INSIDE the success branch of the
    // `writeChunkedFrame` `|`/`else| |` dispatch.
    const source = @embedFile("../../../../src/modules/custom_http_server/src/sse_manager.zig");

    // The success branch of the heartbeat write must contain the
    // `last_heartbeat = timestamp(self.io)` assignment. The windows-
    // compatibility branch updated `timestamp()` to take the `io: std.Io`
    // parameter (cross-platform wrapper around libc `gettimeofday` /
    // Win32 `GetSystemTimeAsFileTime`), so the assignment now passes
    // `self.io` as the source of "real" wall-clock time.
    const success_assign = std.mem.indexOf(
        u8,
        source,
        "writeChunkedFrame(client.fd, ping)) |_| {\n                client.last_heartbeat = timestamp(self.io);",
    ) orelse 0;
    if (success_assign == 0) {
        std.debug.print(
            "\n!! sse_manager.zig: last_heartbeat must update INSIDE the success branch !!\n" ++
                "   Sweep helper relies on stale timestamps catching failed heartbeats.\n",
            .{},
        );
        return error.LastHeartbeatOutsideSuccessBranch;
    }
}

test "SseManager: sweepStaleClients removes clients whose last_heartbeat is stale" {
    // Regression test for the periodic-stale sweep in
    // `docs/superpowers/plans/2026-06-30-fix-sse-fd-leak.md` Change 3.
    // A client whose `last_heartbeat` is older than `max_stale_ms` must
    // be reaped, closing its FD and freeing the SseClient.
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var server_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer server_arena.deinit();
    const server_allocator = server_arena.allocator();

    var mgr = try SseManager.init(std.testing.allocator, server_allocator, io);
    defer mgr.deinit();

    // Register a client backed by a real socket pair so the FD is valid
    // (we only want to test the staleness sweep, not POLL.NVAL).
    const pair = try createSocketPair();
    // The sweep closes pair[0] for us; we close the other end.
    defer _ = closeFd(pair[1]);
    const id: [16]u8 = .{ 0x42 } ** 16;
    _ = try mgr.registerClientForTest(pair[0], id);
    try std.testing.expect(mgr.clientCount() == 1);

    // The client's `last_heartbeat` was set to `timestamp()` at register
    // time. Wait long enough that 200ms have elapsed (so a 100ms
    // staleness threshold catches it).
    try std.Io.sleep(io, .{ .nanoseconds = 200 * std.time.ns_per_ms }, .real);

    // Sweep with max_stale_ms=100 (anything older than 100ms is stale).
    mgr.sweepStaleClients(100, 64);
    try std.testing.expect(mgr.clientCount() == 0);
}

test "SseManager: sweepStaleClients respects max_per_call cap" {
    // The sweep helper is bounded per-call to avoid O(N²) behaviour when
    // a large batch goes stale at once (e.g., on a server-side rollback).
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var server_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer server_arena.deinit();
    const server_allocator = server_arena.allocator();

    var mgr = try SseManager.init(std.testing.allocator, server_allocator, io);
    defer mgr.deinit();

    const pair1 = try createSocketPair();
    const pair2 = try createSocketPair();
    const pair3 = try createSocketPair();
    const pair4 = try createSocketPair();
    defer _ = closeFd(pair1[1]);
    defer _ = closeFd(pair2[1]);
    defer _ = closeFd(pair3[1]);
    defer _ = closeFd(pair4[1]);

    _ = try mgr.registerClientForTest(pair1[0], .{ 0x11 } ** 16);
    _ = try mgr.registerClientForTest(pair2[0], .{ 0x22 } ** 16);
    _ = try mgr.registerClientForTest(pair3[0], .{ 0x33 } ** 16);
    _ = try mgr.registerClientForTest(pair4[0], .{ 0x44 } ** 16);
    try std.testing.expect(mgr.clientCount() == 4);

    // Make all 4 stale.
    try std.Io.sleep(io, .{ .nanoseconds = 200 * std.time.ns_per_ms }, .real);

    // Sweep with max_per_call=2 — at most 2 per call.
    mgr.sweepStaleClients(100, 2);
    try std.testing.expect(mgr.clientCount() == 2);

    // Second sweep picks up the remaining 2.
    mgr.sweepStaleClients(100, 2);
    try std.testing.expect(mgr.clientCount() == 0);
}

// ============================================================================
// Task 4 (2026-07-01): additional FD-leak / memory-leak regression tests
// (`docs/superpowers/plans/2026-07-01-fix-remaining-fd-leak-risks.md`).
//
// Three fixes audited on 2026-07-01 that were NOT addressed by the prior
// `5df11a9a` (POLL.NVAL) fix:
//   1. `sendToClient` reads `self.clients` and `client.fd` without holding
//      the lock — UAF + potential FD leak if a concurrent `removeClient`
//      frees the client while the writeChunkedFrame is in flight.
//   2. `deinit` and `gracefulShutdown` call `client.forceDestroy()` which
//      closes the fd but leaks the per-client arena + message_queue —
//      memory leak in long-lived servers that have served many distinct
//      connections.
//   3. `handleClientDisconnect` (in root.zig) only unregisters the FIRST
//      routing_key containing the client_id, leaving N-1 orphans in
//      `session_to_client_ids` for clients connected via the unified
//      SSE endpoint (which registers under N channels).
// ============================================================================

test "SseManager: sendToClient takes the manager lock before reading self.clients (static contract)" {
    // The audit identified that `sendToClient` previously read from
    // `self.clients.get(id)` and dereferenced `client.fd` without
    // holding the per-manager lock. Concurrent `registerClient` /
    // `removeClient` could rehash the underlying bucket array or free
    // the client pointer mid-write, leaving the failed-write path's
    // `removeClient` call operating on a foreign (recycled) client_id
    // and silently leaking the real victim's FD. The fix holds the
    // lock for the duration of the `get` + writeChunkedFrame +
    // inlined-remove sequence.
    const source = @embedFile("../../../../src/modules/custom_http_server/src/sse_manager.zig");

    // Find `fn sendToClient` and look at the next ~8 KiB of body
    // (matches the window size used by the existing sendHeartbeat
    // static-contract test in this file; the function is ~50 lines
    // with verbose comments).
    const decl_pos = std.mem.indexOf(u8, source, "pub fn sendToClient(") orelse 0;
    if (decl_pos == 0) {
        std.debug.print("\n!! sse_manager.zig missing `pub fn sendToClient` !!\n", .{});
        return error.SendToClientDeclMissing;
    }
    const window_end = @min(decl_pos + 8192, source.len);
    const window = source[decl_pos..window_end];

    // Reverse-direction guard: the lock must NOT be commented out —
    // the regression that motivated this fix was an unlocked read
    // that the test would otherwise miss if someone commented the
    // lock back out.
    if (std.mem.indexOf(u8, window, "// self.lock.lock(self.io)") != null) {
        std.debug.print(
            "\n!! sse_manager.zig: sendToClient lock is commented out !!\n" ++
                "   Uncomment `self.lock.lock(self.io)` and `self.lock.unlock(self.io)`.\n",
            .{},
        );
        return error.SendToClientLockCommentedOut;
    }

    const lock_pos = std.mem.indexOf(u8, window, "self.lock.lock(self.io)") orelse 0;
    if (lock_pos == 0) {
        std.debug.print(
            "\n!! sse_manager.zig: sendToClient must lock before reading self.clients !!\n" ++
                "   Concurrent register/remove can race with the unlocked read and leak FDs.\n",
            .{},
        );
        return error.SendToClientLockMissing;
    }
    if (std.mem.indexOf(u8, window, "self.lock.unlock(self.io)") == null) {
        std.debug.print(
            "\n!! sse_manager.zig: sendToClient must release `self.lock` !!\n" ++
                "   Missing `defer self.lock.unlock(self.io)` would deadlock registerClient.\n",
            .{},
        );
        return error.SendToClientUnlockMissing;
    }

    // The lock MUST be acquired BEFORE the read of `self.clients` (or
    // an inlined `fetchRemove` is fine — that's still under the lock).
    const get_pos = std.mem.indexOf(u8, window, "self.clients.get(id)") orelse 0;
    const fetch_pos = std.mem.indexOf(u8, window, "self.clients.fetchRemove(id)") orelse 0;
    if (get_pos == 0 and fetch_pos == 0) {
        std.debug.print(
            "\n!! sse_manager.zig: sendToClient must read self.clients under the lock !!\n" ++
                "   Expected either `self.clients.get(id)` or `self.clients.fetchRemove(id)` in the body.\n",
            .{},
        );
        return error.SendToClientUnlockedClientsRead;
    }
    const read_pos = if (get_pos != 0) get_pos else fetch_pos;
    if (read_pos < lock_pos) {
        std.debug.print(
            "\n!! sse_manager.zig: self.clients read precedes the lock acquire !!\n" ++
                "   The read happens at offset {d} but the lock acquire is at offset {d}.\n",
            .{ read_pos, lock_pos },
        );
        return error.SendToClientReadBeforeLock;
    }
}

test "SseManager: sendToClient removes the client on a failed write (behavioural)" {
    // Verify the failed-write path correctly cleans up: after
    // sendToClient returns ClientDisconnected, the client must no
    // longer be in the manager (so the FD is properly closed and the
    // SseClient struct is freed).
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var server_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer server_arena.deinit();
    const server_allocator = server_arena.allocator();

    var mgr = try SseManager.init(std.testing.allocator, server_allocator, io);
    defer mgr.deinit();

    const pair = try createSocketPair();
    // We close pair[0] BEFORE calling sendToClient so the write
    // fails with EPIPE — this simulates the "peer crashed" scenario
    // that the failed-write branch must clean up. Use the closeFd
    // helper (which short-circuits on Windows, where sockets are HANDLE
    // not i32) instead of posix.system.close directly — calling the
    // latter on Windows fails to compile because posix.system.close
    // expects `*anyopaque` (fd_t on Windows) and we're passing i32.
    closeFd(pair[0]);
    defer closeFd(pair[1]);

    const id: [16]u8 = .{ 0xAA, 0xBB, 0xCC, 0xDD } ++ .{0} ** 12;
    _ = try mgr.registerClientForTest(pair[0], id);
    try std.testing.expect(mgr.clientCount() == 1);

    // sendToClient should observe the failed write, remove the client,
    // and return error.ClientDisconnected.
    const result = mgr.sendToClient(id, "data: ping\n\n");
    try std.testing.expectError(error.ClientDisconnected, result);
    try std.testing.expect(mgr.clientCount() == 0);
}

test "SseManager: sendToClient returns ClientNotFound for an unknown id (behavioural)" {
    // Sanity check: the lock-protected path still returns ClientNotFound
    // when the id is not registered.
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var server_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer server_arena.deinit();
    const server_allocator = server_arena.allocator();

    var mgr = try SseManager.init(std.testing.allocator, server_allocator, io);
    defer mgr.deinit();

    const bogus: [16]u8 = .{0xFE} ** 16;
    const result = mgr.sendToClient(bogus, "data: hello\n\n");
    try std.testing.expectError(error.ClientNotFound, result);
}

test "SseManager: deinit and gracefulShutdown call client.deinit (not forceDestroy)" {
    // Static-contract guard against the 2026-07-01 audit finding:
    // `forceDestroy` closes the fd but leaks the per-client arena and
    // message_queue. Both `deinit` and `gracefulShutdown` must use
    // the full `client.deinit()` so arena memory is freed.
    const source = @embedFile("../../../../src/modules/custom_http_server/src/sse_manager.zig");

    // Find each shutdown function and assert the body uses
    // `entry.value_ptr.*.deinit()` rather than `forceDestroy()`.
    const functions = [_][]const u8{ "pub fn deinit(self: *SseManager) void {", "pub fn gracefulShutdown(self: *SseManager) void {" };
    inline for (functions) |fn_sig| {
        const decl_pos = std.mem.indexOf(u8, source, fn_sig) orelse 0;
        if (decl_pos == 0) {
            std.debug.print("\n!! sse_manager.zig missing {s} !!\n", .{fn_sig});
            return error.ShutdownFnMissing;
        }
        // Each shutdown body is <1 KiB in this codebase.
        const window_end = @min(decl_pos + 1500, source.len);
        const window = source[decl_pos..window_end];

        // Must contain at least one `entry.value_ptr.*.deinit()` call
        // (the iterator loop variable name is consistent across both
        // functions).
        const deinit_pos = std.mem.indexOf(u8, window, "entry.value_ptr.*.deinit()") orelse 0;
        if (deinit_pos == 0) {
            std.debug.print(
                "\n!! sse_manager.zig: {s} must call entry.value_ptr.*.deinit() !!\n" ++
                    "   `forceDestroy` closes the fd but leaks the per-client arena.\n",
                .{fn_sig},
            );
            return error.ShutdownLeakForceDestroy;
        }

        // Must NOT contain `entry.value_ptr.*.forceDestroy()` in the
        // same window — if both are present, the forceDestroy branch
        // would win at runtime and the leak is back.
        const force_pos = std.mem.indexOf(u8, window, "entry.value_ptr.*.forceDestroy()") orelse 0;
        if (force_pos != 0) {
            std.debug.print(
                "\n!! sse_manager.zig: {s} still calls forceDestroy !!\n" ++
                    "   The full `deinit()` is required to free the per-client arena.\n",
                .{fn_sig},
            );
            return error.ShutdownStillUsesForceDestroy;
        }
    }
}

test "root.zig: handleClientDisconnect iterates ALL routing_keys (static contract)" {
    // The 2026-07-01 audit found that the previous `handleClientDisconnect`
    // implementation called `getSessionIdForClient` (which returns the
    // FIRST match) and unregistered only that one routing_key. For
    // clients connected via the unified SSE endpoint (which registers
    // the same client_id under N channels), this left N-1 orphan
    // entries in `session_to_client_ids` that grew with every reconnect.
    //
    // The fix iterates all matches and unregisters each one. This
    // static-contract test verifies the fix is in place by looking for
    // the iteration pattern: `it.next()` inside a `while` loop over
    // the session_to_client_ids iterator.
    const source = @embedFile("../../../../src/root.zig");

    // Find `fn handleClientDisconnect` and check the next ~2 KiB
    // contains BOTH an iterator loop AND a check for the client_id
    // inside the loop body. The previous implementation had a single
    // `getSessionIdForClient` call instead.
    const decl_pos = std.mem.indexOf(u8, source, "pub fn handleClientDisconnect(") orelse 0;
    if (decl_pos == 0) {
        std.debug.print("\n!! root.zig missing `pub fn handleClientDisconnect` !!\n", .{});
        return error.HandleClientDisconnectDeclMissing;
    }
    const window_end = @min(decl_pos + 2000, source.len);
    const window = source[decl_pos..window_end];

    // Must iterate over session_to_client_ids (the iterator loop).
    const it_loop = std.mem.indexOf(u8, window, "session_to_client_ids.iterator()") orelse 0;
    if (it_loop == 0) {
        std.debug.print(
            "\n!! root.zig: handleClientDisconnect must iterate session_to_client_ids !!\n" ++
                "   Without iteration, only one routing_key per disconnect is unregistered.\n",
            .{},
        );
        return error.HandleClientDisconnectNoIteration;
    }

    // Must compare the client_id inside the loop body (the inner
    // `for (entry.value_ptr.items) |v| { ... eql(&v, &client_id) }`).
    const cmp_pos = std.mem.indexOf(u8, window, "std.mem.eql(u8, &v, &client_id)") orelse
        std.mem.indexOf(u8, window, "std.mem.eql(u8, &client_id, &v)") orelse 0;
    if (cmp_pos == 0) {
        std.debug.print(
            "\n!! root.zig: handleClientDisconnect must compare client_id inside the iteration !!\n" ++
                "   Without the inner comparison, the loop iterates but does not match.\n",
            .{},
        );
        return error.HandleClientDisconnectNoCompare;
    }

    // Reverse-direction guard: the OLD single-match pattern must be gone.
    // The previous implementation called `getSessionIdForClient` once.
    if (std.mem.indexOf(u8, window, "getSessionIdForClient(client_id, false)") != null) {
        std.debug.print(
            "\n!! root.zig: handleClientDisconnect still uses single-match getSessionIdForClient !!\n" ++
                "   The fix replaced this with an iterator loop to handle multi-channel clients.\n",
            .{},
        );
        return error.HandleClientDisconnectStillSingleMatch;
    }
}
