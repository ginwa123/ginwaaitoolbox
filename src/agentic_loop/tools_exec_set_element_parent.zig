const std = @import("std");
const nalarcore = @import("nalarcore");
const tools = @import("tools.zig");

const ToolExecContext = tools.ToolExecContext;
const ToolExecResult = tools.ToolExecResult;
const agent = nalarcore.agent;
const set_element_parent_mod = nalarcore.set_element_parent;
const wrapToolOutput = tools.wrapToolOutput;

pub fn execSetElementParent(ctx: ToolExecContext, tc: agent.ToolCall) !ToolExecResult {
    const parsed = std.json.parseFromSlice(
        set_element_parent_mod.SetElementParentInput,
        ctx.allocator,
        tc.function.arguments,
        .{ .allocate = .alloc_always, .ignore_unknown_fields = true },
    ) catch |err| {
        const err_msg = try std.fmt.allocPrint(ctx.allocator, "set_element_parent failed to parse input: {s}", .{@errorName(err)});
        const output = try wrapToolOutput(ctx.allocator, "set_element_parent", tc.function.arguments, false, err_msg, "");
        return ToolExecResult{ .output = output, .output_allocated = true };
    };
    defer parsed.deinit();

    // set_element_parent doesn't need Io (no disk writes).
    const inner = set_element_parent_mod.executeSetElementParentToString(
        ctx.allocator,
        ctx.db,
        parsed.value,
    ) catch |err| {
        const err_msg = try std.fmt.allocPrint(ctx.allocator, "set_element_parent failed: {s}", .{@errorName(err)});
        const output = try wrapToolOutput(ctx.allocator, "set_element_parent", tc.function.arguments, false, err_msg, "");
        return ToolExecResult{ .output = output, .output_allocated = true };
    };
    defer ctx.allocator.free(inner);

    // Detect <set_element_parent><error>...</error></set_element_parent> and
    // surface it as a tool failure.
    if (std.mem.indexOf(u8, inner, "<error>") != null) {
        const err_start = (std.mem.indexOf(u8, inner, "<error>") orelse 0) + "<error>".len;
        const err_end = std.mem.indexOf(u8, inner[err_start..], "</error>") orelse (inner.len - err_start);
        const err_msg = inner[err_start .. err_start + err_end];
        const output = try wrapToolOutput(ctx.allocator, "set_element_parent", tc.function.arguments, false, err_msg, inner);
        return ToolExecResult{ .output = output, .output_allocated = true };
    }

    const output = try wrapToolOutput(ctx.allocator, "set_element_parent", tc.function.arguments, true, null, inner);
    return ToolExecResult{ .output = output, .output_allocated = true };
}