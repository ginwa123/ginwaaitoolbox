const std = @import("std");
const nalarcore = @import("nalarcore");
const tools = @import("tools.zig");

const ToolExecContext = tools.ToolExecContext;
const ToolExecResult = tools.ToolExecResult;
const agent = nalarcore.agent;
const glob_tool_mod = nalarcore.glob_tool;
const wrapToolOutput = tools.wrapToolOutput;

pub fn execGlob(ctx: ToolExecContext, tc: agent.ToolCall) !ToolExecResult {
    const args = tc.function.arguments;
    const args_to_parse: []const u8 = if (args.len == 0) "{}" else args;

    const parsed = std.json.parseFromSlice(
        glob_tool_mod.GlobInput,
        ctx.allocator,
        args_to_parse,
        .{ .allocate = .alloc_always, .ignore_unknown_fields = true },
    ) catch |err| {
        const err_msg = try std.fmt.allocPrint(ctx.allocator, "glob failed: {s}", .{@errorName(err)});
        const output = try wrapToolOutput(ctx.allocator, "glob", tc.function.arguments, false, err_msg, "");
        return ToolExecResult{ .output = output, .output_allocated = true };
    };
    defer parsed.deinit();

    // Security: reject absolute paths.
    if (try nalarcore.path_security.rejectAbsolutePath(
        ctx.allocator, "glob", "path", parsed.value.path, ctx.cwd
    )) |err_msg| {
        defer ctx.allocator.free(err_msg);
        const output = try wrapToolOutput(ctx.allocator, "glob", tc.function.arguments, false, err_msg, "");
        return ToolExecResult{ .output = output, .output_allocated = true };
    }

    var glob_result = glob_tool_mod.executeGlob(ctx.allocator, ctx.io, parsed.value) catch |err| {
        // Map the new domain errors to LLM-friendly messages. Each one
        // names the fix the LLM can try (different pattern, narrower
        // path, smaller max_results, etc).
        const err_msg: []const u8 = blk: {
            switch (err) {
                error.EmptyPattern => break :blk "glob pattern was empty — pass a non-empty pattern (this is a caller bug, not 'no match')",
                error.WhitespaceOnlyPattern => break :blk "glob pattern contained only whitespace characters — pass a real pattern (this is a caller bug, not 'no match')",
                error.PatternContainsNulByte => break :blk "glob pattern contained a NUL (0x00) byte — patterns must be valid UTF-8 with no embedded NULs",
                error.PathDoesNotExist => break :blk "glob path does not exist or is not a directory — verify the path exists and points to a directory (not a file)",
                error.InvalidFileType => break :blk "glob file_type must be 'f', 'file', 'd', or 'directory' (or omitted for all types)",
                error.InvalidMaxResults => break :blk "glob max_results must be > 0 (omit the field or use a positive integer; the default is 100)",
                error.InvalidBraceExpansion => break :blk "glob pattern has unmatched braces ('{' without '}') — fix the brace expansion syntax",
                else => {},
            }
            // Fall-through for unrecognised errors: build the allocPrint
            // result and break with that.
            const msg = std.fmt.allocPrint(ctx.allocator, "glob failed: {s}", .{@errorName(err)}) catch "glob failed with an unknown error";
            break :blk msg;
        };
        const output = try wrapToolOutput(ctx.allocator, "glob", tc.function.arguments, false, err_msg, "");
        return ToolExecResult{ .output = output, .output_allocated = true };
    };

    const inner = try glob_tool_mod.toXmlSuccess(ctx.allocator, glob_result, parsed.value.pattern);
    glob_result.deinit(ctx.allocator);
    const output = try wrapToolOutput(ctx.allocator, "glob", tc.function.arguments, true, null, inner);
    return ToolExecResult{ .output = output, .output_allocated = true };
}