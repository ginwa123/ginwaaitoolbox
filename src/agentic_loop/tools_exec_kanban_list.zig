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

    // executeKanbanListToString returns an XML string. Errors (missing
    // input, DB failure) are encoded as <kanban><error>...</error></kanban>
    // so the LLM sees a structured failure rather than a tool crash.
    const inner = kanban_list_mod.executeKanbanListToString(
        ctx.allocator,
        ctx.db,
        parsed.value,
    ) catch |err| {
        const err_msg = try std.fmt.allocPrint(ctx.allocator, "kanban_list failed: {s}", .{@errorName(err)});
        const output = try wrapToolOutput(ctx.allocator, "kanban_list", tc.function.arguments, false, err_msg, "");
        return ToolExecResult{ .output = output, .output_allocated = true };
    };
    defer ctx.allocator.free(inner);

    // Detect the <kanban><error>...</error></kanban> shape and surface
    // it as a tool failure (so the LLM sees `success=false` rather
    // than a successful wrapper around an error body).
    if (std.mem.indexOf(u8, inner, "<error>") != null) {
        const err_start = (std.mem.indexOf(u8, inner, "<error>") orelse 0) + "<error>".len;
        const err_end = std.mem.indexOf(u8, inner[err_start..], "</error>") orelse (inner.len - err_start);
        const err_msg = inner[err_start .. err_start + err_end];
        const output = try wrapToolOutput(ctx.allocator, "kanban_list", tc.function.arguments, false, err_msg, inner);
        return ToolExecResult{ .output = output, .output_allocated = true };
    }

    const output = try wrapToolOutput(ctx.allocator, "kanban_list", tc.function.arguments, true, null, inner);
    return ToolExecResult{ .output = output, .output_allocated = true };
}