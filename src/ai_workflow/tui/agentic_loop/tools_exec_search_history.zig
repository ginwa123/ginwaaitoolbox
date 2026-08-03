const std = @import("std");
const nalarcore = @import("nalarcore");
const tools = @import("tools.zig");

const ToolExecContext = tools.ToolExecContext;
const ToolExecResult = tools.ToolExecResult;
const agent = nalarcore.agent;
const search_history_mod = nalarcore.search_history_tool;
const wrapToolOutput = tools.wrapToolOutput;

pub fn execSearchHistory(ctx: ToolExecContext, tc: agent.ToolCall) !ToolExecResult {
    const parsed = std.json.parseFromSlice(
        search_history_mod.SearchHistoryInput,
        ctx.allocator,
        tc.function.arguments,
        .{ .allocate = .alloc_always, .ignore_unknown_fields = true },
    ) catch |err| {
        const err_msg = try std.fmt.allocPrint(ctx.allocator, "search_history failed: {s}", .{@errorName(err)});
        const output = try wrapToolOutput(ctx.allocator, "search_history", tc.function.arguments, false, err_msg, "");
        return ToolExecResult{ .output = output, .output_allocated = true };
    };
    defer parsed.deinit();

    const inner = search_history_mod.execute_search_history(
        ctx.allocator,
        ctx.io,
        ctx.db,
        parsed.value,
    ) catch |err| {
        const err_msg = try std.fmt.allocPrint(ctx.allocator, "search_history failed: {s}", .{@errorName(err)});
        const output = try wrapToolOutput(ctx.allocator, "search_history", tc.function.arguments, false, err_msg, "");
        return ToolExecResult{ .output = output, .output_allocated = true };
    };

    const output = try wrapToolOutput(ctx.allocator, "search_history", tc.function.arguments, true, null, inner);
    return ToolExecResult{ .output = output, .output_allocated = true };
}