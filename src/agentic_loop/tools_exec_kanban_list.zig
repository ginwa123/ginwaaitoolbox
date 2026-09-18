const std = @import("std");
const nalarcore = @import("nalarcore");
const tools = @import("tools.zig");

const ToolExecContext = tools.ToolExecContext;
const ToolExecResult = tools.ToolExecResult;
const agent = nalarcore.agent;
const kanban_list_mod = nalarcore.kanban_list;
const wrapToolOutput = tools.wrapToolOutput;

pub fn execKanbanList(ctx: ToolExecContext, tc: agent.ToolCall) !ToolExecResult {
    const parsed = std.json.parseFromSlice(
        kanban_list_mod.KanbanListInput,
        ctx.allocator,
        tc.function.arguments,
        .{ .allocate = .alloc_always, .ignore_unknown_fields = true },
    ) catch |err| {
        const err_msg = try std.fmt.allocPrint(ctx.allocator, "kanban_list failed to parse input: {s}", .{@errorName(err)});
        const output = try wrapToolOutput(ctx.allocator, "kanban_list", tc.function.arguments, false, err_msg, "");
        return ToolExecResult{ .output = output, .output_allocated = true };
    };
    defer parsed.deinit();

    // executeKanbanListToJSON returns a JSON string. Errors (missing
    // input, DB failure) are encoded as {"error":...}
    // so the LLM sees a structured failure rather than a tool crash.
    const inner = kanban_list_mod.executeKanbanListToJSON(
        ctx.allocator,
        ctx.db,
        parsed.value,
    ) catch |err| {
        const err_msg = try std.fmt.allocPrint(ctx.allocator, "kanban_list failed: {s}", .{@errorName(err)});
        const output = try wrapToolOutput(ctx.allocator, "kanban_list", tc.function.arguments, false, err_msg, "");
        return ToolExecResult{ .output = output, .output_allocated = true };
    };
    defer ctx.allocator.free(inner);

    // Detect the {"error":...} shape and surface it as a tool failure
    // (so the LLM sees `success=false` rather than a successful wrapper
    // around an error body).
    if (std.json.parseFromSlice(struct { @"error": ?[]const u8 = null }, ctx.allocator, inner, .{ .allocate = .alloc_always, .ignore_unknown_fields = true }) catch null) |probe| {
        defer probe.deinit();
        if (probe.value.@"error") |err_msg| {
            const output = try wrapToolOutput(ctx.allocator, "kanban_list", tc.function.arguments, false, err_msg, inner);
            return ToolExecResult{ .output = output, .output_allocated = true };
        }
    }

    const output = try wrapToolOutput(ctx.allocator, "kanban_list", tc.function.arguments, true, null, inner);
    return ToolExecResult{ .output = output, .output_allocated = true };
}
