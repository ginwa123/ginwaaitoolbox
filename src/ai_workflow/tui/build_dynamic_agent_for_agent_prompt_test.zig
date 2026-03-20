const std = @import("std");

test "build_dynamic_agent_for_agent_prompt module imports" {
    // Test that the module can be imported without errors
    const build_agent = @import("build_dynamic_agent_for_agent_prompt.zig");
    _ = build_agent;
    try std.testing.expect(true);
}
