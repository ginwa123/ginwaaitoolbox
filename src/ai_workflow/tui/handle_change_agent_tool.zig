const std = @import("std");
const tree1_mod = @import("nalarcore");
const agent = tree1_mod.agent;
const change_agent_tool = tree1_mod.change_agent_tool;

/// Result of parsing change_agent_tool arguments
pub const ChangeAgentResult = struct {
    agent: []const u8,
    message: []const u8,
    temperature: ?f32,
    is_thinking: ?bool,
    tool_call_id: []const u8,
    arguments: []const u8,
};

/// Stateless change_agent tool handler - only handles core logic:
/// 1. Parse arguments from tool_call.function.arguments
/// Returns ChangeAgentResult with parsed data.
/// 
/// Note: All side effects (modifying temperature/is_thinking, messages_list, DB, SSE) must be handled by caller.
pub fn run(
    allocator: std.mem.Allocator,
    tool_call: agent.ToolCall,
) !ChangeAgentResult {
    const parsed = try std.json.parseFromSlice(
        change_agent_tool.ChangeAgentToolResult,
        allocator,
        tool_call.function.arguments,
        .{},
    );
    defer parsed.deinit();

    const contentChangeAgent = try std.fmt.allocPrint(
        allocator,
        "<change_agent_tool>\n{s}\n<change_agent_tool>",
        .{tool_call.function.arguments},
    );
    
    return ChangeAgentResult{
        .agent = parsed.value.agent,
        .message = parsed.value.message,
        .temperature = parsed.value.temperature,
        .is_thinking = parsed.value.is_thinking,
        .tool_call_id = try allocator.dupe(u8, tool_call.id),
        .arguments = contentChangeAgent,
    };
}

test {
    _ = @import("handle_change_agent_tool_test.zig");
}
