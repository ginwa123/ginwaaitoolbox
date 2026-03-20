const std = @import("std");

test "handle_spawn_sub_agent module imports" {
    // Test that the module can be imported without errors
    const handle_spawn = @import("handle_spawn_sub_agent.zig");
    _ = handle_spawn;
    try std.testing.expect(true);
}
