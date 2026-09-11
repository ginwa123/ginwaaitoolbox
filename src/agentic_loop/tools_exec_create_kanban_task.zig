//! LLM tool wrapper: `create_kanban_task`.
//!
//! Parses the LLM's tool-call arguments, calls the implementation in
//! `src/modules/agent/tools/create_kanban_task.zig::executeCreateKanbanTaskToString`,
//! wraps the returned XML via `wrapToolOutput`, and detects `<error>`
//! to surface structured failures as `success=false` to the LLM.
//!
//! Mirrors the pattern in `tools_exec_kanban_list.zig` (parse with
//! `std.json.parseFromSlice`, call the implementation, wrap output).
//!
//! Plan: docs/superpowers/plans/2026-07-29-create-kanban-task-tool.md (Task 5)

const std = @import("std");
const nalarcore = @import("nalarcore");
const tools = @import("tools.zig");

const ToolExecContext = tools.ToolExecContext;
const ToolExecResult = tools.ToolExecResult;
const agent = nalarcore.agent;
const create_kanban_task_mod = nalarcore.create_kanban_task;
const wrapToolOutput = tools.wrapToolOutput;

pub fn execCreateKanbanTask(ctx: ToolExecContext, tc: agent.ToolCall) !ToolExecResult {
    const parsed = std.json.parseFromSlice(
        create_kanban_task_mod.CreateKanbanTaskInput,
        ctx.allocator,
        tc.function.arguments,
        .{ .allocate = .alloc_always, .ignore_unknown_fields = true },
    ) catch |err| {
        const err_msg = try std.fmt.allocPrint(ctx.allocator, "create_kanban_task failed to parse input: {s}", .{@errorName(err)});
        const output = try wrapToolOutput(ctx.allocator, "create_kanban_task", tc.function.arguments, false, err_msg, "");
        return ToolExecResult{ .output = output, .output_allocated = true };
    };
    defer parsed.deinit();

    // executeCreateKanbanTaskToString returns an XML string. Errors
    // (missing input, DB failure, validation rejection) are encoded as
    // <kanban_task><error>...</error></kanban_task> so the LLM sees
    // a structured failure rather than a tool crash.
    const inner = create_kanban_task_mod.executeCreateKanbanTaskToString(
        ctx.allocator,
        ctx.db,
        parsed.value,
    ) catch |err| {
        const err_msg = try std.fmt.allocPrint(ctx.allocator, "create_kanban_task failed: {s}", .{@errorName(err)});
        const output = try wrapToolOutput(ctx.allocator, "create_kanban_task", tc.function.arguments, false, err_msg, "");
        return ToolExecResult{ .output = output, .output_allocated = true };
    };
    defer ctx.allocator.free(inner);

    // Detect the <kanban_task><error>...</error></kanban_task> shape
    // and surface it as a tool failure (so the LLM sees success=false
    // rather than a successful wrapper around an error body).
    if (std.mem.indexOf(u8, inner, "<error>") != null) {
        const err_start = (std.mem.indexOf(u8, inner, "<error>") orelse 0) + "<error>".len;
        const err_end = std.mem.indexOf(u8, inner[err_start..], "</error>") orelse (inner.len - err_start);
        const err_msg = inner[err_start .. err_start + err_end];
        const output = try wrapToolOutput(ctx.allocator, "create_kanban_task", tc.function.arguments, false, err_msg, inner);
        return ToolExecResult{ .output = output, .output_allocated = true };
    }

    const output = try wrapToolOutput(ctx.allocator, "create_kanban_task", tc.function.arguments, true, null, inner);
    return ToolExecResult{ .output = output, .output_allocated = true };
}