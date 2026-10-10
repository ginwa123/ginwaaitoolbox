const std = @import("std");
const pabrikcore = @import("pabrikcore");
const tools = @import("tools.zig");

const ToolExecContext = tools.ToolExecContext;
const ToolExecResult = tools.ToolExecResult;
const agent = pabrikcore.agent;
const list_memory_mod = pabrikcore.list_memory_tool;
const wrapToolOutput = tools.wrapToolOutput;
const error_explain = @import("tools_error_explain.zig");

pub fn execListMemory(ctx: ToolExecContext, tc: agent.ToolCall) !ToolExecResult {
    // Memories are global only — no cwd involvement. The env comes from ctx
    // (same path as list_skills); on null we emit an error-tagged XML so the
    // LLM gets a structured failure instead of a panic.
    const inner = list_memory_mod.execute_list_memory(ctx.allocator, ctx.io, ctx.environment) catch |err| {
        const err_msg = try error_explain.explain(ctx.allocator, err, null);
        defer ctx.allocator.free(err_msg);
        const output = try wrapToolOutput(ctx.allocator, "list_memory", tc.function.arguments, false, err_msg, "");
        return ToolExecResult{ .output = output, .output_allocated = true };
    };
    const output = try wrapToolOutput(ctx.allocator, "list_memory", tc.function.arguments, true, null, inner);
    return ToolExecResult{ .output = output, .output_allocated = true };
}