const std = @import("std");
const nalarcore = @import("nalarcore");
const tools = @import("tools.zig");

const ToolExecContext = tools.ToolExecContext;
const ToolExecResult = tools.ToolExecResult;
const agent = nalarcore.agent;
const write_file_mod = nalarcore.write_file;
const wrapToolOutput = tools.wrapToolOutput;

pub fn execWriteFile(ctx: ToolExecContext, tc: agent.ToolCall) !ToolExecResult {
    const parsed = std.json.parseFromSlice(
        write_file_mod.WriteFileInput,
        ctx.allocator,
        tc.function.arguments,
        .{ .allocate = .alloc_always },
    ) catch |err| {
        const err_msg = try std.fmt.allocPrint(ctx.allocator, "write_file failed: {s}", .{@errorName(err)});
        const output = try wrapToolOutput(ctx.allocator, "write_file", tc.function.arguments, false, err_msg, "");
        return ToolExecResult{ .output = output, .output_allocated = true };
    };
    defer parsed.deinit();

    const write_result = write_file_mod.writeFile(ctx.allocator, ctx.io, parsed.value) catch |err| {
        const inner = write_file_mod.toXmlError(ctx.allocator, err, parsed.value.path);
        const err_msg = try std.fmt.allocPrint(ctx.allocator, "write_file failed: {s}", .{@errorName(err)});
        const output = try wrapToolOutput(ctx.allocator, "write_file", tc.function.arguments, false, err_msg, inner);
        return ToolExecResult{ .output = output, .output_allocated = true };
    };
    const inner = write_file_mod.toXmlSuccess(ctx.allocator, write_result);
    write_result.deinit(ctx.allocator);
    const output = try wrapToolOutput(ctx.allocator, "write_file", tc.function.arguments, true, null, inner);
    return ToolExecResult{ .output = output, .output_allocated = true };
}