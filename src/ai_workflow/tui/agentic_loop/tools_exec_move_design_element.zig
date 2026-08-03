//! Tool executor for `move_design_element` — wraps
//! `nalarcore.move_design_element.executeMoveDesignElementToString`
//! into the `ToolExecContext` / `ToolExecResult` shape used by the
//! agentic loop's tool dispatcher.
//!
//! Plan: docs/superpowers/plans/2026-08-06-move-element-with-descendants.md
//! (Chunk 5, Task 5.2)

const std = @import("std");
const nalarcore = @import("nalarcore");
const tools = @import("tools.zig");

const ToolExecContext = tools.ToolExecContext;
const ToolExecResult = tools.ToolExecResult;
const agent = nalarcore.agent;
const move_design_element_mod = nalarcore.move_design_element;
const wrapToolOutput = tools.wrapToolOutput;

pub fn execMoveDesignElement(ctx: ToolExecContext, tc: agent.ToolCall) !ToolExecResult {
    const parsed = std.json.parseFromSlice(
        move_design_element_mod.MoveDesignElementInput,
        ctx.allocator,
        tc.function.arguments,
        .{ .allocate = .alloc_always, .ignore_unknown_fields = true },
    ) catch |err| {
        const err_msg = try std.fmt.allocPrint(ctx.allocator, "move_design_element failed to parse input: {s}", .{@errorName(err)});
        const output = try wrapToolOutput(ctx.allocator, "move_design_element", tc.function.arguments, false, err_msg, "");
        return ToolExecResult{ .output = output, .output_allocated = true };
    };
    defer parsed.deinit();

    // move_design_element doesn't need Io for the cascade path (no
    // disk writes); the same DB-only signature as set_element_parent.
    const inner = move_design_element_mod.executeMoveDesignElementToString(
        ctx.allocator,
        ctx.db,
        parsed.value,
    ) catch |err| {
        const err_msg = try std.fmt.allocPrint(ctx.allocator, "move_design_element failed: {s}", .{@errorName(err)});
        const output = try wrapToolOutput(ctx.allocator, "move_design_element", tc.function.arguments, false, err_msg, "");
        return ToolExecResult{ .output = output, .output_allocated = true };
    };
    defer ctx.allocator.free(inner);

    // Detect <move_design_element><error>...</error></move_design_element>
    // and surface it as a tool failure.
    if (std.mem.indexOf(u8, inner, "<error>") != null) {
        const err_start = (std.mem.indexOf(u8, inner, "<error>") orelse 0) + "<error>".len;
        const err_end = std.mem.indexOf(u8, inner[err_start..], "</error>") orelse inner.len;
        const err_msg = inner[err_start .. err_start + err_end];
        const output = try wrapToolOutput(ctx.allocator, "move_design_element", tc.function.arguments, false, err_msg, inner);
        return ToolExecResult{ .output = output, .output_allocated = true };
    }

    const output = try wrapToolOutput(ctx.allocator, "move_design_element", tc.function.arguments, true, null, inner);
    return ToolExecResult{ .output = output, .output_allocated = true };
}
