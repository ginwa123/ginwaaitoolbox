const std = @import("std");
const nalarcore = @import("nalarcore");
const tools = @import("tools.zig");

const ToolExecContext = tools.ToolExecContext;
const ToolExecResult = tools.ToolExecResult;
const agent = nalarcore.agent;
const text_replace_mod = nalarcore.text_replace_tool;
const wrapToolOutput = tools.wrapToolOutput;

pub fn execTextReplace(ctx: ToolExecContext, tc: agent.ToolCall) !ToolExecResult {
    const parsed = std.json.parseFromSlice(
        text_replace_mod.TextReplaceInput,
        ctx.allocator,
        tc.function.arguments,
        .{ .allocate = .alloc_always, .ignore_unknown_fields = true },
    ) catch |err| {
        const err_msg = try std.fmt.allocPrint(ctx.allocator, "text_replace failed: {s}", .{@errorName(err)});
        const output = try wrapToolOutput(ctx.allocator, "text_replace", tc.function.arguments, false, err_msg, "");
        return ToolExecResult{ .output = output, .output_allocated = true };
    };
    defer parsed.deinit();

    // Security: reject absolute paths.
    if (try nalarcore.path_security.rejectAbsolutePath(
        ctx.allocator, "text_replace", "path", parsed.value.path, ctx.cwd
    )) |err_msg| {
        defer ctx.allocator.free(err_msg);
        const output = try wrapToolOutput(ctx.allocator, "text_replace", tc.function.arguments, false, err_msg, "");
        return ToolExecResult{ .output = output, .output_allocated = true };
    }

    const result = text_replace_mod.executeTextReplace(
        ctx.allocator,
        ctx.io,
        parsed.value.path,
        parsed.value.old_str,
        parsed.value.new_str,
    ) catch |err| {
        const inner = text_replace_mod.toXmlError(
            ctx.allocator,
            err,
            parsed.value.path,
            parsed.value.old_str,
        );
        const err_msg = try std.fmt.allocPrint(ctx.allocator, "text_replace failed: {s}", .{@errorName(err)});
        const output = try wrapToolOutput(ctx.allocator, "text_replace", tc.function.arguments, false, err_msg, inner);
        return ToolExecResult{ .output = output, .output_allocated = true };
    };

    const inner = text_replace_mod.toXmlSuccess(ctx.allocator, result, parsed.value.path);
    const output = try wrapToolOutput(ctx.allocator, "text_replace", tc.function.arguments, true, null, inner);
    return ToolExecResult{ .output = output, .output_allocated = true };
}