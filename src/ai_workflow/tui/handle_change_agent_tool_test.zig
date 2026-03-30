const std = @import("std");
const handle_change_agent_tool = @import("handle_change_agent_tool.zig");

test "handle_change_agent_tool module imports and exports exist" {
    // Verify the module loads without error
    // and that the required export exists
    _ = handle_change_agent_tool.handle_change_agent_tool_run;
}
