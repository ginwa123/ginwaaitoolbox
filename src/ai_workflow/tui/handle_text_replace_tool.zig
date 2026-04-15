const std = @import("std");
const tree1_mod = @import("nalarcore");
const agent = tree1_mod.agent;
const text_replace_tool_mod = tree1_mod.text_replace_tool;

/// Stateless text_replace tool handler
pub fn handle_text_replace_tool_run(
    allocator: std.mem.Allocator,
    tool_call: agent.ToolCall,
) ![]const u8 {
    // Check for empty arguments first
    if (tool_call.function.arguments.len == 0) {
        const result = try std.fmt.allocPrint(allocator,
            \\<error>text_replace failed: Missing arguments (empty JSON)</error>
            \\<path></path>
            \\<old_str></old_str>
            \\<new_str></new_str>
            \\<success>false</success>
        , .{});
        return result;
    }

    const parsed = std.json.parseFromSlice(
        text_replace_tool_mod.TextReplaceInput,
        allocator,
        tool_call.function.arguments,
        .{ .allocate = .alloc_always },
    ) catch |err| {
        const err_msg: []const u8 = switch (err) {
            error.UnexpectedEndOfInput => "text_replace failed: UnexpectedEndOfInput - arguments may be incomplete or malformed",
            else => "text_replace failed: Invalid JSON arguments",
        };
        const result = try std.fmt.allocPrint(allocator,
            \\<error>{s}</error>
            \\<path></path>
            \\<old_str></old_str>
            \\<new_str></new_str>
            \\<success>false</success>
        , .{err_msg});
        return result;
    };
    defer parsed.deinit();

    const result = try text_replace_tool_mod.text_replace(
        allocator,
        parsed.value.path,
        parsed.value.old_str,
        parsed.value.new_str,
    );

    return text_replace_tool_mod.to_xml(allocator, result);
}
