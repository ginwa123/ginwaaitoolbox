const std = @import("std");
const activity_registry = @import("activity_registry.zig");

test "ActivityRegistry struct exists" {
    const allocator = std.testing.allocator;
    var registry = activity_registry.ActivityRegistry.init(allocator);
    defer registry.deinit();
}

test "ActivityRegistry can register a session" {
    const allocator = std.testing.allocator;
    var registry = activity_registry.ActivityRegistry.init(allocator);
    defer registry.deinit();

    try registry.register("session-123");
    try std.testing.expect(registry.is_registered("session-123"));
}

test "ActivityRegistry mark_running sets is_running true" {
    const allocator = std.testing.allocator;
    var registry = activity_registry.ActivityRegistry.init(allocator);
    defer registry.deinit();

    try registry.register("session-123");
    
    // Initially not running
    try std.testing.expect(!registry.is_running("session-123"));
    
    // Mark as running
    registry.mark_running("session-123");
    try std.testing.expect(registry.is_running("session-123"));
}

test "ActivityRegistry mark_idle sets is_running false" {
    const allocator = std.testing.allocator;
    var registry = activity_registry.ActivityRegistry.init(allocator);
    defer registry.deinit();

    try registry.register("session-123");
    registry.mark_running("session-123");
    try std.testing.expect(registry.is_running("session-123"));
    
    registry.mark_idle("session-123");
    try std.testing.expect(!registry.is_running("session-123"));
}

test "ActivityRegistry supports nested running markers" {
    const allocator = std.testing.allocator;
    var registry = activity_registry.ActivityRegistry.init(allocator);
    defer registry.deinit();

    try registry.register("session-nested");
    
    registry.mark_running("session-nested");
    registry.mark_running("session-nested");
    try std.testing.expect(registry.is_running("session-nested"));
    
    registry.mark_idle("session-nested");
    try std.testing.expect(registry.is_running("session-nested")); // Still > 0
    
    registry.mark_idle("session-nested");
    try std.testing.expect(!registry.is_running("session-nested")); // Now 0
}

test "ActivityRegistry can unregister a session" {
    const allocator = std.testing.allocator;
    var registry = activity_registry.ActivityRegistry.init(allocator);
    defer registry.deinit();

    try registry.register("session-123");
    try std.testing.expect(registry.is_registered("session-123"));
    
    registry.unregister("session-123");
    try std.testing.expect(!registry.is_registered("session-123"));
}

test "ActivityRegistry tracks multiple sessions independently" {
    const allocator = std.testing.allocator;
    var registry = activity_registry.ActivityRegistry.init(allocator);
    defer registry.deinit();

    try registry.register("session-a");
    try registry.register("session-b");
    
    registry.mark_running("session-a");
    
    try std.testing.expect(registry.is_running("session-a"));
    try std.testing.expect(!registry.is_running("session-b"));
}

test "ActivityRegistry has global singleton" {
    // Clean up any existing global
    activity_registry.deinitGlobalRegistry();
    
    // Initialize
    const allocator = std.testing.allocator;
    activity_registry.initGlobalRegistry(allocator);
    
    // Get and use
    if (activity_registry.get_global_registry()) |registry| {
        try registry.register("global-session");
        try std.testing.expect(registry.is_registered("global-session"));
    } else {
        try std.testing.expect(false); // Should never happen
    }
    
    // Clean up
    activity_registry.deinitGlobalRegistry();
}

test "ActivityRegistry mark_stopped sets is_running false immediately" {
    const allocator = std.testing.allocator;
    var registry = activity_registry.ActivityRegistry.init(allocator);
    defer registry.deinit();

    try registry.register("session-123");
    
    // Mark as running multiple times (nested)
    registry.mark_running("session-123");
    registry.mark_running("session-123");
    registry.mark_running("session-123");
    try std.testing.expect(registry.is_running("session-123")); // Count = 3
    
    // mark_stopped should reset count to 0 immediately (not decrement)
    registry.mark_stopped("session-123");
    try std.testing.expect(!registry.is_running("session-123")); // Count = 0
}

// ============ Message Queue Tests ============

test "ActivityRegistry queue_message adds message to queue" {
    const allocator = std.testing.allocator;
    var registry = activity_registry.ActivityRegistry.init(allocator);
    defer registry.deinit();

    try registry.register("session-123");
    
    // Initially no queued messages
    try std.testing.expect(!registry.is_have_queue_message("session-123"));
    
    // Queue a message
    registry.queue_message("session-123", "Hello world");
    
    // Now should have queued messages
    try std.testing.expect(registry.is_have_queue_message("session-123"));
}

test "ActivityRegistry can queue multiple messages" {
    const allocator = std.testing.allocator;
    var registry = activity_registry.ActivityRegistry.init(allocator);
    defer registry.deinit();

    try registry.register("session-123");
    
    registry.queue_message("session-123", "Message 1");
    registry.queue_message("session-123", "Message 2");
    registry.queue_message("session-123", "Message 3");
    
    try std.testing.expect(registry.is_have_queue_message("session-123"));
}

