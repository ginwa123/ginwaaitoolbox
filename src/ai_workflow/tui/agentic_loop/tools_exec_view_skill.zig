const std = @import("std");
const nalarcore = @import("nalarcore");
const tools = @import("tools.zig");

const ToolExecContext = tools.ToolExecContext;
const ToolExecResult = tools.ToolExecResult;
const agent = nalarcore.agent;
const view_skill_mod = nalarcore.view_skill_tool;
const wrapToolOutput = tools.wrapToolOutput;

pub fn execViewSkill(ctx: ToolExecContext, tc: agent.ToolCall) !ToolExecResult {
    const parsed = std.json.parseFromSlice(
        view_skill_mod.ViewSkillInput,
        ctx.allocator,
        tc.function.arguments,
        .{ .allocate = .alloc_always },
    ) catch |err| {
        const err_msg = try std.fmt.allocPrint(ctx.allocator, "view_skill failed: {s}", .{@errorName(err)});
        const output = try wrapToolOutput(ctx.allocator, "view_skill", tc.function.arguments, false, err_msg, "");
        return ToolExecResult{ .output = output, .output_allocated = true };
    };
    defer parsed.deinit();

    const inner = view_skill_mod.execute_view_skill_to_string(ctx.allocator, ctx.io, parsed.value, ctx.environment) catch |err| {
        const err_msg = try std.fmt.allocPrint(ctx.allocator, "view_skill failed: {s}", .{@errorName(err)});
        const output = try wrapToolOutput(ctx.allocator, "view_skill", tc.function.arguments, false, err_msg, "");
        return ToolExecResult{ .output = output, .output_allocated = true };
    };

    // Empty skill_name means "not found" → wrap as error.
    if (std.mem.indexOf(u8, inner, "<skill_name></skill_name>") != null) {
        const err_msg = try ctx.allocator.dupe(u8, "Skill not found");
        const output = try wrapToolOutput(ctx.allocator, "view_skill", tc.function.arguments, false, err_msg, "");
        return ToolExecResult{ .output = output, .output_allocated = true };
    }

    const output = try wrapToolOutput(ctx.allocator, "view_skill", tc.function.arguments, true, null, inner);
    return ToolExecResult{ .output = output, .output_allocated = true };
}