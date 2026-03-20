const std = @import("std");

test "agent module imports" {
    // Test that the agent module can be imported
    // Note: Full agent tests require nalarcore module context
    const agent = @import("agent.zig");
    _ = agent;
    try std.testing.expect(true);
}
