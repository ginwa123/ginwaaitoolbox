const std = @import("std");
const tree1_mod = @import("nalarcore");
const agent = tree1_mod.agent;
const text_replace_mod = tree1_mod.text_replace;

/// Stateless text_replace tool handler
pub fn handle_text_replace_tool_run(
    allocator: std.mem.Allocator,
    tool_call: agent.ToolCall,
) ![]const u8 {
    const parsed = try std.json.parseFromSlice(
        text_replace_mod.TextReplaceInput,
        allocator,
        tool_call.function.arguments,
        .{ .allocate = .alloc_always },
    );
    defer parsed.deinit();

    const result = try text_replace_mod.text_replace(
        allocator,
        parsed.value.path,
        parsed.value.old_str,
        parsed.value.new_str,
    );

    return text_replace_mod.text_replace_to_string_xml(allocator, result);
}