test "ActivityRegistry get_queue_messages returns ArrayList of strings" {
    const allocator = std.testing.allocator;
    var registry = activity_registry.ActivityRegistry.init(allocator);
    defer registry.deinit();

    try registry.register("session-123");
    
    registry.queue_message("session-123", "Hello");
    registry.queue_message("session-123", "World");
    
    // Get and clear messages
    const messages_opt = registry.get_queue_messages("session-123");
    try std.testing.expect(messages_opt != null);
    
    var messages = messages_opt.?;
    
    // After getting, queue should be empty
    try std.testing.expect(!registry.is_have_queue_message("session-123"));
    
    // Should return list of 2 messages
    try std.testing.expectEqual(@as(usize, 2), messages.items.len);
    
    // Verify order is preserved
    try std.testing.expectEqualStrings("Hello", messages.items[0]);
    try std.testing.expectEqualStrings("World", messages.items[1]);
    
    // Clean up - free individual items then the list
    for (messages.items) |msg| {
        allocator.free(msg);
    }
    messages.deinit(allocator);
}

test "ActivityRegistry get_queue_messages returns null when empty" {
    const allocator = std.testing.allocator;
    var registry = activity_registry.ActivityRegistry.init(allocator);
    defer registry.deinit();

    try registry.register("session-123");
    
    const messages = registry.get_queue_messages("session-123");
    try std.testing.expect(messages == null);
}

test "ActivityRegistry queue_message on unregistered session does nothing" {
    const allocator = std.testing.allocator;
    var registry = activity_registry.ActivityRegistry.init(allocator);
    defer registry.deinit();

    // Don't register session-123
    
    // Queue should not crash, just do nothing
    registry.queue_message("session-123", "Hello");
    
    // get_queue_messages should return null
    const messages = registry.get_queue_messages("session-123");
    try std.testing.expect(messages == null);
}

test "ActivityRegistry delete_queue_messages removes specific message" {
    const allocator = std.testing.allocator;
    var registry = activity_registry.ActivityRegistry.init(allocator);
    defer registry.deinit();

    try registry.register("session-123");
    
    registry.queue_message("session-123", "Hello");
    registry.queue_message("session-123", "World");
    registry.queue_message("session-123", "Foo");
    
    // Delete "World"
    registry.delete_queue_messages("session-123", "World");
    
    // Get remaining messages
    const messages_opt = registry.get_queue_messages("session-123");
    try std.testing.expect(messages_opt != null);
    
    var messages = messages_opt.?;
    defer {
        for (messages.items) |msg| allocator.free(msg);
        messages.deinit(allocator);
    }
    
    // Should have 2 messages left
    try std.testing.expectEqual(@as(usize, 2), messages.items.len);
    
    // Verify "World" is gone (order may change due to swapRemove)
    try std.testing.expect(messages.items[0].len > 0); // at least something
    try std.testing.expect(!std.mem.containsAtLeast(u8, messages.items[0], 1, "World"));
}

test "ActivityRegistry delete_queue_messages does nothing if message not found" {
    const allocator = std.testing.allocator;
    var registry = activity_registry.ActivityRegistry.init(allocator);
    defer registry.deinit();

    try registry.register("session-123");
    
    registry.queue_message("session-123", "Hello");
    registry.queue_message("session-123", "World");
    
    // Try to delete non-existent message
    registry.delete_queue_messages("session-123", "NonExistent");
    
    // Get messages
    const messages_opt = registry.get_queue_messages("session-123");
    try std.testing.expect(messages_opt != null);
    
    var messages = messages_opt.?;
    defer {
        for (messages.items) |msg| allocator.free(msg);
        messages.deinit(allocator);
    }
    
    // Should still have 2 messages
    try std.testing.expectEqual(@as(usize, 2), messages.items.len);
}

test "ActivityRegistry delete_queue_messages on unregistered session does nothing" {
    const allocator = std.testing.allocator;
    var registry = activity_registry.ActivityRegistry.init(allocator);
    defer registry.deinit();

    // Don't register session-123
    
    // Should not crash
    registry.delete_queue_messages("session-123", "Hello");
}

test "ActivityRegistry delete_queue_messages reduces count by 1" {
    const allocator = std.testing.allocator;
    var registry = activity_registry.ActivityRegistry.init(allocator);
    defer registry.deinit();

    try registry.register("session-123");
    
    registry.queue_message("session-123", "Hello");
    registry.queue_message("session-123", "World");
    registry.queue_message("session-123", "Foo");
    registry.queue_message("session-123", "Bar");
    
    // Delete one message
    registry.delete_queue_messages("session-123", "World");
    
    const messages_opt = registry.get_queue_messages("session-123");
    try std.testing.expect(messages_opt != null);
    
    var messages = messages_opt.?;
    defer {
        for (messages.items) |msg| allocator.free(msg);
        messages.deinit(allocator);
    }
    
    // Should have 3 messages left
    try std.testing.expectEqual(@as(usize, 3), messages.items.len);
}
