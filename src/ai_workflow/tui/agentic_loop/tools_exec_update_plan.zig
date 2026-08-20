// Exec wrapper for the `update_plan` agent tool.
//
// The wrapper parses the JSON arguments emitted by the LLM, threads
// `ctx.session_id` into the pure-fn layer (D3 — session_id is implicit
// in the tool's input schema, never accepted as an argument), and wraps
// the result in the standard `<tool>...</tool>` envelope via
// `wrapToolOutput`.
//
// Plan: docs/superpowers/plans/2026-08-19-session-plan-agent-tool.md
// Task: task_1787073929852_8 (Task 4 of 9)

const std = @import("std");
const nalarcore = @import("nalarcore");
const tools = @import("tools.zig");

const ToolExecContext = tools.ToolExecContext;
const ToolExecResult = tools.ToolExecResult;
const agent = nalarcore.agent;
const update_plan_mod = nalarcore.update_plan;
const wrapToolOutput = tools.wrapToolOutput;

pub fn execUpdatePlan(ctx: ToolExecContext, tc: agent.ToolCall) !ToolExecResult {
    const parsed = std.json.parseFromSlice(
        update_plan_mod.UpdatePlanInput,
        ctx.allocator,
        tc.function.arguments,
        .{ .allocate = .alloc_always, .ignore_unknown_fields = true },
    ) catch |err| {
        const err_msg = try std.fmt.allocPrint(ctx.allocator, "update_plan failed to parse input: {s}", .{@errorName(err)});
        defer ctx.allocator.free(err_msg);
        const output = try wrapToolOutput(ctx.allocator, "update_plan", tc.function.arguments, false, err_msg, "");
        return ToolExecResult{ .output = output, .output_allocated = true };
    };
    defer parsed.deinit();

    const inner = update_plan_mod.executeUpdatePlan(
        ctx.allocator,
        ctx.db,
        ctx.session_id,
        parsed.value,
    ) catch |err| {
        const err_msg = try std.fmt.allocPrint(ctx.allocator, "update_plan failed: {s}", .{@errorName(err)});
        defer ctx.allocator.free(err_msg);
        const output = try wrapToolOutput(ctx.allocator, "update_plan", tc.function.arguments, false, err_msg, "");
        return ToolExecResult{ .output = output, .output_allocated = true };
    };
    defer ctx.allocator.free(inner);

    // Detect the <update_plan><error>...</error></update_plan> shape and
    // surface it as a tool failure (so the LLM sees success=false rather
    // than a successful wrapper around an error body). The inner XML
    // is still surfaced in <data> so the LLM can see the per-tool
    // detail (e.g. "content must be non-empty (1 byte minimum)").
    if (std.mem.indexOf(u8, inner, "<error>") != null) {
        const err_start = (std.mem.indexOf(u8, inner, "<error>") orelse 0) + "<error>".len;
        const err_end = std.mem.indexOf(u8, inner[err_start..], "</error>") orelse inner.len;
        const err_msg = inner[err_start .. err_start + err_end];
        const output = try wrapToolOutput(ctx.allocator, "update_plan", tc.function.arguments, false, err_msg, inner);
        return ToolExecResult{ .output = output, .output_allocated = true };
    }

    const output = try wrapToolOutput(ctx.allocator, "update_plan", tc.function.arguments, true, null, inner);
    return ToolExecResult{ .output = output, .output_allocated = true };
}