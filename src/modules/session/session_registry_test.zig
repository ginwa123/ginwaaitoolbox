const std = @import("std");
const session_registry = @import("session_registry.zig");

// ========== Cancellation Tests (from cancellation_registry_test.zig) ==========

test "SessionRegistry can register and check cancellation" {
    const allocator = std.testing.allocator;
    var registry = session_registry.SessionRegistry.init(allocator);
    defer registry.deinit();

    const session_id = "session-123";
    try registry.register(session_id);
    
    // Initially not cancelled
    try std.testing.expect(!registry.is_cancelled(session_id));
    
    // Cancel the session
    registry.cancel(session_id);
    try std.testing.expect(registry.is_cancelled(session_id));
}

test "SessionRegistry supports multiple sessions independently" {
    const allocator = std.testing.allocator;
    var registry = session_registry.SessionRegistry.init(allocator);
    defer registry.deinit();

    const session_a = "session-a";
    const session_b = "session-b";
    
    try registry.register(session_a);
    try registry.register(session_b);
    
    // Cancel only session A
    registry.cancel(session_a);
    
    // Session A should be cancelled
    try std.testing.expect(registry.is_cancelled(session_a));
    // Session B should NOT be cancelled
    try std.testing.expect(!registry.is_cancelled(session_b));
}

test "SessionRegistry can reset session" {
    const allocator = std.testing.allocator;
    var registry = session_registry.SessionRegistry.init(allocator);
    defer registry.deinit();

    const session_id = "session-123";
    try registry.register(session_id);
    
    registry.cancel(session_id);
    try std.testing.expect(registry.is_cancelled(session_id));
    
    registry.reset(session_id);
    try std.testing.expect(!registry.is_cancelled(session_id));
}

test "SessionRegistry can unregister session" {
    const allocator = std.testing.allocator;
    var registry = session_registry.SessionRegistry.init(allocator);
    defer registry.deinit();

    const session_id = "session-123";
    try registry.register(session_id);
    try std.testing.expect(registry.is_registered(session_id));
    
    registry.unregister(session_id);
    try std.testing.expect(!registry.is_registered(session_id));
}

test "SessionRegistry has_sessions returns false when empty" {
    const allocator = std.testing.allocator;
    var registry = session_registry.SessionRegistry.init(allocator);
    defer registry.deinit();
    try std.testing.expect(!registry.has_sessions());
}

test "SessionRegistry has_sessions returns true when session registered" {
    const allocator = std.testing.allocator;
    var registry = session_registry.SessionRegistry.init(allocator);
    defer registry.deinit();
    try registry.register("session-1");
    try std.testing.expect(registry.has_sessions());
}

test "SessionRegistry session_count returns correct count" {
    const allocator = std.testing.allocator;
    var registry = session_registry.SessionRegistry.init(allocator);
    defer registry.deinit();
    try std.testing.expectEqual(@as(usize, 0), registry.session_count());
    try registry.register("session-1");
    try std.testing.expectEqual(@as(usize, 1), registry.session_count());
    try registry.register("session-2");
    try std.testing.expectEqual(@as(usize, 2), registry.session_count());
    registry.unregister("session-1");
    try std.testing.expectEqual(@as(usize, 1), registry.session_count());
}

// ========== Activity Tests (from activity_registry_test.zig) ==========

test "SessionRegistry struct exists" {
    const allocator = std.testing.allocator;
    var registry = session_registry.SessionRegistry.init(allocator);
    defer registry.deinit();
    try std.testing.expect(true);
}

test "SessionRegistry can register a session" {
    const allocator = std.testing.allocator;
    var registry = session_registry.SessionRegistry.init(allocator);
    defer registry.deinit();

    const session_id = "session-123";
    try registry.register(session_id);
    try std.testing.expect(registry.is_registered(session_id));
}

test "SessionRegistry mark_running sets is_running true" {
    const allocator = std.testing.allocator;
    var registry = session_registry.SessionRegistry.init(allocator);
    defer registry.deinit();

    const session_id = "session-123";
    try registry.register(session_id);
    registry.mark_running(session_id);
    try std.testing.expect(registry.is_running(session_id));
}

