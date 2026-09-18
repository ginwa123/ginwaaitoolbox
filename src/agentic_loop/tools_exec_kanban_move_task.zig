const std = @import("std");
const nalarcore = @import("nalarcore");
const tools = @import("tools.zig");

const ToolExecContext = tools.ToolExecContext;
const ToolExecResult = tools.ToolExecResult;
const agent = nalarcore.agent;
const kanban_move_task_mod = nalarcore.kanban_move_task;
const wrapToolOutput = tools.wrapToolOutput;

pub fn execKanbanMoveTask(ctx: ToolExecContext, tc: agent.ToolCall) !ToolExecResult {
    const parsed = std.json.parseFromSlice(
        kanban_move_task_mod.KanbanMoveTaskInput,
        ctx.allocator,
        tc.function.arguments,
        .{ .allocate = .alloc_always, .ignore_unknown_fields = true },
    ) catch |err| {
        const err_msg = try std.fmt.allocPrint(ctx.allocator, "kanban_move_task failed to parse input: {s}", .{@errorName(err)});
        const output = try wrapToolOutput(ctx.allocator, "kanban_move_task", tc.function.arguments, false, err_msg, "");
        return ToolExecResult{ .output = output, .output_allocated = true };
    };
    defer parsed.deinit();

    const inner = kanban_move_task_mod.executeKanbanMoveTaskToJSON(
        ctx.allocator,
        ctx.db,
        parsed.value,
    ) catch |err| {
        const err_msg = try std.fmt.allocPrint(ctx.allocator, "kanban_move_task failed: {s}", .{@errorName(err)});
        const output = try wrapToolOutput(ctx.allocator, "kanban_move_task", tc.function.arguments, false, err_msg, "");
        return ToolExecResult{ .output = output, .output_allocated = true };
    };
    defer ctx.allocator.free(inner);

    // Detect {"success":false,"error":...} via the top-level "error" key
    // (parsed, not substring-matched, so task/column names containing
    // the word "error" can't false-positive).
    if (std.json.parseFromSlice(struct { @"error": ?[]const u8 = null }, ctx.allocator, inner, .{ .allocate = .alloc_always, .ignore_unknown_fields = true }) catch null) |probe| {
        defer probe.deinit();
        if (probe.value.@"error") |err_msg| {
            const output = try wrapToolOutput(ctx.allocator, "kanban_move_task", tc.function.arguments, false, err_msg, inner);
            return ToolExecResult{ .output = output, .output_allocated = true };
        }
    }

    const output = try wrapToolOutput(ctx.allocator, "kanban_move_task", tc.function.arguments, true, null, inner);
    return ToolExecResult{ .output = output, .output_allocated = true };
}
