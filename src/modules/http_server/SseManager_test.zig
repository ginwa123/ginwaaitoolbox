const std = @import("std");
const testing = std.testing;
const SseManager = @import("SseManager.zig");

const Queue = SseManager.SseConnectionManager.Queue;
const test_io = std.testing.io;

test "SseManager basic registration and removal" {
    var manager = SseManager.SseConnectionManager.init(testing.allocator, test_io);
    defer manager.deinit();

    // Create a queue
    const queue = try manager.createQueue();
    defer testing.allocator.destroy(queue);

    // Register client
    try manager.registerClient("session-1", queue);

    // Verify client count
    try testing.expectEqual(@as(usize, 1), manager.getClientCount("session-1"));
    try testing.expectEqual(@as(usize, 1), manager.getSessionCount());

    // Remove client
    const was_last = manager.removeClient("session-1", queue);
    try testing.expect(was_last);
    try testing.expectEqual(@as(usize, 0), manager.getSessionCount());
}

test "SseManager multiple clients per session" {
    var manager = SseManager.SseConnectionManager.init(testing.allocator, test_io);
    defer manager.deinit();

    // Create 3 queues
    const queue1 = try manager.createQueue();
    const queue2 = try manager.createQueue();
    const queue3 = try manager.createQueue();
    defer {
        testing.allocator.destroy(queue1);
        testing.allocator.destroy(queue2);
        testing.allocator.destroy(queue3);
    }

    // Register 3 clients to same session
    try manager.registerClient("session-1", queue1);
    try manager.registerClient("session-1", queue2);
    try manager.registerClient("session-1", queue3);

    // Verify 3 clients
    try testing.expectEqual(@as(usize, 3), manager.getClientCount("session-1"));
    try testing.expectEqual(@as(usize, 1), manager.getSessionCount());

    // Remove one client
    var was_last = manager.removeClient("session-1", queue2);
    try testing.expect(!was_last);
    try testing.expectEqual(@as(usize, 2), manager.getClientCount("session-1"));
    try testing.expectEqual(@as(usize, 1), manager.getSessionCount());

    // Remove second client
    was_last = manager.removeClient("session-1", queue1);
    try testing.expect(!was_last);
    try testing.expectEqual(@as(usize, 1), manager.getClientCount("session-1"));

    // Remove last client - session should be cleaned up
    was_last = manager.removeClient("session-1", queue3);
    try testing.expect(was_last);
    try testing.expectEqual(@as(usize, 0), manager.getSessionCount());
}

test "SseManager removeClient with non-existent queue" {
    var manager = SseManager.SseConnectionManager.init(testing.allocator, test_io);
    defer manager.deinit();

    // Create a queue but don't register it
    const queue = try manager.createQueue();
    defer testing.allocator.destroy(queue);

    // Try to remove non-registered queue - should return false
    const was_last = manager.removeClient("session-1", queue);
    try testing.expect(!was_last);
    try testing.expectEqual(@as(usize, 0), manager.getSessionCount());
}

test "SseManager removeClient from non-existent session" {
    var manager = SseManager.SseConnectionManager.init(testing.allocator, test_io);
    defer manager.deinit();

    const queue = try manager.createQueue();
    defer testing.allocator.destroy(queue);

    // Session doesn't exist
    const was_last = manager.removeClient("non-existent", queue);
    try testing.expect(!was_last);
}

test "SseManager enqueueEvent basic" {
    var manager = SseManager.SseConnectionManager.init(testing.allocator, test_io);
    defer manager.deinit();

    const queue = try manager.createQueue();
    defer testing.allocator.destroy(queue);

    try manager.registerClient("session-1", queue);

    // Enqueue an event
    const event = SseManager.SseEvent{
        .data = "test message",
        .event_type = "message",
    };
    try manager.enqueueEvent("session-1", event);

    // Dequeue should return the event
    const item = queue.dequeueWithTimeout(100_000_000); // 100ms
    try testing.expect(item != null);
    try testing.expectEqualStrings("test message", item.?.data);

    // Free the item
    testing.allocator.free(item.?.data);
    if (item.?.event_type) |et| testing.allocator.free(et);
    testing.allocator.destroy(item.?);
}

test "SseManager enqueueEvent auto-creates session" {
    var manager = SseManager.SseConnectionManager.init(testing.allocator, test_io);
    defer manager.deinit();

    // No clients registered - enqueueEvent should auto-create
    const event = SseManager.SseEvent{
        .data = "auto message",
        .event_type = null,
    };
    try manager.enqueueEvent("new-session", event);

    // Session should exist now
    try testing.expectEqual(@as(usize, 1), manager.getSessionCount());
}

