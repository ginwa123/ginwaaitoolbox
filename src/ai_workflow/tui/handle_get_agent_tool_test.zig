const std = @import("std");

test "handle_get_agent_tool module imports" {
    // Test that the module can be imported without errors
    const handle_get_agent_tool = @import("handle_get_agent_tool.zig");
    _ = handle_get_agent_tool;
    try std.testing.expect(true);
}