test "SessionRegistry mark_idle sets is_running false" {
    const allocator = std.testing.allocator;
    var registry = session_registry.SessionRegistry.init(allocator);
    defer registry.deinit();

    const session_id = "session-123";
    try registry.register(session_id);
    registry.mark_running(session_id);
    registry.mark_idle(session_id);
    try std.testing.expect(!registry.is_running(session_id));
}

test "SessionRegistry supports nested running markers" {
    const allocator = std.testing.allocator;
    var registry = session_registry.SessionRegistry.init(allocator);
    defer registry.deinit();

    const session_id = "session-123";
    try registry.register(session_id);

    registry.mark_running(session_id);
    registry.mark_running(session_id);
    try std.testing.expect(registry.is_running(session_id));

    registry.mark_idle(session_id);
    try std.testing.expect(registry.is_running(session_id));

    registry.mark_idle(session_id);
    try std.testing.expect(!registry.is_running(session_id));
}

test "SessionRegistry can unregister a session" {
    const allocator = std.testing.allocator;
    var registry = session_registry.SessionRegistry.init(allocator);
    defer registry.deinit();

    const session_id = "session-123";
    try registry.register(session_id);
    try std.testing.expect(registry.is_registered(session_id));

    registry.unregister(session_id);
    try std.testing.expect(!registry.is_registered(session_id));
}

test "SessionRegistry tracks multiple sessions independently" {
    const allocator = std.testing.allocator;
    var registry = session_registry.SessionRegistry.init(allocator);
    defer registry.deinit();

    const session_a = "session-a";
    const session_b = "session-b";
    try registry.register(session_a);
    try registry.register(session_b);

    registry.mark_running(session_a);
    try std.testing.expect(registry.is_running(session_a));
    try std.testing.expect(!registry.is_running(session_b));
}

test "SessionRegistry has global singleton" {
    const allocator = std.testing.allocator;
    session_registry.init_global_registry(allocator);
    defer session_registry.deinit_global_registry();

    const registry = session_registry.get_global_registry();
    try std.testing.expect(registry != null);
}

test "SessionRegistry mark_stopped sets is_running false immediately" {
    const allocator = std.testing.allocator;
    var registry = session_registry.SessionRegistry.init(allocator);
    defer registry.deinit();

    const session_id = "session-123";
    try registry.register(session_id);
    registry.mark_running(session_id);
    try std.testing.expect(registry.is_running(session_id));

    registry.mark_stopped(session_id);
    try std.testing.expect(!registry.is_running(session_id));
}

test "SessionRegistry is_stopped returns true after mark_stopped" {
    const allocator = std.testing.allocator;
    var registry = session_registry.SessionRegistry.init(allocator);
    defer registry.deinit();

    const session_id = "session-123";
    try registry.register(session_id);

    try std.testing.expect(!registry.is_stopped(session_id));
    registry.mark_stopped(session_id);
    try std.testing.expect(registry.is_stopped(session_id));
}

test "SessionRegistry is_running returns false when stopped even with activity count > 0" {
    const allocator = std.testing.allocator;
    var registry = session_registry.SessionRegistry.init(allocator);
    defer registry.deinit();

    const session_id = "session-123";
    try registry.register(session_id);
    registry.mark_running(session_id);
    try std.testing.expect(registry.is_running(session_id));

    registry.mark_stopped(session_id);
    try std.testing.expect(!registry.is_running(session_id));
    // Activity count is reset to 0 by mark_stopped
}

test "SessionRegistry stopped flag persists across mark_running calls" {
    const allocator = std.testing.allocator;
    var registry = session_registry.SessionRegistry.init(allocator);
    defer registry.deinit();

    const session_id = "session-123";
    try registry.register(session_id);
    registry.mark_stopped(session_id);
    try std.testing.expect(registry.is_stopped(session_id));

    // Even if we mark running (reset clears stopped), now stopped persists
    registry.mark_running(session_id);
    try std.testing.expect(!registry.is_running(session_id));
}

test "SessionRegistry register clears stopped flag" {
    const allocator = std.testing.allocator;
    var registry = session_registry.SessionRegistry.init(allocator);
    defer registry.deinit();

    const session_id = "session-123";
    try registry.register(session_id);
    registry.mark_stopped(session_id);
    try std.testing.expect(registry.is_stopped(session_id));

    // Re-register clears stopped flag
    try registry.register(session_id);
    try std.testing.expect(!registry.is_stopped(session_id));
}

