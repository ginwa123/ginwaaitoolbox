const std = @import("std");
const mod = @import("mod.zig");
const nalarcore = mod.nalarcore;
const tools = mod.tools;
const ToolExecContext = tools.ToolExecContext;
const ToolExecResult = tools.ToolExecResult;
const agent = nalarcore.agent;
const list_skills_mod = nalarcore.list_skills_tool;
const wrapToolOutput = tools.wrapToolOutput;

pub fn execListSkills(ctx: ToolExecContext, tc: agent.ToolCall) !ToolExecResult {
    // Pass ctx.cwd so local skills are looked up in the session's workspace
    // (the same directory add_skill/edit_skill/remove_skill write to), matching
    // how those tools are invoked. Passing null here would make list_skills fall
    // back to the server's OS-level cwd, causing local skills to be invisible.
    const inner = list_skills_mod.execute_list_skills(ctx.allocator, ctx.io, ctx.cwd, ctx.environment) catch |err| {
        const err_msg = try std.fmt.allocPrint(ctx.allocator, "list_skills failed: {s}", .{@errorName(err)});
        const output = try wrapToolOutput(ctx.allocator, "list_skills", tc.function.arguments, false, err_msg, "");
        return ToolExecResult{ .output = output, .output_allocated = true };
    };
    const output = try wrapToolOutput(ctx.allocator, "list_skills", tc.function.arguments, true, null, inner);
    return ToolExecResult{ .output = output, .output_allocated = true };
}