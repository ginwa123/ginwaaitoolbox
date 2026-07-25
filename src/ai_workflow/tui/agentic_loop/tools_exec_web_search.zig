const std = @import("std");
const mod = @import("mod.zig");
const nalarcore = mod.nalarcore;
const tools = mod.tools;
const ToolExecContext = tools.ToolExecContext;
const ToolExecResult = tools.ToolExecResult;
const agent = nalarcore.agent;
const tool_models = nalarcore.tool_models;
const web_search_mod = nalarcore.web_search;
const wrapToolOutput = tools.wrapToolOutput;

pub fn execWebSearch(ctx: ToolExecContext, tc: agent.ToolCall) !ToolExecResult {
    const parsed = std.json.parseFromSlice(
        tool_models.WebSearchInput,
        ctx.allocator,
        tc.function.arguments,
        .{ .allocate = .alloc_always },
    ) catch |err| {
        const err_msg = try std.fmt.allocPrint(ctx.allocator, "web_search failed: {s}", .{@errorName(err)});
        const output = try wrapToolOutput(ctx.allocator, "web_search", tc.function.arguments, false, err_msg, "");
        return ToolExecResult{ .output = output, .output_allocated = true };
    };
    defer parsed.deinit();

    const result = web_search_mod.execute_web_search(ctx.allocator, ctx.io, parsed.value) catch |err| {
        const err_msg = try std.fmt.allocPrint(ctx.allocator, "web_search failed: {s}", .{@errorName(err)});
        const output = try wrapToolOutput(ctx.allocator, "web_search", tc.function.arguments, false, err_msg, "");
        return ToolExecResult{ .output = output, .output_allocated = true };
    };
    defer result.deinit(ctx.allocator);

    const inner = try web_search_mod.web_search_result_to_string(ctx.allocator, result);
    const output = try wrapToolOutput(ctx.allocator, "web_search", tc.function.arguments, true, null, inner);
    return ToolExecResult{ .output = output, .output_allocated = true };
}