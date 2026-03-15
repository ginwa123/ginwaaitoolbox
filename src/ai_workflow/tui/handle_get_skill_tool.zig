const std = @import("std");
const tree1_mod = @import("nalarcore");
const agent = tree1_mod.agent;
const get_skill_tool = tree1_mod.get_skill_tool;

/// Stateless get_skill tool handler - only handles core logic:
/// 1. Parse arguments from tool_call.function.arguments
/// 2. Execute get_skill
/// Returns the result as string or error.
/// 
/// Note: Saving skill to DB and sending to TUI are side effects that must be handled by caller.
pub fn run(
    allocator: std.mem.Allocator,
    tool_call: agent.ToolCall,
) ![]const u8 {
    // Parse arguments JSON to GetSkillInput
    const parsed = std.json.parseFromSlice(
        get_skill_tool.GetSkillInput,
        allocator,
        tool_call.function.arguments,
        .{ .allocate = .alloc_always },
    ) catch {
        return "<skill_name></skill_name><content></content><loaded>false</loaded><error>Failed to parse get_skill arguments</error>";
    };
    defer parsed.deinit();

    const result = get_skill_tool.executeGetSkillToString(allocator, parsed.value) catch {
        return "<skill_name></skill_name><content></content><loaded>false</loaded><error>Failed to get skill</error>";
    };
    
    return result;
}

// test {
//     _ = @import("handle_get_skill_tool_test.zig");
// }
