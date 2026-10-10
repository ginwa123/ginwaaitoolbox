//! LLM tool wrapper: `create_kanban_task`.
//!
//! Parses the LLM's tool-call arguments, calls the implementation in
//! `src/modules/agent/tools/create_kanban_task.zig::executeKanbanTaskToJSON`,
//! wraps the returned JSON via `wrapToolOutput`, and detects `"error"`
//! to surface structured failures as `success=false` to the LLM.
//!
//! Mirrors the pattern in `tools_exec_kanban_list.zig` (parse with
//! `std.json.parseFromSlice`, call the implementation, wrap output).
//!
//! Plan: docs/superpowers/plans/2026-07-29-create-kanban-task-tool.md (Task 5)

const std = @import("std");
const pabrikcore = @import("pabrikcore");
const tools = @import("tools.zig");

const ToolExecContext = tools.ToolExecContext;
const ToolExecResult = tools.ToolExecResult;
const agent = pabrikcore.agent;
const create_kanban_task_mod = pabrikcore.create_kanban_task;
const wrapToolOutput = tools.wrapToolOutput;
const error_explain = @import("tools_error_explain.zig");

pub fn execCreateKanbanTask(ctx: ToolExecContext, tc: agent.ToolCall) !ToolExecResult {
    const parsed = std.json.parseFromSlice(
        create_kanban_task_mod.CreateKanbanTaskInput,
        ctx.allocator,
        tc.function.arguments,
        .{ .allocate = .alloc_always, .ignore_unknown_fields = true },
    ) catch |err| {
        const err_msg = try error_explain.explain(ctx.allocator, err, null);
        defer ctx.allocator.free(err_msg);
        const output = try wrapToolOutput(ctx.allocator, "create_kanban_task", tc.function.arguments, false, err_msg, "");
        return ToolExecResult{ .output = output, .output_allocated = true };
    };
    defer parsed.deinit();

    // Seed the session's chat with a real model id. The tool's own schema
    // has no `resolved_model` field, so this is the only way that value is
    // ever populated — and the seed INSERT's `llm_history.model` bind
    // depends on it. Assigned unconditionally so a model that guessed the
    // field (or omitted it) cannot influence what gets recorded.
    var input = parsed.value;
    input.resolved_model = ctx.model;

    // executeKanbanTaskToJSON returns a JSON string. Errors
    // (missing input, DB failure, validation rejection) are encoded as
    // {"success":false,"error":...} so the LLM sees
    // a structured failure rather than a tool crash.
    const inner = create_kanban_task_mod.executeKanbanTaskToJSON(
        ctx.allocator,
        ctx.db,
        input,
    ) catch |err| {
        const err_msg = try error_explain.explain(ctx.allocator, err, null);
        defer ctx.allocator.free(err_msg);
        const output = try wrapToolOutput(ctx.allocator, "create_kanban_task", tc.function.arguments, false, err_msg, "");
        return ToolExecResult{ .output = output, .output_allocated = true };
    };
    defer ctx.allocator.free(inner);

    // Detect the {"success":false,"error":...} shape via the top-level
    // "error" key (parsed, not substring-matched) and surface it as a
    // tool failure (so the LLM sees success=false rather than a
    // successful wrapper around an error body).
    if (std.json.parseFromSlice(struct { @"error": ?[]const u8 = null }, ctx.allocator, inner, .{ .allocate = .alloc_always, .ignore_unknown_fields = true }) catch null) |probe| {
        defer probe.deinit();
        if (probe.value.@"error") |err_msg| {
            const output = try wrapToolOutput(ctx.allocator, "create_kanban_task", tc.function.arguments, false, err_msg, inner);
            return ToolExecResult{ .output = output, .output_allocated = true };
        }
    }

    const output = try wrapToolOutput(ctx.allocator, "create_kanban_task", tc.function.arguments, true, null, inner);
    return ToolExecResult{ .output = output, .output_allocated = true };
}
