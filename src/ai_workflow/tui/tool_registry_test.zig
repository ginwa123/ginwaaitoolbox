const std = @import("std");
const tool_registry = @import("tool_registry.zig");

test "ALL_AGENT_TOOLS contains change_agent" {
    const tool_defs = tool_registry.ALL_AGENT_TOOLS;
    
    var found = false;
    for (tool_defs) |tool| {
        if (std.mem.eql(u8, tool.function.name, "change_agent")) {
            found = true;
            break;
        }
    }
    try std.testing.expect(found);
}

test "ALL_AGENT_TOOLS does not contain get_agent" {
    const tool_defs = tool_registry.ALL_AGENT_TOOLS;
    
    for (tool_defs) |tool| {
        if (std.mem.eql(u8, tool.function.name, "get_agent")) {
            try std.testing.expect(false);
            return;
        }
    }
}
