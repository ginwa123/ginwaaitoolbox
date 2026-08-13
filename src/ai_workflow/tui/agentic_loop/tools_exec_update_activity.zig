const std = @import("std");
const nalarcore = @import("nalarcore");
const tools = @import("tools.zig");

const ToolExecContext = tools.ToolExecContext;
const ToolExecResult = tools.ToolExecResult;
const agent = nalarcore.agent;
const llm_history = nalarcore.llm_history;
const update_activity_mod = nalarcore.update_activity;
const wrapToolOutput = tools.wrapToolOutput;

// update_activity implementation - records thought as worker activity
pub fn execUpdateActivity(ctx: ToolExecContext, tc: agent.ToolCall) !ToolExecResult {
    ctx.logger.debugFmt("[update_activity] Starting for session {s}", .{ctx.session_id});

    const parsed = try std.json.parseFromSlice(
        update_activity_mod.UpdateActivityInput,
        ctx.allocator,
        tc.function.arguments,
        .{ .allocate = .alloc_always },
    );
    defer parsed.deinit();

    // Use session_id directly as worker_id (matches how worker is registered)
    const worker_id = try ctx.allocator.dupe(u8, ctx.session_id);
    defer ctx.allocator.free(worker_id);

    // Update worker activity with the thought
    if (llm_history.updateWorkerActivityWithDescription(ctx.allocator, ctx.db, worker_id, parsed.value.thought)) |_| {
        ctx.logger.infoFmt("[update_activity] Updated activity for {s}: {s}", .{ worker_id, parsed.value.thought });

        // Also append to the per-session session_activity log (Migration 073).
        // Best-effort: if the INSERT fails (table missing on a pre-073 DB,
        // disk full, etc.) the agent tool call still succeeds — the live
        // worker.last_activity_description update is the load-bearing UI
        // signal, this log is historical/nice-to-have. Matches the SSE
        // `catch {}` pattern in `updateWorkerActivityWithDescription`.
        llm_history.recordSessionActivity(ctx.allocator, ctx.io, ctx.db, ctx.session_id, parsed.value.thought) catch |err| {
            ctx.logger.warnFmt("[update_activity] Failed to record session_activity row for {s}: {}", .{ ctx.session_id, err });
        };

        const inner = update_activity_mod.xmlSuccess(ctx.allocator, parsed.value.thought);
        const output = try wrapToolOutput(ctx.allocator, "update_activity", tc.function.arguments, true, null, inner);
        return ToolExecResult{ .output = output, .output_allocated = true };
    } else |err| {
        ctx.logger.errFmt("[update_activity] Failed to update worker activity for {s}: {}", .{ worker_id, err });
        const inner = update_activity_mod.xmlError(ctx.allocator, "Failed to update worker activity");
        const err_msg = "Failed to update worker activity";
        const output = try wrapToolOutput(ctx.allocator, "update_activity", tc.function.arguments, false, err_msg, inner);
        return ToolExecResult{ .output = output, .output_allocated = true };
    }
}