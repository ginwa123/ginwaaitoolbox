const std = @import("std");
const http_response = @import("http_response.zig");
const nalarcore = @import("nalarcore");
const gserverz = nalarcore.gserverz;

/// HTTP handler: POST /api/workspaces/:workspace_id/items/:item_id/tasks/:task_id/pin
///
/// Body: { "is_pinned": true | false }
///
/// Behavior: flips the `is_pinned` flag on the row. When pinning
/// (true), the row's `pinned_position` is bumped to
/// MAX(pinned_position WHERE is_pinned=1) + 1 so it lands at the
/// BOTTOM of the pinned region. When unpinning (false), the row's
/// `pinned_position` is reset to 0.
///
/// Idempotent: pinning an already-pinned row is a no-op for the
/// position bump (MAX still includes the row's own value, so the
/// new position equals the current one). Unpinning an
/// already-unpinned row is also a no-op.
///
/// Errors:
///   400 — invalid body, missing is_pinned, wrong type
///   404 — task not found (only fired by the inner MAX subquery
///         when the row's id doesn't exist)
///   500 — DB write failed
pub fn taskPinHandler(
    ctx: gserverz.HttpContext,
    req: gserverz.HttpRequest,
    res: gserverz.HttpResponse,
) !gserverz.HttpResponse {
    const allocator = ctx.allocator;

    const task_id = req.params.get("task_id") orelse "";
    if (task_id.len == 0) {
        return res.jsonResponse(.{ .status_code = 400, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "task_id required" }) });
    }

    const body = req.body;
    if (body.len == 0) {
        return res.jsonResponse(.{ .status_code = 400, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "body required" }) });
    }

    const parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch {
        return res.jsonResponse(.{ .status_code = 400, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Invalid JSON" }) });
    };
    defer parsed.deinit();

    const is_pinned_val = parsed.value.object.get("is_pinned") orelse {
        return res.jsonResponse(.{ .status_code = 400, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "is_pinned required" }) });
    };
    if (is_pinned_val != .bool) {
        return res.jsonResponse(.{ .status_code = 400, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "is_pinned must be a boolean" }) });
    }
    const is_pinned = is_pinned_val.bool;

    const di = try nalarcore.getSingleton();
    const new_pos = nalarcore.ai_mod.workspace_item_tasks.setTaskPinned(allocator, di.db, task_id, is_pinned) catch |err| switch (err) {
        error.TaskNotFound => return res.jsonResponse(.{ .status_code = 404, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Task not found" }) }),
        else => return res.jsonResponse(.{ .status_code = 500, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Failed to update task pin" }) }),
    };

    return res.jsonResponse(.{ .status_code = 200, .data = try http_response.makeTaskPinResponse(allocator, task_id, is_pinned, new_pos) });
}
