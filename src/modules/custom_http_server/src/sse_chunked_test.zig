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
