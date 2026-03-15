const std = @import("std");
const tree1_mod = @import("nalarcore");
const agent = tree1_mod.agent;
const text_replace_tool = tree1_mod.text_replace;

/// Stateless text_replace tool handler - only handles core logic:
/// 1. Parse arguments from tool_call.function.arguments
/// 2. Execute text_replace
/// Returns the result as string or error.
/// 
/// All side effects (DB, logging, socket, message list) must be handled by caller.
pub fn run(
    allocator: std.mem.Allocator,
    tool_call: agent.ToolCall,
) ![]const u8 {
    // Parse arguments JSON to TextReplaceInput
    const parsed = try std.json.parseFromSlice(
        text_replace_tool.TextReplaceInput,
        allocator,
        tool_call.function.arguments,
        .{ .allocate = .alloc_always },
    );
    defer parsed.deinit();

    const text_replace_result = try text_replace_tool.text_replace(
        allocator,
        parsed.value.path,
        parsed.value.old_str,
        parsed.value.new_str,
        parsed.value.expected_hash,
    );
    
    // Convert text_replace result to string format
    const res_replace = try text_replace_tool.textReplaceToString(allocator, text_replace_result);
    // Caller is responsible for freeing this returned string
    text_replace_result.deinit(allocator);
    
    return res_replace;
}
