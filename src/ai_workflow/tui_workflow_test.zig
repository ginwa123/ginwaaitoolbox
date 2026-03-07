const std = @import("std");
const cancellation_registry = @import("cancellation_registry.zig");
const tui_workflow = @import("tui_workflow.zig");
const StreamingContext = tui_workflow.StreamingContext;
const isCancelledWithContext = tui_workflow.isCancelledWithContext;

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

test "isCancelledWithContext correctly interprets StreamingContext" {
    const allocator = std.testing.allocator;

    // Initialize registry
    cancellation_registry.initGlobalRegistry(allocator);
    defer cancellation_registry.deinitGlobalRegistry();

    const registry = cancellation_registry.getGlobalRegistry().?;

    // Register a session
    try registry.register("test-session-123");
    defer registry.reset("test-session-123");

    // Create a StreamingContext with the session_id
    var dummy_workflow: tui_workflow.TUIWorkflow = undefined;
    var stream_ctx = StreamingContext{
        .allocator = allocator,
        .workflow = &dummy_workflow,
        .conn_fd = -1,
        .chunk_index = 0,
        .session_id = "test-session-123",
    };

    // Test: Not cancelled initially
    try std.testing.expect(!isCancelledWithContext(&stream_ctx));

    // Cancel the session
    registry.cancel("test-session-123");

    // Test: Now cancelled
    try std.testing.expect(isCancelledWithContext(&stream_ctx));
}

test "isCancelledWithContext returns false for null context" {
    try std.testing.expect(!isCancelledWithContext(null));
}

test "isCancelledWithContext returns false when no global registry" {
    // Don't initialize registry - should return false
    const allocator = std.testing.allocator;
    var dummy_workflow: tui_workflow.TUIWorkflow = undefined;
    var stream_ctx = StreamingContext{
        .allocator = allocator,
        .workflow = &dummy_workflow,
        .conn_fd = -1,
        .chunk_index = 0,
        .session_id = "no-registry-session",
    };

    try std.testing.expect(!isCancelledWithContext(&stream_ctx));
}

test "isCancelledWithContext isolates different sessions" {
    const allocator = std.testing.allocator;

    // Initialize registry
    cancellation_registry.initGlobalRegistry(allocator);
    defer cancellation_registry.deinitGlobalRegistry();

    const registry = cancellation_registry.getGlobalRegistry().?;

    // Register two sessions
    try registry.register("session-a");
    try registry.register("session-b");
    defer {
        registry.reset("session-a");
        registry.reset("session-b");
    }

    // Create StreamingContext for each session
    var dummy_workflow: tui_workflow.TUIWorkflow = undefined;
    var ctx_a = StreamingContext{
        .allocator = allocator,
        .workflow = &dummy_workflow,
        .conn_fd = -1,
        .chunk_index = 0,
        .session_id = "session-a",
    };
    var ctx_b = StreamingContext{
        .allocator = allocator,
        .workflow = &dummy_workflow,
        .conn_fd = -1,
        .chunk_index = 0,
        .session_id = "session-b",
    };

    // Neither should be cancelled initially
    try std.testing.expect(!isCancelledWithContext(&ctx_a));
    try std.testing.expect(!isCancelledWithContext(&ctx_b));

    // Cancel only session-a
    registry.cancel("session-a");

    // Only session-a should show as cancelled
    try std.testing.expect(isCancelledWithContext(&ctx_a));
    try std.testing.expect(!isCancelledWithContext(&ctx_b));
}
