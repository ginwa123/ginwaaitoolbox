const std = @import("std");
const tree1_mod = @import("nalarcore");
const agent = tree1_mod.agent;
const bash_tool = tree1_mod.bash_tool;
const tool_models = tree1_mod.tool_models;

/// Stateless bash tool handler - only handles core logic:
/// 1. Parse arguments from tool_call.function.arguments
/// 2. Execute bash command
/// Returns the bash output as string or error.
/// 
/// All side effects (DB, logging, socket, message list) must be handled by caller.
pub fn run(
    allocator: std.mem.Allocator,
    tool_call: agent.ToolCall,
) ![]const u8 {
    // Parse arguments JSON to BashInput
    const parsed = try std.json.parseFromSlice(
        tool_models.BashInput,
        allocator,
        tool_call.function.arguments,
        .{ .allocate = .alloc_always },
    );
    defer parsed.deinit();

    const bash_output = try bash_tool.executeBash(allocator, parsed.value);
    const res_bash = try bash_tool.bashResultToString(allocator, bash_output);
    
    return res_bash;
}

test {
    _ = @import("handle_bash_tool_test.zig");
}
