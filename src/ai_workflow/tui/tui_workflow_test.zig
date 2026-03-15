const std = @import("std");
const cancellation_registry = @import("../../modules/session/cancellation_registry.zig");
const tui_workflow = @import("tui_workflow.zig");
const StreamingContext = tui_workflow.StreamingContext;

test "multiple sessions can be cancelled independently" {
    const allocator = std.testing.allocator;
    std.log.info("test multiple sessions can be cancelled independently", .{});

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

test "StreamingContext can be created" {
    const allocator = std.testing.allocator;

    // Create a StreamingContext
    const stream_ctx = StreamingContext{
        .allocator = allocator,
        .chunk_index = 0,
        .session_id = "test-session-123",
    };

    // Verify fields are set correctly
    try std.testing.expectEqual(allocator, stream_ctx.allocator);
    try std.testing.expectEqual(@as(usize, 0), stream_ctx.chunk_index);
    try std.testing.expectEqualStrings("test-session-123", stream_ctx.session_id);
}
