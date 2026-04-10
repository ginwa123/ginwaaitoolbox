const std = @import("std");
const tree1_mod = @import("nalarcore");
const agent = tree1_mod.agent;
const add_agent_tool = tree1_mod.add_agent;

/// Stateless add_agent tool handler - creates a new agent file:
/// 1. Parse arguments from tool_call.function.arguments
/// 2. Execute add_agent to create the file
/// Returns the result as string or error.
pub fn handle_add_agent_tool_run(
    allocator: std.mem.Allocator,
    tool_call: agent.ToolCall,
) ![]const u8 {
    // Parse arguments JSON to AddAgentInput
    const parsed = std.json.parseFromSlice(
        add_agent_tool.AddAgentInput,
        allocator,
        tool_call.function.arguments,
        .{ .allocate = .alloc_always },
    ) catch {
        return try std.fmt.allocPrint(allocator,
            \\<agent>
            \\<name></name>
            \\<created>false</created>
            \\<error>Failed to parse add_agent arguments</error>
            \\</agent>
        , .{});
    };
    defer parsed.deinit();

    const result = add_agent_tool.executeAddAgentToString(allocator, parsed.value) catch {
        return try std.fmt.allocPrint(allocator,
            \\<agent>
            \\<name>{s}</name>
            \\<created>false</created>
            \\<error>Failed to add agent</error>
            \\</agent>
        , .{ parsed.value.name });
    };
    
    return result;
}
