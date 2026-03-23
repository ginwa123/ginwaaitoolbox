const std = @import("std");
const tree1_mod = @import("nalarcore");
const agent = tree1_mod.agent;
const list_agents_tool = tree1_mod.list_agents_tool;

/// Stateless list_agents tool handler - only handles core logic:
/// 1. Execute list_agents
/// Returns the result as string or error.
/// 
/// Note: This tool lists all available agents.
pub fn handle_list_agents_tool_run(
    allocator: std.mem.Allocator,
) ![]const u8 {
    const result = list_agents_tool.executeListAgents(allocator) catch {
        return try std.fmt.allocPrint(allocator,
            \\<agents>
            \\  <error>Failed to list agents</error>
            \\</agents>
        , .{});
    };
    
    return result;
}
