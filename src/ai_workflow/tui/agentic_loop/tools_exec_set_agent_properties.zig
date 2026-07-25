const std = @import("std");
const mod = @import("mod.zig");
const nalarcore = mod.nalarcore;
const tools = mod.tools;
const ToolExecContext = tools.ToolExecContext;
const ToolExecResult = tools.ToolExecResult;
const agent = nalarcore.agent;
const set_agent_properties_mod = nalarcore.set_agent_properties;
const wrapToolOutput = tools.wrapToolOutput;

/// Result of parsing set_agent_properties arguments. This is the
/// agentic_loop-internal output type — it carries the parsed
/// temperature/is_thinking overrides plus the wrapped XML envelope
/// (output) and a copy of the tool_call id (allocated by the caller).
///
/// The input type `set_agent_properties_mod.SetAgentPropertiesResult`
/// is the JSON-parsed shape; this type is the wrapper that carries
/// the side-effect data to handle_tool.zig.
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
fn handleSetAgentProperties(
    allocator: std.mem.Allocator,
    tool_call: agent.ToolCall,
) !SetAgentPropertiesResult {
    const parsed = try std.json.parseFromSlice(
        set_agent_properties_mod.SetAgentPropertiesResult,
        allocator,
        tool_call.function.arguments,
        .{},
    );
    defer parsed.deinit();

    // The execX contract is "set these fields and return the wrapped output".
    // We use the standardized envelope so handle_tool sees the same shape as
    // every other tool. The typo in the closing tag (`<set_agent_properties>`
    // without the `/`) in the previous version is fixed.
    const wrapped = try wrapToolOutput(allocator, "set_agent_properties", tool_call.function.arguments, true, null, "");

    return SetAgentPropertiesResult{
        .temperature = parsed.value.temperature,
        .is_thinking = parsed.value.is_thinking,
        .tool_call_id = try allocator.dupe(u8, tool_call.id),
        .arguments = wrapped,
    };
}

// set_agent_properties implementation - modifies agent temperature/is_thinking
pub fn execSetAgentProperties(ctx: ToolExecContext, tc: agent.ToolCall) !ToolExecResult {
    const result = try handleSetAgentProperties(ctx.allocator, tc);

    return ToolExecResult{
        .output = result.arguments,
        .output_allocated = true,
        .temperature = result.temperature,
        .is_thinking = result.is_thinking,
    };
}
