const std = @import("std");
const mod = @import("mod.zig");
const nalarcore = mod.nalarcore;
const tools = mod.tools;
const ToolExecContext = tools.ToolExecContext;
const ToolExecResult = tools.ToolExecResult;
const agent = nalarcore.agent;
const ReadFileInput = nalarcore.tool_models.ReadFileInput;
const ReadFileOptions = nalarcore.read_file.ReadFileOptions;
const readFile = nalarcore.read_file.readFile;
const toXMLSuccess = nalarcore.read_file.toXMLSuccess;
const wrapToolOutput = tools.wrapToolOutput;

pub fn execReadFile(ctx: ToolExecContext, tc: agent.ToolCall) !ToolExecResult {
    _ = ctx.db;
    _ = ctx.session_id;

    // Parse arguments JSON to ReadFileInput
    const parsed = std.json.parseFromSlice(
        ReadFileInput,
        ctx.allocator,
        tc.function.arguments,
        .{ .allocate = .alloc_always },
    ) catch |err| {
        const err_msg = try std.fmt.allocPrint(ctx.allocator, "read_file failed: {s}", .{@errorName(err)});
        const output = try wrapToolOutput(ctx.allocator, "read_file", tc.function.arguments, false, err_msg, "");
        return ToolExecResult{ .output = output, .output_allocated = true };
    };
    defer parsed.deinit();

    const read_opts = ReadFileOptions{
        .offset = parsed.value.offset,
        .limit = parsed.value.limit,
    };

    const read_result = readFile(ctx.allocator, ctx.io, parsed.value.path, read_opts) catch |err| {
        const err_msg = try std.fmt.allocPrint(ctx.allocator, "read_file failed: {s}", .{@errorName(err)});
        const output = try wrapToolOutput(ctx.allocator, "read_file", tc.function.arguments, false, err_msg, "");
        return ToolExecResult{ .output = output, .output_allocated = true };
    };
    defer read_result.deinit(ctx.allocator);

    // Single allocation: combines path and content into XML result
    const inner = try toXMLSuccess(ctx.allocator, read_result, parsed.value.path);
    const output = try wrapToolOutput(ctx.allocator, "read_file", tc.function.arguments, true, null, inner);
    return ToolExecResult{ .output = output, .output_allocated = true };
}
