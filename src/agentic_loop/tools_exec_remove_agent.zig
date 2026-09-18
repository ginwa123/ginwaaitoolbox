const std = @import("std");
const nalarcore = @import("nalarcore");
const tools = @import("tools.zig");

const ToolExecContext = tools.ToolExecContext;
const ToolExecResult = tools.ToolExecResult;
const agent = nalarcore.agent;
const remove_agent_mod = nalarcore.remove_agent;
const wrapToolOutput = tools.wrapToolOutput;

pub fn execRemoveAgent(ctx: ToolExecContext, tc: agent.ToolCall) !ToolExecResult {
    const parsed = std.json.parseFromSlice(
        remove_agent_mod.RemoveAgentInput,
        ctx.allocator,
        tc.function.arguments,
        .{ .allocate = .alloc_always },
    ) catch |err| {
        const err_msg = try std.fmt.allocPrint(ctx.allocator, "remove_agent failed: {s}", .{@errorName(err)});
        const output = try wrapToolOutput(ctx.allocator, "remove_agent", tc.function.arguments, false, err_msg, "");
        return ToolExecResult{ .output = output, .output_allocated = true };
    };
    defer parsed.deinit();

    const inner = remove_agent_mod.execute_remove_agent_to_json(ctx.allocator, ctx.io, parsed.value) catch |err| {
        const err_msg = try std.fmt.allocPrint(ctx.allocator, "remove_agent failed: {s}", .{@errorName(err)});
        const output = try wrapToolOutput(ctx.allocator, "remove_agent", tc.function.arguments, false, err_msg, "");
        return ToolExecResult{ .output = output, .output_allocated = true };
    };

    const parsed_inner = std.json.parseFromSlice(std.json.Value, ctx.allocator, inner, .{}) catch |err| {
        const err_msg = try std.fmt.allocPrint(ctx.allocator, "remove_agent failed: {s}", .{@errorName(err)});
        const output = try wrapToolOutput(ctx.allocator, "remove_agent", tc.function.arguments, false, err_msg, "");
        return ToolExecResult{ .output = output, .output_allocated = true };
    };
    defer parsed_inner.deinit();
    if (parsed_inner.value == .object) {
        if (parsed_inner.value.object.get("error")) |err_val| {
            if (err_val != .null) {
                const err_msg = if (err_val == .string) err_val.string else "remove_agent failed";
                const output = try wrapToolOutput(ctx.allocator, "remove_agent", tc.function.arguments, false, err_msg, "");
                return ToolExecResult{ .output = output, .output_allocated = true };
            }
        }
    }

    const output = try wrapToolOutput(ctx.allocator, "remove_agent", tc.function.arguments, true, null, inner);
    return ToolExecResult{ .output = output, .output_allocated = true };
}
