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

fn createSocketPair() ![2]i32 {
    if (builtin.os.tag == .windows) {
        // On Windows we need socket + accept/connect instead of socketpair.
        const server_sock = try posix.socket(.ipv6, .stream, .passive);
        defer _ = posix.system.close(server_sock);
        const addr = std.net.Address.initIpv6([_]u8{0} ** 16, 0, 0, 0, 0, 0, 0, 0, 127, 0, 0, 1);
        try posix.bind(server_sock, &addr);
        _ = posix.listen(server_sock, 1);
        const bound_addr = try posix.getsockname(server_sock, null);
        const client_sock = try posix.socket(.ipv6, .stream, .active);
        _ = posix.connect(client_sock, &bound_addr);
        const server_conn = try posix.accept(server_sock, null, null);
        return [2]i32{ client_sock, server_conn };
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
    defer _ = posix.system.close(pair[0]);
    defer _ = posix.system.close(pair[1]);

    try sse_manager.writeChunkedFrame(pair[0], "event: ping\ndata: 1\n\n");

    // Read on the OTHER end of the socketpair and assert the chunked frame.
    // Data is 21 bytes → hex len "15" → "15\r\n" (4) + data (21) + "\r\n" (2) = 27.
    var buf: [64]u8 = undefined;
    const n = posix.system.read(pair[1], &buf, buf.len);
    try std.testing.expect(n == 27);
    try std.testing.expectEqualSlices(u8, "15\r\nevent: ping\ndata: 1\n\n\r\n", buf[0..@intCast(n)]);
}

test "writeChunkedFrame: empty data writes 0\\r\\n\\r\\n (chunked terminator)" {
    const pair = try createSocketPair();
    defer _ = posix.system.close(pair[0]);
    defer _ = posix.system.close(pair[1]);

    try sse_manager.writeChunkedFrame(pair[0], "");

    var buf: [16]u8 = undefined;
    const n = posix.system.read(pair[1], &buf, buf.len);
    try std.testing.expect(n == 5);
    try std.testing.expectEqualSlices(u8, "0\r\n\r\n", buf[0..@intCast(n)]);
}

test "SseClient: sendEvent writes <hex len>\\r\\n<data>\\r\\n" {
    const pair = try createSocketPair();
    defer _ = posix.system.close(pair[0]);
    defer _ = posix.system.close(pair[1]);

    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();

    const id: [16]u8 = .{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16 };
    var client: sse_manager.SseClient = .init(id, pair[0], std.testing.allocator, threaded.io());
    // Suppress the per-client arena cleanup on scope-exit (it would
    // double-free the fd that `posix.system.close(pair[0])` above
    // also closes). The test only needs `client.sendEvent` to write
    // the chunked frame; we explicitly call `forceDestroy` to close
    // the fd without deinitialising the arena.
    defer client.forceDestroy();
    try client.sendEvent("event: ping\ndata: 1\n\n");

    var buf: [64]u8 = undefined;
    const n = posix.system.read(pair[1], &buf, buf.len);
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
    defer _ = posix.system.close(pair[1]);

    // Use registerClientForTest so the random-id path (which requires
    // being on the Io thread) is bypassed.
    const id = try mgr.registerClientForTest(pair[0], .{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16 });

    // Send one event so the peer has a chunked frame on the wire.
    try mgr.sendChunked(id, "event: ping\ndata: 1\n\n");

    // removeClient must (a) flush the terminator, then (b) close the fd.
    mgr.removeClient(id);

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
        const n = posix.system.read(pair[1], &buf, buf.len - total);
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
// Task 1.4 (this plan): SseManager must define `sendDeferred` that spawns a
// group.concurrent task — guards against someone removing the helper in
// a future refactor and silently regressing the kanban-SSE handler
// blocking fix.
//
// Bug history (pre-fix): every SSE handler called `sendToClient` for
// the connected-event handshake synchronously, blocking the
// `group.concurrent` worker thread until the kernel TCP send
// completed. With 4 SSE event loops parked in `socket.poll`
// (`LOOP_COUNT=4`), the worker pool could starve under a burst of
// SSE connections, blocking every other HTTP API call.
//
// Fix: `sendDeferred` spawns the send on `send_group` (a long-lived
// internal Io Group), freeing the caller's worker thread immediately.
// The connected-event handshake (38 bytes of static-literal data)
// is safe to defer — the worker reads the literal's static memory.
// ============================================================================

test "SseManager: defines sendDeferred that uses send_group.concurrent (NOT synchronous sendToClient)" {
    const source = try readSseManagerSource(std.testing.allocator);
    defer std.testing.allocator.free(source);

    // 1. The helper must exist.
    const decl = std.mem.indexOf(u8, source, "fn sendDeferred(") orelse {
        std.debug.print(
            "\n!! sse_manager.zig missing `fn sendDeferred` !!\n" ++
                "   The SSE handler blocking fix requires a fire-and-forget helper that\n" ++
                "   spawns the connected-event send on a separate worker thread. Without\n" ++
                "   this, every SSE handshake parks the calling `group.concurrent` worker\n" ++
                "   thread on `socket.write`, starving the Io worker pool.\n",
            .{},
        );
        return error.SendDeferredMissing;
    };
    const window_end = @min(decl + 4096, source.len);
    const body = source[decl..window_end];

    // 2. The helper must spawn via `send_group.concurrent` (NOT call
    //    `sendToClient` directly — that would re-introduce the
    //    synchronous-block bug we just fixed).
    if (std.mem.indexOf(u8, body, "send_group.concurrent") == null) {
        std.debug.print(
            "\n!! sse_manager.zig: sendDeferred does not use `send_group.concurrent` !!\n" ++
                "   The helper must spawn the send on the internal `send_group` Io Group\n" ++
                "   so the calling worker thread is freed immediately.\n",
            .{},
        );
        return error.SendDeferredNotConcurrent;
    }

    // NOTE: we deliberately do NOT also assert "sendDeferred must not
    // call sendToClient". The spawned task body inside the
    // `send_group.concurrent(...)` call MUST call `sendToClient` to
    // actually send data — that is the entire point of the helper
    // (delegate to the worker, not the caller). A `sendToClient`
    // call inside the spawned `run` function is correct and required.
    // The wrong pattern would be a `sendToClient` call OUTSIDE the
    // `send_group.concurrent(...)` invocation, but that would
    // necessarily mean `send_group.concurrent` is missing from the
    // helper body — which check #2 already catches. Asserting the
    // negative here would be a false-positive tripwire.
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
