// Exec wrapper for the `get_plan` agent tool.
//
// `get_plan` declares zero required parameters — session_id is implicit
// (D3) and pulled from `ctx.session_id` here. The wrapper calls the
// pure-fn layer (which returns `<empty/>` when no plan exists, D6) and
// wraps the result in the standard `<tool>...</tool>` envelope.
//
// Plan: docs/superpowers/plans/2026-08-19-session-plan-agent-tool.md
// Task: task_1787073929852_8 (Task 4 of 9)

const std = @import("std");
const nalarcore = @import("nalarcore");
const tools = @import("tools.zig");

const ToolExecContext = tools.ToolExecContext;
const ToolExecResult = tools.ToolExecResult;
const agent = nalarcore.agent;
const get_plan_mod = nalarcore.get_plan;
const wrapToolOutput = tools.wrapToolOutput;

pub fn execGetPlan(ctx: ToolExecContext, tc: agent.ToolCall) !ToolExecResult {
    // No input to parse — the schema declares zero required params.
    // Use `tc.function.arguments` for the envelope's `<parameters>`
    // block verbatim (the LLM is expected to send `{}`).
    const inner = get_plan_mod.executeGetPlan(ctx.allocator, ctx.db, ctx.session_id) catch |err| {
        const err_msg = try std.fmt.allocPrint(ctx.allocator, "get_plan failed: {s}", .{@errorName(err)});
        defer ctx.allocator.free(err_msg);
        const output = try wrapToolOutput(ctx.allocator, "get_plan", tc.function.arguments, false, err_msg, "");
        return ToolExecResult{ .output = output, .output_allocated = true };
    };
    defer ctx.allocator.free(inner);

    const output = try wrapToolOutput(ctx.allocator, "get_plan", tc.function.arguments, true, null, inner);
    return ToolExecResult{ .output = output, .output_allocated = true };
}