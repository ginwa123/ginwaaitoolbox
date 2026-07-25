const std = @import("std");
const mod = @import("mod.zig");
const nalarcore = mod.nalarcore;
const tools = mod.tools;
const ToolExecContext = tools.ToolExecContext;
const ToolExecResult = tools.ToolExecResult;
const agent = nalarcore.agent;
const show_preview_mod = nalarcore.ai_mod.show_preview;
const wrapToolOutput = tools.wrapToolOutput;

pub fn execShowPreview(ctx: ToolExecContext, tc: agent.ToolCall) !ToolExecResult {
    const parsed = std.json.parseFromSlice(
        show_preview_mod.ShowPreviewInput,
        ctx.allocator,
        tc.function.arguments,
        .{ .allocate = .alloc_always, .ignore_unknown_fields = true },
    ) catch |err| {
        const err_msg = try std.fmt.allocPrint(ctx.allocator, "show_preview failed to parse input: {s}", .{@errorName(err)});
        const output = try wrapToolOutput(ctx.allocator, "show_preview", tc.function.arguments, false, err_msg, "");
        return ToolExecResult{ .output = output, .output_allocated = true };
    };
    defer parsed.deinit();

    // executeShowPreviewToString always allocates a preview_id (even on
    // validation failure) and writes it to `out_preview_id.*`. We provide
    // an uninitialized []u8 and take ownership of the allocation after
    // the call returns.
    var preview_id: []u8 = undefined;

    // executeShowPreviewToString returns an XML string. Errors
    // (invalid content_type, content too large, missing language for
    // code, OOM during sanitization) are encoded as
    // <show_preview><error>...</error></show_preview> so the LLM
    // sees a structured failure rather than a tool crash.
    const inner = show_preview_mod.executeShowPreviewToString(
        ctx.allocator,
        ctx.io,
        parsed.value,
        &preview_id,
    ) catch |err| {
        const err_msg = try std.fmt.allocPrint(ctx.allocator, "show_preview failed: {s}", .{@errorName(err)});
        const output = try wrapToolOutput(ctx.allocator, "show_preview", tc.function.arguments, false, err_msg, "");
        return ToolExecResult{ .output = output, .output_allocated = true };
    };
    defer ctx.allocator.free(inner);
    defer ctx.allocator.free(preview_id);

    // Detect the <show_preview><error>...</error></show_preview> shape
    // and surface it as a tool failure (so the LLM sees
    // `success=false` rather than a successful wrapper around an
    // error body). The inner envelope is still passed through as
    // `data` so the LLM can read the full diagnostic.
    if (std.mem.indexOf(u8, inner, "<error>") != null) {
        const err_start = (std.mem.indexOf(u8, inner, "<error>") orelse 0) + "<error>".len;
        const err_end = std.mem.indexOf(u8, inner[err_start..], "</error>") orelse inner.len;
        const err_msg = inner[err_start .. err_start + err_end];
        const output = try wrapToolOutput(ctx.allocator, "show_preview", tc.function.arguments, false, err_msg, inner);
        return ToolExecResult{ .output = output, .output_allocated = true };
    }

    const output = try wrapToolOutput(ctx.allocator, "show_preview", tc.function.arguments, true, null, inner);
    return ToolExecResult{ .output = output, .output_allocated = true };
}