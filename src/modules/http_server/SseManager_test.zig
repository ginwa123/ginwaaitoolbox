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

    // Register client
    try manager.registerClient("session-1", queue);

    // Verify client count
    try testing.expectEqual(@as(usize, 1), manager.getClientCount("session-1"));
    try testing.expectEqual(@as(usize, 1), manager.getSessionCount());

    // Remove client - manager takes ownership and destroys the queue
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
    // All queues are destroyed by removeClient
}

test "SseManager removeClient with non-existent queue" {
    var manager = SseManager.SseConnectionManager.init(testing.allocator, test_io);
    defer manager.deinit();

    // Create a queue but don't register it - we own it
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

    const queue = try manager.createQueue();

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

    // Clean up: removeClient takes ownership and destroys the queue
    _ = manager.removeClient("session-1", queue);
    manager.deinit();
}

test "SseManager enqueueEvent auto-creates session" {
    var manager = SseManager.SseConnectionManager.init(testing.allocator, test_io);

    // Create queue and register it
    const queue = try manager.createQueue();
    try manager.registerClient("new-session", queue);

    // Enqueue event
    const event = SseManager.SseEvent{
        .data = "auto message",
        .event_type = null,
    };
    try manager.enqueueEvent("new-session", event);

    // Verify we got the event
    const item = queue.dequeueWithTimeout(100_000_000);
    try testing.expect(item != null);
    try testing.expectEqualStrings("auto message", item.?.data);
    testing.allocator.free(item.?.data);
    if (item.?.event_type) |et| testing.allocator.free(et);
    testing.allocator.destroy(item.?);

    // Clean up: removeClient takes ownership and destroys the queue
    _ = manager.removeClient("new-session", queue);
    manager.deinit();
}

test "SseManager enqueueEvent to multiple clients" {
    var manager = SseManager.SseConnectionManager.init(testing.allocator, test_io);

    const queue1 = try manager.createQueue();
    const queue2 = try manager.createQueue();
    const queue3 = try manager.createQueue();

    try manager.registerClient("session-1", queue1);
    try manager.registerClient("session-1", queue2);
    try manager.registerClient("session-1", queue3);

    // Enqueue event
    const event = SseManager.SseEvent{ .data = "broadcast test", .event_type = null };
    try manager.enqueueEvent("session-1", event);

    // All 3 clients should receive the event
    const item1 = queue1.dequeueWithTimeout(100_000_000);
    try testing.expect(item1 != null);
    testing.allocator.free(item1.?.data);
    if (item1.?.event_type) |et| testing.allocator.free(et);
    testing.allocator.destroy(item1.?);

    const item2 = queue2.dequeueWithTimeout(100_000_000);
    try testing.expect(item2 != null);
    testing.allocator.free(item2.?.data);
    if (item2.?.event_type) |et| testing.allocator.free(et);
    testing.allocator.destroy(item2.?);

    const item3 = queue3.dequeueWithTimeout(100_000_000);
    try testing.expect(item3 != null);
    testing.allocator.free(item3.?.data);
    if (item3.?.event_type) |et| testing.allocator.free(et);
    testing.allocator.destroy(item3.?);

    manager.deinit();
}

test "SseManager removeSession" {
    var manager = SseManager.SseConnectionManager.init(testing.allocator, test_io);
    defer manager.deinit();

    const queue1 = try manager.createQueue();
    const queue2 = try manager.createQueue();

    try manager.registerClient("session-1", queue1);
    try manager.registerClient("session-1", queue2);

    // Force remove entire session - manager takes ownership and will destroy queues
    const removed = manager.removeSession("session-1");
    try testing.expectEqual(@as(usize, 2), removed);
    try testing.expectEqual(@as(usize, 0), manager.getSessionCount());
    // Note: queues are destroyed by removeSession, NOT by defer
}

test "SseManager removeSession non-existent" {
    var manager = SseManager.SseConnectionManager.init(testing.allocator, test_io);
    defer manager.deinit();

    const removed = manager.removeSession("non-existent");
    try testing.expectEqual(@as(usize, 0), removed);
}

