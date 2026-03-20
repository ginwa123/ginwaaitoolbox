const std = @import("std");

test "build_messages_tools_mcp_for_agent_prompt module imports" {
    // Test that the module can be imported without errors
    const mcp_tools = @import("build_messages_tools_mcp_for_agent_prompt.zig");
    _ = mcp_tools;
    try std.testing.expect(true);
}
