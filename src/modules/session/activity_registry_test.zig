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
