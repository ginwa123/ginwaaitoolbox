const std = @import("std");
const http_server = @import("nalarcore").http_server;
const activity_registry = @import("nalarcore").session.activity_registry;

// Test module for session_queue_delete handler
// TDD: Tests come first - these validate the handler exists and works correctly

// Import the handler - this will fail to compile until we create the handler
const session_queue_delete = @import("session_queue_delete.zig");

test "session_queue_delete: ActivityRegistry.delete_queue_messages removes first matching message" {
    const allocator = std.testing.allocator;
    var registry = activity_registry.ActivityRegistry.init(allocator);
    defer registry.deinit();

    try registry.register("session-123");
    
    // Queue multiple messages
    registry.queue_message("session-123", "First");
    registry.queue_message("session-123", "DeleteMe");
    registry.queue_message("session-123", "Third");
    
    // Delete specific message
    registry.delete_queue_messages("session-123", "DeleteMe");
    
    // Verify deletion
    const messages_opt = registry.get_queue_messages("session-123");
    try std.testing.expect(messages_opt != null);
    
    var messages = messages_opt.?;
    defer {
        for (messages.items) |msg| allocator.free(msg);
        messages.deinit(allocator);
    }
    
    // Should have 2 messages left
    try std.testing.expectEqual(@as(usize, 2), messages.items.len);
}

test "session_queue_delete: handler should handle missing session gracefully" {
    const allocator = std.testing.allocator;
    var registry = activity_registry.ActivityRegistry.init(allocator);
    defer registry.deinit();

    // Don't register any session
    
    // Delete should not crash on unregistered session
    registry.delete_queue_messages("nonexistent-session", "AnyMessage");
    
    // No exception means success (matching handler behavior)
    try std.testing.expect(true);
}

test "session_queue_delete: handler should handle non-existent message gracefully" {
    const allocator = std.testing.allocator;
    var registry = activity_registry.ActivityRegistry.init(allocator);
    defer registry.deinit();

    try registry.register("session-123");
    registry.queue_message("session-123", "Hello");
    
    // Delete non-existent message should not crash
    registry.delete_queue_messages("session-123", "NonExistent");
    
    // Original message should still be there
    const messages_opt = registry.get_queue_messages("session-123");
    try std.testing.expect(messages_opt != null);
    
    var messages = messages_opt.?;
    try std.testing.expectEqual(@as(usize, 1), messages.items.len);
    
    for (messages.items) |msg| allocator.free(msg);
    messages.deinit(allocator);
}

test "session_queue_delete: only first occurrence is deleted (no duplicates)" {
    const allocator = std.testing.allocator;
    var registry = activity_registry.ActivityRegistry.init(allocator);
    defer registry.deinit();

    try registry.register("session-123");
    
    // Queue with duplicate messages
    registry.queue_message("session-123", "Dup");
    registry.queue_message("session-123", "Unique");
    registry.queue_message("session-123", "Dup");
    
    // Delete one occurrence
    registry.delete_queue_messages("session-123", "Dup");
    
    const messages_opt = registry.get_queue_messages("session-123");
    try std.testing.expect(messages_opt != null);
    
    var messages = messages_opt.?;
    defer {
        for (messages.items) |msg| allocator.free(msg);
        messages.deinit(allocator);
    }
    
    // Should have 2 messages (one Dup remains)
    try std.testing.expectEqual(@as(usize, 2), messages.items.len);
}

// TDD: Handler must exist with correct signature
test "session_queue_delete: handler function exists" {
    // If this compiles, the handler exists with correct signature
    // The function pointer type is: fn(*HttpServer.ServerHandler, *Request, *Response) anyerror!void
    const HandlerType = @TypeOf(session_queue_delete.sessionQueueDeleteHandler);
    
    // Just verify the type is not void/noreturn (which would mean it doesn't exist)
    try std.testing.expect(HandlerType != noreturn);
    try std.testing.expect(HandlerType != void);
}
