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

    // executePresentFilesToString returns an XML string. Validation
    // failures (missing file, relative path, too many files) are
    // encoded as <present_files><error>...</error></present_files> so
    // the LLM sees a structured failure rather than a tool crash.
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

    // Detect the <present_files><error>...</error></present_files> shape
    // and surface it as a tool failure (so the LLM sees
    // `success=false` rather than a successful wrapper around an
    // error body). The inner envelope is still passed through as
    // `data` so the LLM can read the full diagnostic.
    if (std.mem.indexOf(u8, inner, "<error>") != null) {
        const err_start = (std.mem.indexOf(u8, inner, "<error>") orelse 0) + "<error>".len;
        const err_end = std.mem.indexOf(u8, inner[err_start..], "</error>") orelse (inner.len - err_start);
        const err_msg = inner[err_start .. err_start + err_end];
        const output = try wrapToolOutput(ctx.allocator, "present_files", tc.function.arguments, false, err_msg, inner);
        return ToolExecResult{ .output = output, .output_allocated = true };
    }

    const output = try wrapToolOutput(ctx.allocator, "present_files", tc.function.arguments, true, null, inner);
    return ToolExecResult{ .output = output, .output_allocated = true };
}
