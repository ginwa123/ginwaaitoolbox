const std = @import("std");
const tree1_mod = @import("nalarcore");
const agent = tree1_mod.agent;
const text_replace_mod = tree1_mod.text_replace;

/// Stateless text_replace tool handler - only handles core logic:
/// 1. Parse arguments from tool_call.function.arguments
/// 2. Execute text_replace_batch
/// Returns the result as string or error.
///
/// All side effects (DB, logging, socket, message list) must be handled by caller.
pub fn handle_text_replace_tool_run(
    allocator: std.mem.Allocator,
    tool_call: agent.ToolCall,
) ![]const u8 {
    // Parse arguments JSON to TextReplaceInput
    const parsed = try std.json.parseFromSlice(
        text_replace_mod.TextReplaceInput,
        allocator,
        tool_call.function.arguments,
        .{ .allocate = .alloc_always },
    );
    defer parsed.deinit();

    const result = try text_replace_mod.text_replace_batch(
        allocator,
        parsed.value.path,
        parsed.value.ops,
        parsed.value.expected_hash,
    );

    // Convert batch result to string format
    const res = try text_replace_mod.text_replace_batch_to_string_xml(allocator, result);
    // Caller is responsible for freeing this returned string

    return res;
}