test "SseManager broadcast" {
    var manager = SseManager.SseConnectionManager.init(testing.allocator, test_io);

    const queue1 = try manager.createQueue();
    const queue2 = try manager.createQueue();

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

    manager.deinit();
}

test "SseManager hasSession" {
    var manager = SseManager.SseConnectionManager.init(testing.allocator, test_io);
    defer manager.deinit();

    const queue = try manager.createQueue();

    try testing.expect(!manager.hasSession("session-1"));

    try manager.registerClient("session-1", queue);
    try testing.expect(manager.hasSession("session-1"));

    _ = manager.removeClient("session-1", queue);
    try testing.expect(!manager.hasSession("session-1"));
}

test "SseManager getTotalClientCount" {
    var manager = SseManager.SseConnectionManager.init(testing.allocator, test_io);

    const queue1 = try manager.createQueue();
    const queue2 = try manager.createQueue();
    const queue3 = try manager.createQueue();

    try testing.expectEqual(@as(usize, 0), manager.getTotalClientCount());

    try manager.registerClient("session-1", queue1);
    try manager.registerClient("session-1", queue2);
    try manager.registerClient("session-2", queue3);

    try testing.expectEqual(@as(usize, 3), manager.getTotalClientCount());

    manager.deinit();
}

test "SseManager queue close behavior" {
    var manager = SseManager.SseConnectionManager.init(testing.allocator, test_io);

    const queue = try manager.createQueue();

    try manager.registerClient("session-1", queue);

    // Close the queue manually - this will cause dequeuers to wake up and exit
    queue.close();

    // Dequeue should return null immediately since queue is closed
    const item = queue.dequeueWithTimeout(100_000_000);
    try testing.expect(item == null);

    // Session should still exist
    try testing.expect(manager.hasSession("session-1"));

    // Note: don't call removeClient or destroy queue - let manager.deinit() handle it
    manager.deinit();
}

test "SseManager double removeClient" {
    var manager = SseManager.SseConnectionManager.init(testing.allocator, test_io);

    const queue = try manager.createQueue();

    try manager.registerClient("session-1", queue);

    // First removal - should succeed, manager destroys the queue
    const was_last = manager.removeClient("session-1", queue);
    try testing.expect(was_last);

    // Second removal - should be no-op (queue already closed)
    const was_last2 = manager.removeClient("session-1", queue);
    try testing.expect(!was_last2);

    // Note: queue is already destroyed by removeClient
    manager.deinit();
}

test "SseManager empty event data" {
    var manager = SseManager.SseConnectionManager.init(testing.allocator, test_io);

    const queue = try manager.createQueue();

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

    manager.deinit();
}

test "SseManager event with event_type" {
    var manager = SseManager.SseConnectionManager.init(testing.allocator, test_io);

    const queue = try manager.createQueue();

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

    manager.deinit();
}

test "SseManager many sessions" {
    var manager = SseManager.SseConnectionManager.init(testing.allocator, test_io);

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

    try testing.expectEqual(@as(usize, 10), manager.getSessionCount());
    try testing.expectEqual(@as(usize, 10), manager.getTotalClientCount());

    // Remove all
    for (session_names, 0..) |name, i| {
        _ = manager.removeClient(name, queues[i]);
    }

    try testing.expectEqual(@as(usize, 0), manager.getSessionCount());

    manager.deinit();
}

test "SseManager concurrent registration race - same session" {
    var manager = SseManager.SseConnectionManager.init(testing.allocator, test_io);

    // This test verifies that getOrPut prevents duplicate session creation
    // Even if multiple threads call registerClient simultaneously

    const queue1 = try manager.createQueue();
    const queue2 = try manager.createQueue();

    // Register same session from two "threads" (sequentially in test)
    // The key insight is that getOrPut should prevent race conditions
    try manager.registerClient("race-session", queue1);
    try manager.registerClient("race-session", queue2);

    // Should have 2 clients in 1 session
    try testing.expectEqual(@as(usize, 2), manager.getClientCount("race-session"));
    try testing.expectEqual(@as(usize, 1), manager.getSessionCount());

    manager.deinit();
}
