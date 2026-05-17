const std = @import("std");
const sse_manager = @import("sse_manager.zig");
const SseManager = sse_manager.SseManager;
const SseClient = sse_manager.SseClient;
const linux = std.posix.system;

// Helper to create a pair of connected sockets for testing
// AF_UNIX=1, SOCK_STREAM=1
fn createSocketPair() ![2]i32 {
    var fds: [2]i32 = undefined;
    const rc = linux.socketpair(1, 1, 0, &fds);
    if (rc < 0) return error.SocketPairFailed;
    return fds;
}

// ============================================================================
// SSE Manager Tests - Client Registration and Removal
// ============================================================================

test "SseManager: register and remove single client" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var server_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer server_arena.deinit();
    const server_allocator = server_arena.allocator();

    var mgr = try SseManager.init(allocator, server_allocator);
    defer mgr.deinit();

    // Create a socket pair for testing
    const pair = try createSocketPair();
    defer {
        _ = linux.close(pair[0]);
        _ = linux.close(pair[1]);
    }

    // Register a client
    _ = try mgr.registerClient(pair[0]);
    try std.testing.expect(mgr.clientCount() == 1);

    // Remove client by fd
    const removed_id = mgr.removeClientByFd(pair[0]);
    try std.testing.expect(removed_id != null);
    try std.testing.expect(mgr.clientCount() == 0);
}

test "SseManager: register and remove multiple clients" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var server_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer server_arena.deinit();
    const server_allocator = server_arena.allocator();

    var mgr = try SseManager.init(allocator, server_allocator);
    defer mgr.deinit();

    // Create multiple socket pairs
    const pair1 = try createSocketPair();
    const pair2 = try createSocketPair();
    const pair3 = try createSocketPair();
    defer {
        _ = linux.close(pair1[0]);
        _ = linux.close(pair1[1]);
        _ = linux.close(pair2[0]);
        _ = linux.close(pair2[1]);
        _ = linux.close(pair3[0]);
        _ = linux.close(pair3[1]);
    }

    // Register multiple clients
    _ = try mgr.registerClient(pair1[0]);
    _ = try mgr.registerClient(pair2[0]);
    _ = try mgr.registerClient(pair3[0]);
    try std.testing.expect(mgr.clientCount() == 3);

    // Remove each client one by one
    _ = mgr.removeClientByFd(pair2[0]);
    try std.testing.expect(mgr.clientCount() == 2);

    _ = mgr.removeClientByFd(pair1[0]);
    try std.testing.expect(mgr.clientCount() == 1);

    _ = mgr.removeClientByFd(pair3[0]);
    try std.testing.expect(mgr.clientCount() == 0);
}

test "SseManager: remove by ID works correctly" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var server_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer server_arena.deinit();
    const server_allocator = server_arena.allocator();

    var mgr = try SseManager.init(allocator, server_allocator);
    defer mgr.deinit();

    const pair = try createSocketPair();
    defer {
        _ = linux.close(pair[0]);
        _ = linux.close(pair[1]);
    }

    const id = try mgr.registerClient(pair[0]);
    try std.testing.expect(mgr.clientCount() == 1);

    // Remove by ID
    mgr.removeClient(id);
    try std.testing.expect(mgr.clientCount() == 0);
}

test "SseManager: remove non-existent client returns null" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var server_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer server_arena.deinit();
    const server_allocator = server_arena.allocator();

    var mgr = try SseManager.init(allocator, server_allocator);
    defer mgr.deinit();

    // Try to remove a client that doesn't exist
    const result = mgr.removeClientByFd(9999);
    try std.testing.expect(result == null);
}

test "SseManager: deinit cleans up all clients" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var server_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer server_arena.deinit();
    const server_allocator = server_arena.allocator();

    var mgr = try SseManager.init(allocator, server_allocator);

    // Create and register multiple clients
    var socket_pairs = std.ArrayListUnmanaged([2]i32){ .items = &.{}, .capacity = 0 };
    defer {
        // Note: manager already closed read ends, only close write ends
        for (socket_pairs.items) |fds| {
            _ = linux.close(fds[1]);
        }
        socket_pairs.deinit(allocator);
    }

    for (0..5) |_| {
        const fds = try createSocketPair();
        try socket_pairs.append(allocator, fds);
        _ = try mgr.registerClient(fds[0]);
    }

    try std.testing.expect(mgr.clientCount() == 5);

    // deinit should clean up without crashing
    mgr.deinit();

    // Close the other ends of socket pairs
    for (socket_pairs.items) |fds| {
        _ = linux.close(fds[1]);
    }
}

