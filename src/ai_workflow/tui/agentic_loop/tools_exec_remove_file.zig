const std = @import("std");
const nalarcore = @import("nalarcore");
const tools = @import("tools.zig");

const ToolExecContext = tools.ToolExecContext;
const ToolExecResult = tools.ToolExecResult;
const agent = nalarcore.agent;
const remove_file_mod = nalarcore.remove_file;
const wrapToolOutput = tools.wrapToolOutput;

pub fn execRemoveFile(ctx: ToolExecContext, tc: agent.ToolCall) !ToolExecResult {
    const parsed = std.json.parseFromSlice(
        remove_file_mod.RemoveFileInput,
        ctx.allocator,
        tc.function.arguments,
        .{ .allocate = .alloc_always },
    ) catch |err| {
        const err_msg = try std.fmt.allocPrint(ctx.allocator, "remove_file failed: {s}", .{@errorName(err)});
        const output = try wrapToolOutput(ctx.allocator, "remove_file", tc.function.arguments, false, err_msg, "");
        return ToolExecResult{ .output = output, .output_allocated = true };
    };
    defer parsed.deinit();

    // Security: reject absolute paths.
    if (try nalarcore.path_security.rejectAbsolutePath(
        ctx.allocator, "remove_file", "path", parsed.value.path, ctx.cwd
    )) |err_msg| {
        defer ctx.allocator.free(err_msg);
        const output = try wrapToolOutput(ctx.allocator, "remove_file", tc.function.arguments, false, err_msg, "");
        return ToolExecResult{ .output = output, .output_allocated = true };
    }

    const inner = remove_file_mod.executeRemoveFileToString(ctx.allocator, ctx.io, parsed.value) catch |err| {
        const err_msg = try std.fmt.allocPrint(ctx.allocator, "remove_file failed: {s}", .{@errorName(err)});
        const output = try wrapToolOutput(ctx.allocator, "remove_file", tc.function.arguments, false, err_msg, "");
        return ToolExecResult{ .output = output, .output_allocated = true };
    };

    if (std.mem.indexOf(u8, inner, "<error>") != null) {
        const err_start = (std.mem.indexOf(u8, inner, "<error>") orelse 0) + "<error>".len;
        const err_end = std.mem.indexOf(u8, inner[err_start..], "</error>") orelse inner.len;
        const err_msg = inner[err_start .. err_start + err_end];
        const output = try wrapToolOutput(ctx.allocator, "remove_file", tc.function.arguments, false, err_msg, "");
        return ToolExecResult{ .output = output, .output_allocated = true };
    }

    const output = try wrapToolOutput(ctx.allocator, "remove_file", tc.function.arguments, true, null, inner);
    return ToolExecResult{ .output = output, .output_allocated = true };
}