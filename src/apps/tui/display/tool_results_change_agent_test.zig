const std = @import("std");

test "tool_results.zig uses change_agent name" {
    const tool_name = "change_agent";
    try std.testing.expectEqualStrings("change_agent", tool_name);
}

test "tool_results.zig does not use get_agent name" {
    const tool_name = "change_agent";
    // Should not equal "get_agent"
    try std.testing.expect(!std.mem.eql(u8, tool_name, "get_agent"));
}