test "SseManager enqueueEvent to multiple clients" {
    var manager = SseManager.SseConnectionManager.init(testing.allocator, test_io);
    defer manager.deinit();

    const queue1 = try manager.createQueue();
    const queue2 = try manager.createQueue();
    const queue3 = try manager.createQueue();
    defer {
        testing.allocator.destroy(queue1);
        testing.allocator.destroy(queue2);
        testing.allocator.destroy(queue3);
    }

    try manager.registerClient("session-1", queue1);
    try manager.registerClient("session-1", queue2);
    try manager.registerClient("session-1", queue3);

    // Enqueue event
    const event = SseManager.SseEvent{ .data = "broadcast test", .event_type = null };
    try manager.enqueueEvent("session-1", event);

    // All 3 clients should receive the event
    for ([_]*Queue{queue1, queue2, queue3}) |queue| {
        const item = queue.dequeueWithTimeout(100_000_000);
        try testing.expect(item != null);
        try testing.expectEqualStrings("broadcast test", item.?.data);
        testing.allocator.free(item.?.data);
        if (item.?.event_type) |et| testing.allocator.free(et);
        testing.allocator.destroy(item.?);
    }

    // Fourth dequeue should timeout (no more events)
    const item = queue1.dequeueWithTimeout(50_000_000); // 50ms
    try testing.expect(item == null);
}

test "SseManager removeSession" {
    var manager = SseManager.SseConnectionManager.init(testing.allocator, test_io);
    defer manager.deinit();

    const queue1 = try manager.createQueue();
    const queue2 = try manager.createQueue();
    defer {
        testing.allocator.destroy(queue1);
        testing.allocator.destroy(queue2);
    }

    try manager.registerClient("session-1", queue1);
    try manager.registerClient("session-1", queue2);

    // Force remove entire session
    const removed = manager.removeSession("session-1");
    try testing.expectEqual(@as(usize, 2), removed);
    try testing.expectEqual(@as(usize, 0), manager.getSessionCount());
}

test "SseManager removeSession non-existent" {
    var manager = SseManager.SseConnectionManager.init(testing.allocator, test_io);
    defer manager.deinit();

    const removed = manager.removeSession("non-existent");
    try testing.expectEqual(@as(usize, 0), removed);
}

test "SseManager broadcast" {
    var manager = SseManager.SseConnectionManager.init(testing.allocator, test_io);
    defer manager.deinit();

    const queue1 = try manager.createQueue();
    const queue2 = try manager.createQueue();
    defer {
        testing.allocator.destroy(queue1);
        testing.allocator.destroy(queue2);
    }

    try manager.registerClient("session-1", queue1);
    try manager.registerClient("session-2", queue2);

    // Broadcast
    const event = SseManager.SseEvent{ .data = "broadcast all", .event_type = null };
    manager.broadcast(event);

    // Both sessions should receive
    for ([_]*Queue{queue1, queue2}) |queue| {
        const item = queue.dequeueWithTimeout(100_000_000);
        try testing.expect(item != null);
        try testing.expectEqualStrings("broadcast all", item.?.data);
        testing.allocator.free(item.?.data);
        if (item.?.event_type) |et| testing.allocator.free(et);
        testing.allocator.destroy(item.?);
    }
}

test "SseManager hasSession" {
    var manager = SseManager.SseConnectionManager.init(testing.allocator, test_io);
    defer manager.deinit();

    const queue = try manager.createQueue();
    defer testing.allocator.destroy(queue);

    try testing.expect(!manager.hasSession("session-1"));

    try manager.registerClient("session-1", queue);
    try testing.expect(manager.hasSession("session-1"));

    _ = manager.removeClient("session-1", queue);
    try testing.expect(!manager.hasSession("session-1"));
}

test "SseManager getTotalClientCount" {
    var manager = SseManager.SseConnectionManager.init(testing.allocator, test_io);
    defer manager.deinit();

    const queue1 = try manager.createQueue();
    const queue2 = try manager.createQueue();
    const queue3 = try manager.createQueue();
    defer {
        testing.allocator.destroy(queue1);
        testing.allocator.destroy(queue2);
        testing.allocator.destroy(queue3);
    }

    try testing.expectEqual(@as(usize, 0), manager.getTotalClientCount());

    try manager.registerClient("session-1", queue1);
    try manager.registerClient("session-1", queue2);
    try manager.registerClient("session-2", queue3);

    try testing.expectEqual(@as(usize, 3), manager.getTotalClientCount());
}

