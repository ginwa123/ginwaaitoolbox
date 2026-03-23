const std = @import("std");
const tree1_mod = @import("nalarcore");
const agent = tree1_mod.agent;
const get_agent_tool = tree1_mod.get_agent;

/// Stateless get_agent tool handler - only handles core logic:
/// 1. Parse arguments from tool_call.function.arguments
/// 2. Execute get_agent
/// Returns the result as string or error.
/// 
/// Note: Saving agent to DB is a side effect that must be handled by caller.
pub fn handle_get_agent_tool_run(
    allocator: std.mem.Allocator,
    tool_call: agent.ToolCall,
) ![]const u8 {
    // Parse arguments JSON to GetAgentInput
    const parsed = std.json.parseFromSlice(
        get_agent_tool.GetAgentInput,
        allocator,
        tool_call.function.arguments,
        .{ .allocate = .alloc_always },
    ) catch {
        return try std.fmt.allocPrint(allocator,
            \\<agent>
            \\  <agent_name></agent_name>
            \\  <content></content>
            \\  <loaded>false</loaded>
            \\  <error>Failed to parse get_agent arguments</error>
            \\</agent>
        , .{});
    };
    defer parsed.deinit();

    const result = get_agent_tool.executeGetAgentToString(allocator, parsed.value) catch {
        return try std.fmt.allocPrint(allocator,
            \\<agent>
            \\  <agent_name></agent_name>
            \\  <content></content>
            \\  <loaded>false</loaded>
            \\  <error>Failed to get agent</error>
            \\</agent>
        , .{});
    };
    
    return result;
}
