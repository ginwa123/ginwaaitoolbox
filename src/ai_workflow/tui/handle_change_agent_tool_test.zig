const std = @import("std");
const handle_change = @import("handle_change_agent_tool.zig");

test "handle_change_agent_tool module exists" {
    // This module has complex dependencies, so we just verify it compiles
    _ = handle_change;
}
