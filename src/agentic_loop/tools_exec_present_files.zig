const std = @import("std");
const nalarcore = @import("nalarcore");
const tools = @import("tools.zig");

const ToolExecContext = tools.ToolExecContext;
const ToolExecResult = tools.ToolExecResult;
const agent = nalarcore.agent;
const present_files_mod = nalarcore.ai_mod.present_files;
const wrapToolOutput = tools.wrapToolOutput;

pub fn execPresentFiles(ctx: ToolExecContext, tc: agent.ToolCall) !ToolExecResult {
    const parsed = std.json.parseFromSlice(
        present_files_mod.PresentFilesInput,
        ctx.allocator,
        tc.function.arguments,
        .{ .allocate = .alloc_always, .ignore_unknown_fields = true },
    ) catch |err| {
        const err_msg = try std.fmt.allocPrint(ctx.allocator, "present_files failed to parse input: {s}", .{@errorName(err)});
        const output = try wrapToolOutput(ctx.allocator, "present_files", tc.function.arguments, false, err_msg, "");
        return ToolExecResult{ .output = output, .output_allocated = true };
    };
    defer parsed.deinit();

    // executePresentFilesToString returns a JSON string. Validation
    // failures (missing file, relative path, too many files) are
    // encoded as {"status":null,"error":...} so the LLM sees a
    // structured failure rather than a tool crash.
    const inner = present_files_mod.executePresentFilesToString(
        ctx.allocator,
        ctx.io,
        parsed.value,
    ) catch |err| {
        const err_msg = try std.fmt.allocPrint(ctx.allocator, "present_files failed: {s}", .{@errorName(err)});
        const output = try wrapToolOutput(ctx.allocator, "present_files", tc.function.arguments, false, err_msg, "");
        return ToolExecResult{ .output = output, .output_allocated = true };
    };
    defer ctx.allocator.free(inner);

    // Detect the {"status":null,"error":...} shape and surface it as a
    // tool failure (so the LLM sees `success=false` rather than a
    // successful wrapper around an error body). The inner object is
    // still passed through as `data` so the LLM can read the full
    // diagnostic.
    const inner_failed: bool = blk: {
        const parsed_inner = std.json.parseFromSlice(std.json.Value, ctx.allocator, inner, .{}) catch break :blk true;
        defer parsed_inner.deinit();
        if (parsed_inner.value != .object) break :blk true;
        const status = parsed_inner.value.object.get("status") orelse break :blk true;
        if (status != .string) break :blk true;
        break :blk !std.mem.eql(u8, status.string, "presented");
    };
    if (inner_failed) {
        const err_msg: []const u8 = blk: {
            const parsed_inner = std.json.parseFromSlice(std.json.Value, ctx.allocator, inner, .{}) catch break :blk inner;
            defer parsed_inner.deinit();
            if (parsed_inner.value != .object) break :blk inner;
            const e = parsed_inner.value.object.get("error") orelse break :blk inner;
            if (e != .string) break :blk inner;
            break :blk e.string;
        };
        const output = try wrapToolOutput(ctx.allocator, "present_files", tc.function.arguments, false, err_msg, inner);
        return ToolExecResult{ .output = output, .output_allocated = true };
    }

    const output = try wrapToolOutput(ctx.allocator, "present_files", tc.function.arguments, true, null, inner);
    return ToolExecResult{ .output = output, .output_allocated = true };
}
