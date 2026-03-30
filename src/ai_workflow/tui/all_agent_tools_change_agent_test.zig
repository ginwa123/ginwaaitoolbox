const std = @import("std");
const all_agent_tools = @import("all_agent_tools.zig");

test "all_agent_tools contains change_agent" {
    const tool_defs = all_agent_tools.all_agent_tools;
    
    var found = false;
    for (tool_defs) |tool| {
        if (std.mem.eql(u8, tool.function.name, "change_agent")) {
            found = true;
            break;
        }
    }
    try std.testing.expect(found);
}

test "all_agent_tools does not contain get_agent" {
    const tool_defs = all_agent_tools.all_agent_tools;
    
    for (tool_defs) |tool| {
        if (std.mem.eql(u8, tool.function.name, "get_agent")) {
            try std.testing.expect(false);
            return;
        }
    }
}
