const std = @import("std");
const cancellation_registry = @import("cancellation_registry.zig");

test "multiple sessions can be cancelled independently" {
    const allocator = std.testing.allocator;
    
    // Initialize registry
    cancellation_registry.initGlobalRegistry(allocator);
    defer cancellation_registry.deinitGlobalRegistry();
    
    const registry = cancellation_registry.getGlobalRegistry().?;
    
    // Register multiple sessions
    try registry.register("session-1");
    try registry.register("session-2");
    try registry.register("session-3");
    
    // Cancel session 2 only
    registry.cancel("session-2");
    
    // Verify only session 2 is cancelled
    try std.testing.expect(!registry.isCancelled("session-1"));
    try std.testing.expect(registry.isCancelled("session-2"));
    try std.testing.expect(!registry.isCancelled("session-3"));
    
    // Reset session 2
    registry.reset("session-2");
    try std.testing.expect(!registry.isCancelled("session-2"));
    
    // Cancel all sessions
    registry.cancel("session-1");
    registry.cancel("session-2");
    registry.cancel("session-3");
    
    try std.testing.expect(registry.isCancelled("session-1"));
    try std.testing.expect(registry.isCancelled("session-2"));
    try std.testing.expect(registry.isCancelled("session-3"));
}
