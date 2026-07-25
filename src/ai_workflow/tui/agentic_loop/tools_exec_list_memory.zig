const std = @import("std");
const mod = @import("mod.zig");
const nalarcore = mod.nalarcore;
const tools = mod.tools;
const ToolExecContext = tools.ToolExecContext;
const ToolExecResult = tools.ToolExecResult;
const agent = nalarcore.agent;
const list_memory_mod = nalarcore.list_memory_tool;
const wrapToolOutput = tools.wrapToolOutput;

pub fn execListMemory(ctx: ToolExecContext, tc: agent.ToolCall) !ToolExecResult {
    // Memories are global only — no cwd involvement. The env comes from ctx
    // (same path as list_skills); on null we emit an error-tagged XML so the
    // LLM gets a structured failure instead of a panic.
    const inner = list_memory_mod.execute_list_memory(ctx.allocator, ctx.io, ctx.environment) catch |err| {
        const err_msg = try std.fmt.allocPrint(ctx.allocator, "list_memory failed: {s}", .{@errorName(err)});
        const output = try wrapToolOutput(ctx.allocator, "list_memory", tc.function.arguments, false, err_msg, "");
        return ToolExecResult{ .output = output, .output_allocated = true };
    };
    const output = try wrapToolOutput(ctx.allocator, "list_memory", tc.function.arguments, true, null, inner);
    return ToolExecResult{ .output = output, .output_allocated = true };
}