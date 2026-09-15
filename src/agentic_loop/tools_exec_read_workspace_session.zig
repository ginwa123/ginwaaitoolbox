const std = @import("std");
const nalarcore = @import("nalarcore");
const tools = @import("tools.zig");

const ToolExecContext = tools.ToolExecContext;
const ToolExecResult = tools.ToolExecResult;
const agent = nalarcore.agent;
const read_workspace_session_mod = nalarcore.read_workspace_session_tool;
const wrapToolOutput = tools.wrapToolOutput;

pub fn execReadWorkspaceSession(ctx: ToolExecContext, tc: agent.ToolCall) !ToolExecResult {
    const parsed = std.json.parseFromSlice(
        read_workspace_session_mod.ReadWorkspaceSessionInput,
        ctx.allocator,
        tc.function.arguments,
        .{ .allocate = .alloc_always, .ignore_unknown_fields = true },
    ) catch |err| {
        const err_msg = try std.fmt.allocPrint(ctx.allocator, "read_workspace_session failed: {s}", .{@errorName(err)});
        const output = try wrapToolOutput(ctx.allocator, "read_workspace_session", tc.function.arguments, false, err_msg, "");
        return ToolExecResult{ .output = output, .output_allocated = true };
    };
    defer parsed.deinit();

    // Workspace scope is derived server-side from the calling session —
    // the LLM never supplies (or spoofs) a workspace id.
    const inner = read_workspace_session_mod.execute_read_workspace_session(
        ctx.allocator,
        ctx.io,
        ctx.db,
        ctx.session_id,
        parsed.value,
    ) catch |err| {
        const err_msg = try std.fmt.allocPrint(ctx.allocator, "read_workspace_session failed: {s}", .{@errorName(err)});
        const output = try wrapToolOutput(ctx.allocator, "read_workspace_session", tc.function.arguments, false, err_msg, "");
        return ToolExecResult{ .output = output, .output_allocated = true };
    };

    const output = try wrapToolOutput(ctx.allocator, "read_workspace_session", tc.function.arguments, true, null, inner);
    return ToolExecResult{ .output = output, .output_allocated = true };
}
