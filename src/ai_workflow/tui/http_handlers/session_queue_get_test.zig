const std = @import("std");
const activity_registry = @import("nalarcore").session.activity_registry;

// Test module for session_queue_get handler
// TDD: Tests come first - these validate the handler exists and works correctly

// Import the handler - this will fail to compile until we create the handler
const session_queue_get = @import("session_queue_get.zig");

test "session_queue_get: handler function exists" {
    // If this compiles, the handler exists with correct signature
    const HandlerType = @TypeOf(session_queue_get.sessionQueueGetHandler);
    try std.testing.expect(HandlerType != noreturn);
    try std.testing.expect(HandlerType != void);
}

test "session_queue_get: ActivityRegistry.get_queue_messages returns messages" {
    const allocator = std.testing.allocator;
    var registry = activity_registry.ActivityRegistry.init(allocator);
    defer registry.deinit();

    try registry.register("session-123");
    
    // Queue some messages
    registry.queue_message("session-123", "Hello");
    registry.queue_message("session-123", "World");
    
    // Get messages (this clears the queue)
    const messages_opt = registry.get_queue_messages("session-123");
    try std.testing.expect(messages_opt != null);
    
    var messages = messages_opt.?;
    try std.testing.expectEqual(@as(usize, 2), messages.items.len);
    
    // Cleanup
    for (messages.items) |msg| allocator.free(msg);
    messages.deinit(allocator);
}

test "session_queue_get: ActivityRegistry.get_queue_messages returns null when empty" {
    const allocator = std.testing.allocator;
    var registry = activity_registry.ActivityRegistry.init(allocator);
    defer registry.deinit();

    try registry.register("session-123");
    
    // Get from empty queue
    const messages = registry.get_queue_messages("session-123");
    try std.testing.expect(messages == null);
}

test "session_queue_get: ActivityRegistry.get_queue_messages clears the queue" {
    const allocator = std.testing.allocator;
    var registry = activity_registry.ActivityRegistry.init(allocator);
    defer registry.deinit();

    try registry.register("session-123");
    
    registry.queue_message("session-123", "Message1");
    
    // First get - should have message
    const first = registry.get_queue_messages("session-123");
    try std.testing.expect(first != null);
    var first_messages = first.?;
    try std.testing.expectEqual(@as(usize, 1), first_messages.items.len);
    for (first_messages.items) |msg| allocator.free(msg);
    first_messages.deinit(allocator);
    
    // Second get - should be null (queue cleared)
    const second = registry.get_queue_messages("session-123");
    try std.testing.expect(second == null);
}

test "session_queue_get: ActivityRegistry.get_queue_messages on unregistered session returns null" {
    const allocator = std.testing.allocator;
    var registry = activity_registry.ActivityRegistry.init(allocator);
    defer registry.deinit();

    // Don't register session
    
    const messages = registry.get_queue_messages("nonexistent-session");
    try std.testing.expect(messages == null);
}
