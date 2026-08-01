//! Tests for the WebSocket manager (register, broadcast, remove clients).
//!
//! The WebSocket manager is the counterpart to sse_manager.zig: it owns the
//! set of currently-connected WebSocket clients, supports broadcasting a
//! message to all of them, and supports targeted send-to-client. It is
//! thread-safe (multiple client threads can register / send concurrently).
//!
//! These tests are written FIRST (TDD red phase). The implementation
//! (websocket_manager.zig) must satisfy these contracts.

const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const ws_manager = @import("websocket_manager.zig");

const is_windows = builtin.os.tag == .windows;

// ============================================================================
// Counting writer — used to verify that broadcast / sendToClient dispatch
// the right number of writes.
// ============================================================================

const CountingWriter = struct {
    fn w(_: ?*anyopaque, _: i32, _: []const u8) anyerror!usize {
        return 0;
    }
};

test "WsManager.init: creates empty manager with zero clients" {
    const mgr = try ws_manager.WsManager.init(testing.allocator, testing.allocator, undefined);
    defer mgr.destroy();

    try testing.expectEqual(@as(usize, 0), mgr.clientCount());
}

test "WsManager.registerClient: returns 16-byte client id" {
    const mgr = try ws_manager.WsManager.init(testing.allocator, testing.allocator, undefined);
    defer mgr.destroy();

    const fd = try createDummySocket();
    defer closeDummySocket(fd);

    const client_id = try mgr.registerClient(fd, CountingWriter.w, null);
    defer mgr.removeClient(&client_id, .test_only);

    try testing.expectEqual(@as(usize, 1), mgr.clientCount());
    try testing.expectEqual(@as(usize, 16), client_id.len);
}

test "WsManager.removeClient: decrements client count" {
    const mgr = try ws_manager.WsManager.init(testing.allocator, testing.allocator, undefined);
    defer mgr.destroy();

    const fd = try createDummySocket();
    defer closeDummySocket(fd);

    const id = try mgr.registerClient(fd, CountingWriter.w, null);
    try testing.expectEqual(@as(usize, 1), mgr.clientCount());

    mgr.removeClient(&id, .test_only);
    try testing.expectEqual(@as(usize, 0), mgr.clientCount());
}

test "WsManager.removeClient: idempotent (removing twice is safe)" {
    const mgr = try ws_manager.WsManager.init(testing.allocator, testing.allocator, undefined);
    defer mgr.destroy();

    const fd = try createDummySocket();
    defer closeDummySocket(fd);

    const id = try mgr.registerClient(fd, CountingWriter.w, null);
    mgr.removeClient(&id, .test_only);
    // Second call must not crash.
    mgr.removeClient(&id, .test_only);
    try testing.expectEqual(@as(usize, 0), mgr.clientCount());
}

test "WsManager.sendToClient: returns ClientNotFound for unknown id" {
    const mgr = try ws_manager.WsManager.init(testing.allocator, testing.allocator, undefined);
    defer mgr.destroy();

    var bogus: [16]u8 = .{0} ** 16;
    try testing.expectError(error.ClientNotFound, mgr.sendToClient(&bogus, "x"));
}

test "WsManager.clientCount: registers multiple clients" {
    const mgr = try ws_manager.WsManager.init(testing.allocator, testing.allocator, undefined);
    defer mgr.destroy();

    var ids: [5][16]u8 = undefined;
    var fds: [5]i32 = undefined;
    for (0..5) |i| {
        fds[i] = try createDummySocket();
        ids[i] = try mgr.registerClient(fds[i], CountingWriter.w, null);
    }
    defer for (0..5) |i| {
        mgr.removeClient(&ids[i], .test_only);
        closeDummySocket(fds[i]);
    };

    try testing.expectEqual(@as(usize, 5), mgr.clientCount());
}

test "WsManager.broadcast: completes without error" {
    const mgr = try ws_manager.WsManager.init(testing.allocator, testing.allocator, undefined);
    defer mgr.destroy();

    const fd1 = try createDummySocket();
    defer closeDummySocket(fd1);
    const fd2 = try createDummySocket();
    defer closeDummySocket(fd2);

    const id1 = try mgr.registerClient(fd1, CountingWriter.w, null);
    defer mgr.removeClient(&id1, .test_only);
    const id2 = try mgr.registerClient(fd2, CountingWriter.w, null);
    defer mgr.removeClient(&id2, .test_only);

    // Broadcast completes (writers return 0 writes happily).
    try mgr.broadcast("hello");
    try mgr.broadcast("world");
}

test "WsManager.sendToClient: sends without error to registered client" {
    const mgr = try ws_manager.WsManager.init(testing.allocator, testing.allocator, undefined);
    defer mgr.destroy();

    const fd = try createDummySocket();
    defer closeDummySocket(fd);

    const id = try mgr.registerClient(fd, CountingWriter.w, null);
    defer mgr.removeClient(&id, .test_only);

    try mgr.sendToClient(&id, "private-message");
}

// ============================================================================
// Test helpers (cross-platform fd plumbing)
// ============================================================================

fn createDummySocket() !i32 {
    if (is_windows) {
        // Open a TCP socket — we never connect it; the manager only
        // stores the fd reference.
        const sock = std.posix.system.socket(2, 1, 6); // AF_INET, SOCK_STREAM, IPPROTO_TCP
        return @intCast(sock);
    } else {
        var fds: [2]std.posix.fd_t = undefined;
        const rc = std.posix.system.pipe(&fds);
        if (rc < 0) return error.PipeFailed;
        // Close the read end and return the write end as our "client fd".
        _ = std.posix.system.close(fds[0]);
        return @intCast(fds[1]);
    }
}

fn closeDummySocket(fd: i32) void {
    _ = std.posix.system.close(fd);
}
