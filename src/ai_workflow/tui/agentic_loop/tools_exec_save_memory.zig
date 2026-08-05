const std = @import("std");
const nalarcore = @import("nalarcore");
const tools = @import("tools.zig");

const ToolExecContext = tools.ToolExecContext;
const ToolExecResult = tools.ToolExecResult;
const agent = nalarcore.agent;
const save_memory_mod = nalarcore.save_memory;
const wrapToolOutput = tools.wrapToolOutput;

pub fn execSaveMemory(ctx: ToolExecContext, tc: agent.ToolCall) !ToolExecResult {
    const parsed = std.json.parseFromSlice(
        save_memory_mod.SaveMemoryInput,
        ctx.allocator,
        tc.function.arguments,
        .{ .allocate = .alloc_always, .ignore_unknown_fields = true },
    ) catch |err| {
        const err_msg = try std.fmt.allocPrint(ctx.allocator, "save_memory failed to parse input: {s}", .{@errorName(err)});
        const output = try wrapToolOutput(ctx.allocator, "save_memory", tc.function.arguments, false, err_msg, "");
        return ToolExecResult{ .output = output, .output_allocated = true };
    };
    defer parsed.deinit();

    const inner = save_memory_mod.executeSaveMemory(
        ctx.allocator,
        ctx.db,
        parsed.value,
    ) catch |err| {
        const err_msg = try std.fmt.allocPrint(ctx.allocator, "save_memory failed: {s}", .{@errorName(err)});
        const output = try wrapToolOutput(ctx.allocator, "save_memory", tc.function.arguments, false, err_msg, "");
        return ToolExecResult{ .output = output, .output_allocated = true };
    };
    defer ctx.allocator.free(inner);

    // Detect the <save_memory><error>...</error></save_memory> shape and
    // surface it as a tool failure (so the LLM sees success=false rather
    // than a successful wrapper around an error body).
    if (std.mem.indexOf(u8, inner, "<error>") != null) {
        const err_start = (std.mem.indexOf(u8, inner, "<error>") orelse 0) + "<error>".len;
        const err_end = std.mem.indexOf(u8, inner[err_start..], "</error>") orelse inner.len;
        const err_msg = inner[err_start .. err_start + err_end];
        const output = try wrapToolOutput(ctx.allocator, "save_memory", tc.function.arguments, false, err_msg, inner);
        return ToolExecResult{ .output = output, .output_allocated = true };
    }

    const output = try wrapToolOutput(ctx.allocator, "save_memory", tc.function.arguments, true, null, inner);
    return ToolExecResult{ .output = output, .output_allocated = true };
}
