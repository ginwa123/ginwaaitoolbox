const std = @import("std");
const http_response = @import("http_response.zig");
const nalarcore = @import("nalarcore");
const gserverz = nalarcore.gserverz;

/// HTTP handler: POST /api/workspaces/:workspace_id/items/:item_id/tasks/reorder_pinned
///
/// Body: { "ordered_ids": ["id1", "id2", ..., "idN"] } (top-to-bottom
/// display order of the pinned subset).
///
/// Behavior: assigns `pinned_position = N-1 - i` to the i-th id.
/// The list lister's `ORDER BY is_pinned DESC, pinned_position DESC,
/// id DESC` then renders them in the user's chosen order. Rows that
/// aren't currently pinned (is_pinned=0) or that belong to a
/// different workspace_item are silently skipped (defense in depth,
/// consistent with the workspace reorder endpoints).
///
/// Idempotent: a second call with the same array leaves the data
/// unchanged (positions are recomputed but the final state is the
/// same).
///
/// Errors:
///   400 — invalid body, missing ordered_ids, wrong type
///   500 — DB write failed
pub fn tasksReorderPinnedHandler(
    ctx: gserverz.HttpContext,
    req: gserverz.HttpRequest,
    res: gserverz.HttpResponse,
) !gserverz.HttpResponse {
    const allocator = ctx.allocator;

    const item_id = req.params.get("item_id") orelse "";
    if (item_id.len == 0) {
        return res.jsonResponse(.{ .status_code = 400, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "item_id required" }) });
    }

    const body = req.body;
    if (body.len == 0) {
        return res.jsonResponse(.{ .status_code = 400, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "body required" }) });
    }

    const parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch {
        return res.jsonResponse(.{ .status_code = 400, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Invalid JSON" }) });
    };
    defer parsed.deinit();

    const root = parsed.value.object;
    const ordered_ids_val = root.get("ordered_ids") orelse {
        return res.jsonResponse(.{ .status_code = 400, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "ordered_ids required" }) });
    };
    if (ordered_ids_val != .array) {
        return res.jsonResponse(.{ .status_code = 400, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "ordered_ids must be an array" }) });
    }

    var ids = std.ArrayList([]const u8).empty;
    defer ids.deinit(allocator);
    for (ordered_ids_val.array.items) |item| {
        if (item == .string) try ids.append(allocator, item.string);
    }

    const di = try nalarcore.getSingleton();
    nalarcore.ai_mod.workspace_item_tasks.reorderPinnedTasks(allocator, di.db, item_id, ids.items) catch {
        return res.jsonResponse(.{ .status_code = 500, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Failed to reorder pinned tasks" }) });
    };

    return res.jsonResponse(.{ .status_code = 200, .data = try http_response.makeTasksReorderPinnedResponse(allocator, ids.items.len) });
}
