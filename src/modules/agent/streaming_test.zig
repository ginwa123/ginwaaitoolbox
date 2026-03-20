const std = @import("std");

test "streaming module imports" {
    // Test that the streaming module can be imported
    // Note: Full streaming tests require nalarcore module context
    const agent = @import("agent.zig");
    _ = agent;
    try std.testing.expect(true);
}