test "SseManager: removeClientByFd then removeClient (race condition test)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var server_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer server_arena.deinit();
    const server_allocator = server_arena.allocator();

    var mgr = try SseManager.init(allocator, server_allocator);
    defer mgr.deinit();

    const pair = try createSocketPair();
    defer {
        _ = linux.close(pair[0]);
        _ = linux.close(pair[1]);
    }

    _ = try mgr.registerClient(pair[0]);

    // First removal by fd
    const removed = mgr.removeClientByFd(pair[0]);
    try std.testing.expect(removed != null);
    try std.testing.expect(mgr.clientCount() == 0);

    // Second removal by id should be a no-op
    mgr.removeClient(removed.?);
    try std.testing.expect(mgr.clientCount() == 0);
}

test "SseManager: removeClient then removeClientByFd (race condition test)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var server_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer server_arena.deinit();
    const server_allocator = server_arena.allocator();

    var mgr = try SseManager.init(allocator, server_allocator);
    defer mgr.deinit();

    const pair = try createSocketPair();
    defer {
        _ = linux.close(pair[0]);
        _ = linux.close(pair[1]);
    }

    const id = try mgr.registerClient(pair[0]);

    // First removal by id
    mgr.removeClient(id);
    try std.testing.expect(mgr.clientCount() == 0);

    // Second removal by fd should be a no-op
    const removed = mgr.removeClientByFd(pair[0]);
    try std.testing.expect(removed == null);
    try std.testing.expect(mgr.clientCount() == 0);
}

test "SseManager: register same fd twice returns same id" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var server_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer server_arena.deinit();
    const server_allocator = server_arena.allocator();

    var mgr = try SseManager.init(allocator, server_allocator);
    defer mgr.deinit();

    const pair = try createSocketPair();
    defer {
        _ = linux.close(pair[0]);
        _ = linux.close(pair[1]);
    }

    const id1 = try mgr.registerClient(pair[0]);
    const id2 = try mgr.registerClient(pair[0]);

    // Should return the same id (no duplicate registration)
    try std.testing.expectEqualSlices(u8, &id1, &id2);
    try std.testing.expect(mgr.clientCount() == 1);
}

test "SseClient: deinit doesn't crash on closed fd" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // Create an invalid socket fd by closing immediately
    const pair = try createSocketPair();
    // Close the first socket
    _ = linux.close(pair[0]);

    var id: [16]u8 = undefined;
    @memset(&id, 0);

    // Create client with already-closed fd
    var client = SseClient.init(id, pair[0], allocator);

    // deinit should not crash even though fd is invalid
    client.deinit();
    _ = linux.close(pair[1]);
}

test "SseManager: stress test - rapid add/remove" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var server_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer server_arena.deinit();
    const server_allocator = server_arena.allocator();

    var mgr = try SseManager.init(allocator, server_allocator);
    defer mgr.deinit();

    // Rapidly add and remove clients
    var socket_pairs = std.ArrayListUnmanaged([2]i32){ .items = &.{}, .capacity = 0 };
    defer {
        // Close write ends (read ends were closed by mgr.deinit)
        for (socket_pairs.items) |fds| {
            _ = linux.close(fds[1]);
        }
        socket_pairs.deinit(allocator);
    }

    for (0..10) |_| {
        const fds = try createSocketPair();
        try socket_pairs.append(allocator, fds);
        _ = try mgr.registerClient(fds[0]);
    }

    try std.testing.expect(mgr.clientCount() == 10);

    // Remove all in reverse order
    for (0..10) |i| {
        const idx = 10 - 1 - i;
        _ = mgr.removeClientByFd(socket_pairs.items[idx][0]);
    }

    try std.testing.expect(mgr.clientCount() == 0);

    // Clean up other ends
    for (socket_pairs.items) |fds| {
        _ = linux.close(fds[1]);
    }
}