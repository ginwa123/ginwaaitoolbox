const std = @import("std");
const tree1_mod = @import("nalarcore");
const agent = tree1_mod.agent;
const set_agent_properties = tree1_mod.set_agent_properties;

/// Result of parsing set_agent_properties arguments
pub const SetAgentPropertiesResult = struct {
    temperature: ?f32,
    is_thinking: ?bool,
    tool_call_id: []const u8,
    arguments: []const u8,
};

/// Stateless set_agent_properties tool handler - only handles core logic:
/// 1. Parse arguments from tool_call.function.arguments
/// Returns SetAgentPropertiesResult with parsed data.
///
/// Note: All side effects (modifying temperature/is_thinking, DB, SSE) must be handled by caller.
pub fn run(
    allocator: std.mem.Allocator,
    tool_call: agent.ToolCall,
) !SetAgentPropertiesResult {
    const parsed = try std.json.parseFromSlice(
        set_agent_properties.SetAgentPropertiesResult,
        allocator,
        tool_call.function.arguments,
        .{},
    );
    defer parsed.deinit();

    const contentSetAgentProps = try std.fmt.allocPrint(
        allocator,
        "<set_agent_properties>\n{s}\n<set_agent_properties>",
        .{tool_call.function.arguments},
    );
    
    return SetAgentPropertiesResult{
        .temperature = parsed.value.temperature,
        .is_thinking = parsed.value.is_thinking,
        .tool_call_id = try allocator.dupe(u8, tool_call.id),
        .arguments = contentSetAgentProps,
    };
}
