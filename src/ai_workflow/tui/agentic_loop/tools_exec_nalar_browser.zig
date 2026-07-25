const std = @import("std");
const mod = @import("mod.zig");
const nalarcore = mod.nalarcore;
const tools = mod.tools;
const ToolExecContext = tools.ToolExecContext;
const ToolExecResult = tools.ToolExecResult;
const agent = nalarcore.agent;
const nalar_browser_mod = nalarcore.nalar_browser;
const wrapToolOutput = tools.wrapToolOutput;

pub fn execNalarBrowser(ctx: ToolExecContext, tc: agent.ToolCall) !ToolExecResult {
    const parsed = std.json.parseFromSlice(
        nalar_browser_mod.NalarBrowserInput,
        ctx.allocator,
        tc.function.arguments,
        .{ .allocate = .alloc_always },
    ) catch |err| {
        const err_msg = try std.fmt.allocPrint(ctx.allocator, "nalar_browser failed: {s}", .{@errorName(err)});
        const output = try wrapToolOutput(ctx.allocator, "nalar_browser", tc.function.arguments, false, err_msg, "");
        return ToolExecResult{ .output = output, .output_allocated = true };
    };
    defer parsed.deinit();

    const result = nalar_browser_mod.execute_nalar_browser(ctx.allocator, ctx.io, parsed.value) catch |err| {
        const err_msg = try std.fmt.allocPrint(ctx.allocator, "nalar_browser failed: {s}", .{@errorName(err)});
        const output = try wrapToolOutput(ctx.allocator, "nalar_browser", tc.function.arguments, false, err_msg, "");
        return ToolExecResult{ .output = output, .output_allocated = true };
    };

    if (result.success) {
        const inner = try nalar_browser_mod.toXMLSuccess(ctx.allocator, result);
        const output = try wrapToolOutput(ctx.allocator, "nalar_browser", tc.function.arguments, true, null, inner);
        return ToolExecResult{ .output = output, .output_allocated = true };
    } else {
        const inner = try nalar_browser_mod.toXMLError(ctx.allocator, result, parsed.value.action);
        const err_msg = try std.fmt.allocPrint(ctx.allocator, "nalar_browser {s} failed", .{parsed.value.action});
        const output = try wrapToolOutput(ctx.allocator, "nalar_browser", tc.function.arguments, false, err_msg, inner);
        return ToolExecResult{ .output = output, .output_allocated = true };
    }
}