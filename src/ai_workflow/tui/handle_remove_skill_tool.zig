const std = @import("std");
const tree1_mod = @import("nalarcore");
const agent = tree1_mod.agent;
const remove_skill_tool = tree1_mod.remove_skill_tool;

/// Stateless remove_skill tool handler - only handles core logic:
/// 1. Parse arguments from tool_call.function.arguments
/// 2. Execute remove_skill validation
/// Returns the result as string.
/// 
/// Note: DB removal and sending to TUI are side effects that must be handled by caller.
pub fn handle_remove_skill_tool_run(
    allocator: std.mem.Allocator,
    tool_call: agent.ToolCall,
) ![]const u8 {
    // Parse arguments JSON to RemoveSkillInput
    const parsed = std.json.parseFromSlice(
        remove_skill_tool.RemoveSkillInput,
        allocator,
        tool_call.function.arguments,
        .{ .allocate = .alloc_always },
    ) catch {
        return try std.fmt.allocPrint(allocator,
            \\<skill_name></skill_name>
            \\<removed>false</removed>
            \\<error>Failed to parse remove_skill arguments</error>
        , .{});
    };
    defer parsed.deinit();

    const result = remove_skill_tool.executeRemoveSkillToString(allocator, parsed.value) catch {
        return try std.fmt.allocPrint(allocator,
            \\<skill_name>{s}</skill_name>
            \\<removed>false</removed>
            \\<error>Unknown error</error>
        , .{ parsed.value.skill_name });
    };
    
    return result;
}

// test {
//     _ = @import("handle_remove_skill_tool_test.zig");
// }
