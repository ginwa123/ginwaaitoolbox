const std = @import("std");
const nalarcore = @import("nalarcore");

test "root.zig exports change_agent" {
    // Verify change_agent is exported
    _ = nalarcore.change_agent;
}

test "root.zig does not export get_agent" {
    // Verify get_agent is not exported anymore
    // This uses @hasField to check at compile time
    const has_get_agent = @hasDecl(@TypeOf(.{nalarcore}), "get_agent");
    try std.testing.expect(!has_get_agent);
}
