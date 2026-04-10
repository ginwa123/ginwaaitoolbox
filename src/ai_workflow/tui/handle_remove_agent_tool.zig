const std = @import("std");
const tree1_mod = @import("nalarcore");
const agent = tree1_mod.agent;
const remove_agent_tool = tree1_mod.remove_agent;

/// Stateless remove_agent tool handler - deletes an agent file:
/// 1. Parse arguments from tool_call.function.arguments
/// 2. Execute remove_agent to delete the file
/// Returns the result as string or error.
pub fn handle_remove_agent_tool_run(
    allocator: std.mem.Allocator,
    tool_call: agent.ToolCall,
) ![]const u8 {
    // Parse arguments JSON to RemoveAgentInput
    const parsed = std.json.parseFromSlice(
        remove_agent_tool.RemoveAgentInput,
        allocator,
        tool_call.function.arguments,
        .{ .allocate = .alloc_always },
    ) catch {
        return try std.fmt.allocPrint(allocator,
            \\<name></name>
            \\<removed>false</removed>
            \\<error>Failed to parse remove_agent arguments</error>
        , .{});
    };
    defer parsed.deinit();

    const result = remove_agent_tool.executeRemoveAgentToString(allocator, parsed.value) catch {
        return try std.fmt.allocPrint(allocator,
            \\<name>{s}</name>
            \\<removed>false</removed>
            \\<error>Failed to remove agent</error>
        , .{ parsed.value.name });
    };
    
    return result;
}
