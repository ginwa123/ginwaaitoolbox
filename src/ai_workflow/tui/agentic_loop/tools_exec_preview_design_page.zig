const std = @import("std");
const mod = @import("mod.zig");
const nalarcore = mod.nalarcore;
const tools = mod.tools;
const ToolExecContext = tools.ToolExecContext;
const ToolExecResult = tools.ToolExecResult;
const agent = nalarcore.agent;
const preview_design_page_mod = nalarcore.preview_design_page;
const wrapToolOutput = tools.wrapToolOutput;

pub fn execPreviewDesignPage(ctx: ToolExecContext, tc: agent.ToolCall) !ToolExecResult {
    const parsed = std.json.parseFromSlice(
        preview_design_page_mod.PreviewDesignPageInput,
        ctx.allocator,
        tc.function.arguments,
        .{ .allocate = .alloc_always, .ignore_unknown_fields = true },
    ) catch |err| {
        const err_msg = try std.fmt.allocPrint(ctx.allocator, "preview_design_page failed to parse input: {s}", .{@errorName(err)});
        const output = try wrapToolOutput(ctx.allocator, "preview_design_page", tc.function.arguments, false, err_msg, "");
        return ToolExecResult{ .output = output, .output_allocated = true };
    };
    defer parsed.deinit();

    // The preview id is always allocated, even on validation failure, so
    // the caller can log the failed attempt with the correlation id.
    var preview_id: []u8 = undefined;

    const inner = preview_design_page_mod.executePreviewDesignPageToString(
        ctx.allocator,
        ctx.io,
        ctx.db,
        parsed.value,
        &preview_id,
    ) catch |err| {
        const err_msg = try std.fmt.allocPrint(ctx.allocator, "preview_design_page failed: {s}", .{@errorName(err)});
        const output = try wrapToolOutput(ctx.allocator, "preview_design_page", tc.function.arguments, false, err_msg, "");
        return ToolExecResult{ .output = output, .output_allocated = true };
    };
    defer ctx.allocator.free(inner);
    defer ctx.allocator.free(preview_id);

    // Detect <show_preview><error>...</error></show_preview> and surface as
    // a tool failure.
    if (std.mem.indexOf(u8, inner, "<error>") != null) {
        const err_start = (std.mem.indexOf(u8, inner, "<error>") orelse 0) + "<error>".len;
        const err_end = std.mem.indexOf(u8, inner[err_start..], "</error>") orelse inner.len;
        const err_msg = inner[err_start .. err_start + err_end];
        const output = try wrapToolOutput(ctx.allocator, "preview_design_page", tc.function.arguments, false, err_msg, inner);
        return ToolExecResult{ .output = output, .output_allocated = true };
    }

    const output = try wrapToolOutput(ctx.allocator, "preview_design_page", tc.function.arguments, true, null, inner);
    return ToolExecResult{ .output = output, .output_allocated = true };
}