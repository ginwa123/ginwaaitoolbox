const std = @import("std");

test "build_messages_for_agent_prompt module imports" {
    // Test that the module can be imported without errors
    const build = @import("build_messages_for_agent_prompt.zig");
    _ = build;
    try std.testing.expect(true);
}