test "SessionRegistry queue_message adds message to queue" {
    const allocator = std.testing.allocator;
    var registry = session_registry.SessionRegistry.init(allocator);
    defer registry.deinit();

    const session_id = "session-123";
    try registry.register(session_id);

    registry.queue_message(session_id, "hello");
    try std.testing.expect(registry.is_have_queue_message(session_id));
}

test "SessionRegistry can queue multiple messages" {
    const allocator = std.testing.allocator;
    var registry = session_registry.SessionRegistry.init(allocator);
    defer registry.deinit();

    const session_id = "session-123";
    try registry.register(session_id);

    registry.queue_message(session_id, "msg1");
    registry.queue_message(session_id, "msg2");
    try std.testing.expect(registry.is_have_queue_message(session_id));
}

test "SessionRegistry get_queue_messages returns ArrayList of strings" {
    const allocator = std.testing.allocator;
    var registry = session_registry.SessionRegistry.init(allocator);
    defer registry.deinit();

    const session_id = "session-123";
    try registry.register(session_id);

    registry.queue_message(session_id, "hello");
    registry.queue_message(session_id, "world");

    const messages = registry.get_queue_messages(session_id);
    try std.testing.expect(messages != null);
    defer messages.?.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 2), messages.?.items.len);
    try std.testing.expectEqualStrings("hello", messages.?.items[0]);
    try std.testing.expectEqualStrings("world", messages.?.items[1]);
}

test "SessionRegistry get_queue_messages returns null when empty" {
    const allocator = std.testing.allocator;
    var registry = session_registry.SessionRegistry.init(allocator);
    defer registry.deinit();

    const session_id = "session-123";
    try registry.register(session_id);

    const messages = registry.get_queue_messages(session_id);
    try std.testing.expect(messages == null);
}

test "SessionRegistry queue_message on unregistered session does nothing" {
    const allocator = std.testing.allocator;
    var registry = session_registry.SessionRegistry.init(allocator);
    defer registry.deinit();

    registry.queue_message("unregistered-session", "hello");
    try std.testing.expect(!registry.is_have_queue_message("unregistered-session"));
}

test "SessionRegistry delete_queue_messages removes specific message" {
    const allocator = std.testing.allocator;
    var registry = session_registry.SessionRegistry.init(allocator);
    defer registry.deinit();

    const session_id = "session-123";
    try registry.register(session_id);

    registry.queue_message(session_id, "to-delete");
    registry.queue_message(session_id, "to-keep");
    registry.delete_queue_messages(session_id, "to-delete");

    const messages = registry.get_queue_messages(session_id);
    try std.testing.expect(messages != null);
    defer messages.?.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), messages.?.items.len);
    try std.testing.expectEqualStrings("to-keep", messages.?.items[0]);
}

test "SessionRegistry delete_queue_messages does nothing if message not found" {
    const allocator = std.testing.allocator;
    var registry = session_registry.SessionRegistry.init(allocator);
    defer registry.deinit();

    const session_id = "session-123";
    try registry.register(session_id);

    registry.queue_message(session_id, "hello");
    registry.delete_queue_messages(session_id, "not-found");

    const messages = registry.get_queue_messages(session_id);
    try std.testing.expect(messages != null);
    defer messages.?.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), messages.?.items.len);
}

test "SessionRegistry delete_queue_messages on unregistered session does nothing" {
    const allocator = std.testing.allocator;
    var registry = session_registry.SessionRegistry.init(allocator);
    defer registry.deinit();

    // Should not crash
    registry.delete_queue_messages("unregistered-session", "hello");
}

test "SessionRegistry delete_queue_messages reduces count by 1" {
    const allocator = std.testing.allocator;
    var registry = session_registry.SessionRegistry.init(allocator);
    defer registry.deinit();

    const session_id = "session-123";
    try registry.register(session_id);

    registry.queue_message(session_id, "first");
    registry.queue_message(session_id, "second");
    registry.queue_message(session_id, "third");

    const before = registry.get_queue_messages(session_id);
    try std.testing.expectEqual(@as(usize, 3), before.?.items.len);
    before.?.deinit(allocator);

    registry.delete_queue_messages(session_id, "second");

    const after = registry.get_queue_messages(session_id);
    try std.testing.expectEqual(@as(usize, 2), after.?.items.len);
    after.?.deinit(allocator);
}
