const std = @import("std");
const tree1_mod = @import("nalarcore");
const agent = tree1_mod.agent;
const add_skill_tool = tree1_mod.add_skill;

/// Stateless add_skill tool handler - creates a new skill file:
/// 1. Parse arguments from tool_call.function.arguments
/// 2. Execute add_skill to create the file
/// Returns the result as string or error.
pub fn handle_add_skill_tool_run(
    allocator: std.mem.Allocator,
    tool_call: agent.ToolCall,
) ![]const u8 {
    // Parse arguments JSON to AddSkillInput
    const parsed = std.json.parseFromSlice(
        add_skill_tool.AddSkillInput,
        allocator,
        tool_call.function.arguments,
        .{ .allocate = .alloc_always },
    ) catch {
        return try std.fmt.allocPrint(allocator,
            \\<skill>
            \\<name></name>
            \\<created>false</created>
            \\<error>Failed to parse add_skill arguments</error>
            \\</skill>
        , .{});
    };
    defer parsed.deinit();

    const result = add_skill_tool.executeAddSkillToString(allocator, parsed.value) catch {
        return try std.fmt.allocPrint(allocator,
            \\<skill>
            \\<name>{s}</name>
            \\<created>false</created>
            \\<error>Failed to add skill</error>
            \\</skill>
        , .{ parsed.value.name });
    };
    
    return result;
}
