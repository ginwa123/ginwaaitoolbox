const std = @import("std");
const handle_tool = @import("handle_tool.zig");

test "handle_tool has change_agent dispatch" {
    // Verify change_agent is a known tool via public API
    const result = handle_tool.isKnownTool("change_agent");
    try std.testing.expect(result == true);
}

test "handle_tool does not have get_agent dispatch" {
    // Verify get_agent was removed
    const result = handle_tool.isKnownTool("get_agent");
    try std.testing.expect(result == false);
}