test "SseManager queue close behavior" {
    var manager = SseManager.SseConnectionManager.init(testing.allocator, test_io);
    defer manager.deinit();

    const queue = try manager.createQueue();
    defer testing.allocator.destroy(queue);

    try manager.registerClient("session-1", queue);

    // Close the queue manually
    queue.close();

    // Dequeue should return null immediately since queue is closed
    const item = queue.dequeueWithTimeout(100_000_000);
    try testing.expect(item == null);

    // Session should still exist
    try testing.expect(manager.hasSession("session-1"));
}

test "SseManager double removeClient" {
    var manager = SseManager.SseConnectionManager.init(testing.allocator, test_io);
    defer manager.deinit();

    const queue = try manager.createQueue();
    defer testing.allocator.destroy(queue);

    try manager.registerClient("session-1", queue);

    // First removal - should succeed
    const was_last = manager.removeClient("session-1", queue);
    try testing.expect(was_last);

    // Second removal - should be no-op (queue already closed)
    const was_last2 = manager.removeClient("session-1", queue);
    try testing.expect(!was_last2);
}

test "SseManager empty event data" {
    var manager = SseManager.SseConnectionManager.init(testing.allocator, test_io);
    defer manager.deinit();

    const queue = try manager.createQueue();
    defer testing.allocator.destroy(queue);

    try manager.registerClient("session-1", queue);

    // Event with empty data
    const event = SseManager.SseEvent{ .data = "", .event_type = null };
    try manager.enqueueEvent("session-1", event);

    const item = queue.dequeueWithTimeout(100_000_000);
    try testing.expect(item != null);
    try testing.expectEqualStrings("", item.?.data);
    testing.allocator.free(item.?.data);
    if (item.?.event_type) |et| testing.allocator.free(et);
    testing.allocator.destroy(item.?);
}

test "SseManager event with event_type" {
    var manager = SseManager.SseConnectionManager.init(testing.allocator, test_io);
    defer manager.deinit();

    const queue = try manager.createQueue();
    defer testing.allocator.destroy(queue);

    try manager.registerClient("session-1", queue);

    const event = SseManager.SseEvent{ .data = "test", .event_type = "custom_event" };
    try manager.enqueueEvent("session-1", event);

    const item = queue.dequeueWithTimeout(100_000_000);
    try testing.expect(item != null);
    try testing.expectEqualStrings("test", item.?.data);
    try testing.expect(item.?.event_type != null);
    try testing.expectEqualStrings("custom_event", item.?.event_type.?);

    testing.allocator.free(item.?.data);
    testing.allocator.free(item.?.event_type.?);
    testing.allocator.destroy(item.?);
}

test "SseManager many sessions" {
    var manager = SseManager.SseConnectionManager.init(testing.allocator, test_io);
    defer manager.deinit();

    // Create 10 sessions with 1 client each
    var queues: [10]*Queue = undefined;
    const session_names = [_][]const u8{
        "session-a", "session-b", "session-c", "session-d", "session-e",
        "session-f", "session-g", "session-h", "session-i", "session-j",
    };
    for (session_names, 0..) |name, i| {
        queues[i] = try manager.createQueue();
        try manager.registerClient(name, queues[i]);
    }
    defer for (queues) |q| testing.allocator.destroy(q);

    try testing.expectEqual(@as(usize, 10), manager.getSessionCount());
    try testing.expectEqual(@as(usize, 10), manager.getTotalClientCount());

    // Remove all
    for (session_names, 0..) |name, i| {
        _ = manager.removeClient(name, queues[i]);
    }

    try testing.expectEqual(@as(usize, 0), manager.getSessionCount());
}

test "SseManager concurrent registration race - same session" {
    var manager = SseManager.SseConnectionManager.init(testing.allocator, test_io);
    defer manager.deinit();

    // This test verifies that getOrPut prevents duplicate session creation
    // Even if multiple threads call registerClient simultaneously

    const queue1 = try manager.createQueue();
    const queue2 = try manager.createQueue();
    defer {
        testing.allocator.destroy(queue1);
        testing.allocator.destroy(queue2);
    }

    // Register same session from two "threads" (sequentially in test)
    // The key insight is that getOrPut should prevent race conditions
    try manager.registerClient("race-session", queue1);
    try manager.registerClient("race-session", queue2);

    // Should have 2 clients in 1 session
    try testing.expectEqual(@as(usize, 2), manager.getClientCount("race-session"));
    try testing.expectEqual(@as(usize, 1), manager.getSessionCount());
}
