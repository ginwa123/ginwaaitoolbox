const std = @import("std");
const cancellation_registry = @import("cancellation_registry.zig");

test "CancellationRegistry can register and check cancellation" {
    const allocator = std.testing.allocator;
    var registry = cancellation_registry.CancellationRegistry.init(allocator);
    defer registry.deinit();

    const session_id = "session-123";
    try registry.register(session_id);
    
    // Initially not cancelled
    try std.testing.expect(!registry.isCancelled(session_id));
    
    // Cancel the session
    registry.cancel(session_id);
    try std.testing.expect(registry.isCancelled(session_id));
}

test "CancellationRegistry supports multiple sessions independently" {
    const allocator = std.testing.allocator;
    var registry = cancellation_registry.CancellationRegistry.init(allocator);
    defer registry.deinit();

    const session_a = "session-a";
    const session_b = "session-b";
    
    try registry.register(session_a);
    try registry.register(session_b);
    
    // Cancel only session A
    registry.cancel(session_a);
    
    // Session A should be cancelled
    try std.testing.expect(registry.isCancelled(session_a));
    // Session B should NOT be cancelled
    try std.testing.expect(!registry.isCancelled(session_b));
}

test "CancellationRegistry can reset session" {
    const allocator = std.testing.allocator;
    var registry = cancellation_registry.CancellationRegistry.init(allocator);
    defer registry.deinit();

    const session_id = "session-123";
    try registry.register(session_id);
    
    registry.cancel(session_id);
    try std.testing.expect(registry.isCancelled(session_id));
    
    registry.reset(session_id);
    try std.testing.expect(!registry.isCancelled(session_id));
}

test "CancellationRegistry can unregister session" {
    const allocator = std.testing.allocator;
    var registry = cancellation_registry.CancellationRegistry.init(allocator);
    defer registry.deinit();

    const session_id = "session-123";
    try registry.register(session_id);
    try std.testing.expect(registry.isRegistered(session_id));
    
    registry.unregister(session_id);
    try std.testing.expect(!registry.isRegistered(session_id));
}

test "CancellationRegistry hasSessions returns false when empty" {
    const allocator = std.testing.allocator;
    var registry = cancellation_registry.CancellationRegistry.init(allocator);
    defer registry.deinit();
    try std.testing.expect(!registry.hasSessions());
}

test "CancellationRegistry hasSessions returns true when session registered" {
    const allocator = std.testing.allocator;
    var registry = cancellation_registry.CancellationRegistry.init(allocator);
    defer registry.deinit();
    try registry.register("session-1");
    try std.testing.expect(registry.hasSessions());
}

test "CancellationRegistry sessionCount returns correct count" {
    const allocator = std.testing.allocator;
    var registry = cancellation_registry.CancellationRegistry.init(allocator);
    defer registry.deinit();
    try std.testing.expectEqual(@as(usize, 0), registry.sessionCount());
    try registry.register("session-1");
    try std.testing.expectEqual(@as(usize, 1), registry.sessionCount());
    try registry.register("session-2");
    try std.testing.expectEqual(@as(usize, 2), registry.sessionCount());
    registry.unregister("session-1");
    try std.testing.expectEqual(@as(usize, 1), registry.sessionCount());
}
