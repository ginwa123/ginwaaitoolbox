const std = @import("std");
const pabrikcore = @import("pabrikcore");
const tools = @import("tools.zig");

const ToolExecContext = tools.ToolExecContext;
const ToolExecResult = tools.ToolExecResult;
const agent = pabrikcore.agent;
const ReadFileInput = pabrikcore.tool_models.ReadFileInput;
const ReadFileOptions = pabrikcore.read_file.ReadFileOptions;
const readFile = pabrikcore.read_file.readFile;
const toJSONSuccess = pabrikcore.read_file.toJSONSuccess;
const wrapToolOutput = tools.wrapToolOutput;
const error_explain = @import("tools_error_explain.zig");

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
        const err_msg = try error_explain.explain(ctx.allocator, err, null);
        defer ctx.allocator.free(err_msg);
        const output = try wrapToolOutput(ctx.allocator, "read_file", tc.function.arguments, false, err_msg, "");
        return ToolExecResult{ .output = output, .output_allocated = true };
    };
    defer parsed.deinit();

    const read_opts = ReadFileOptions{
        .offset = parsed.value.offset,
        .limit = parsed.value.limit,
    };

    const read_result = readFile(ctx.allocator, ctx.io, parsed.value.path, read_opts) catch |err| {
        // The path is the one thing the model can act on here, so it is
        // passed as the explanation's context.
        const err_msg = try error_explain.explain(ctx.allocator, err, parsed.value.path);
        defer ctx.allocator.free(err_msg);
        const output = try wrapToolOutput(ctx.allocator, "read_file", tc.function.arguments, false, err_msg, "");
        return ToolExecResult{ .output = output, .output_allocated = true };
    };
    defer read_result.deinit(ctx.allocator);

    // Single allocation: combines path and content into the JSON result
    const inner = try toJSONSuccess(ctx.allocator, read_result, parsed.value.path);
    const output = try wrapToolOutput(ctx.allocator, "read_file", tc.function.arguments, true, null, inner);
    return ToolExecResult{ .output = output, .output_allocated = true };
}
