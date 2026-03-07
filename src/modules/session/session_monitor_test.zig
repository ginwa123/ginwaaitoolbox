const std = @import("std");
const session_monitor = @import("session_monitor.zig");
const cancellation_registry = @import("cancellation_registry.zig");

// Note: Full integration tests would require spawning a subprocess
// These are basic compilation and structure tests

test "SessionMonitor structure compiles" {
    // Just verify the type exists and has expected methods
    const Monitor = session_monitor.SessionMonitor;
    _ = Monitor.CHECK_INTERVAL_MS;
}
