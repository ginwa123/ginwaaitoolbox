const std = @import("std");
const mod = @import("mod.zig");
const nalarcore = mod.nalarcore;
const tools = mod.tools;
const ToolExecContext = tools.ToolExecContext;
const ToolExecResult = tools.ToolExecResult;
const agent = nalarcore.agent;
const list_agents_mod = nalarcore.list_agents;
const wrapToolOutput = tools.wrapToolOutput;

pub fn execListAgents(ctx: ToolExecContext, tc: agent.ToolCall) !ToolExecResult {
    const inner = list_agents_mod.executeListAgents(ctx.allocator, ctx.io, ctx.environment) catch |err| {
        const err_msg = try std.fmt.allocPrint(ctx.allocator, "list_agents failed: {s}", .{@errorName(err)});
        const output = try wrapToolOutput(ctx.allocator, "list_agents", tc.function.arguments, false, err_msg, "");
        return ToolExecResult{ .output = output, .output_allocated = true };
    };
    const output = try wrapToolOutput(ctx.allocator, "list_agents", tc.function.arguments, true, null, inner);
    return ToolExecResult{ .output = output, .output_allocated = true };
}