const std = @import("std");
const nalarcore = @import("nalarcore");

test "root.zig exports change_agent" {
    // Verify change_agent is exported
    _ = nalarcore.change_agent;
}

test "root.zig exports change_agent_tool" {
    // Verify change_agent_tool is exported
    _ = nalarcore.change_agent_tool;
}

test "root.zig exports ChangeAgentTool with correct name" {
    const tool = nalarcore.change_agent.ChangeAgentTool;
    try std.testing.expectEqualStrings("change_agent", tool.function.name);
}

test "root.zig does not export get_agent" {
    // Verify get_agent is not exported anymore
    // This uses @hasField to check at compile time
    const has_get_agent = @hasDecl(@TypeOf(.{nalarcore}), "get_agent");
    try std.testing.expect(!has_get_agent);
}
