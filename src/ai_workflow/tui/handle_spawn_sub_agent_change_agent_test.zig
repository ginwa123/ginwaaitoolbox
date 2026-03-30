const std = @import("std");
const handle_spawn_sub_agent = @import("handle_spawn_sub_agent.zig");

test "handle_spawn_sub_agent has change_agent registered" {
    // Check if change_agent is in the tool registry
    for (handle_spawn_sub_agent.SUB_AGENT_TOOL_REGISTRY) |tool| {
        if (std.mem.eql(u8, tool.name, "change_agent")) {
            try std.testing.expect(tool.auto_save_agent == true);
            return;
        }
    }
    try std.testing.expect(false); // Should have found change_agent
}

test "handle_spawn_sub_agent does not have get_agent registered" {
    for (handle_spawn_sub_agent.SUB_AGENT_TOOL_REGISTRY) |tool| {
        if (std.mem.eql(u8, tool.name, "get_agent")) {
            try std.testing.expect(false);
            return;
        }
    }
}
