//! PATCH /api/workspaces/:workspace_id/items/:item_id/tasks/:task_id/move
//!
//! Move a task to a different kanban column (and/or reorder within its
//! column). Thin wrapper around `kanban_model.moveTask`.
//!
//! Body: `{column_id, position}` — both required. The frontend fires
//! this from the drag-and-drop handler after a card is dropped on a
//! different column (or a different slot within the same column).
//!
//! Response shape: `{"success": true}` — the frontend re-fetches the
//! board via `GET /kanban/columns` after the move to refresh positions.
//!
//! Errors:
//!   - 400 missing/invalid JSON body, missing/empty column_id or
//!     task_id or item_id
//!   - 500 DB failure
//!
//! Plan: docs/superpowers/plans/2026-06-21-workspace-item-kanban.md
//!   (Chunk 3, Task 3.7)

const std = @import("std");
const nalarcore = @import("nalarcore");
const gserverz = nalarcore.gserverz;
const http_response = @import("http_response.zig");
const kanban_model = @import("../kanban_model.zig");
const on_event_sent_kanban = nalarcore.ai_mod.on_event_sent_kanban;

/// Request body for task-move.
const MoveTaskBody = struct {
    column_id: []const u8,
    position: i64,
};

/// Response shape for task-move.
const MoveTaskResponse = struct {
    success: bool = true,
    task_id: []const u8,
    column_id: []const u8,
    position: i64,
};

pub fn tasksMoveHandler(
    ctx: gserverz.HttpContext,
    req: gserverz.HttpRequest,
    res: gserverz.HttpResponse,
) !gserverz.HttpResponse {
    const allocator = ctx.allocator;

    const di = try nalarcore.getSingleton();
    const sqlite_db = di.db;

    const item_id = req.params.get("item_id") orelse "";
    if (item_id.len == 0) {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "item_id required" }),
        });
    }
    // workspace_id is required for the SSE payload (the frontend
    // filters events for the active workspace). Empty is fine —
    // the SSE event will still be emitted with workspace_id="".
    const ws_id = req.params.get("workspace_id") orelse "";
    const task_id = req.params.get("task_id") orelse "";
    if (task_id.len == 0) {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "task_id required" }),
        });
    }

    if (req.body.len == 0) {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Request body required" }),
        });
    }

    const parsed = std.json.parseFromSliceLeaky(MoveTaskBody, allocator, req.body, .{}) catch {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Invalid JSON body" }),
        });
    };

    if (parsed.column_id.len == 0) {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "column_id is required" }),
        });
    }

    kanban_model.moveTask(allocator, sqlite_db, item_id, task_id, parsed.column_id, parsed.position) catch {
        return res.jsonResponse(.{
            .status_code = 500,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Failed to move task" }),
        });
    };

    // Emit SSE event so other connected clients refresh their kanban
    // view. action="moved" matches the frontend's `KanbanTaskEvent`
    // union variant. `moveTask` renumbers sibling positions in both
    // source and destination columns — the frontend re-fetches the
    // full column+task layout on every move, so a simple re-fetch
    // keeps all boards in sync without patching in-place.
    on_event_sent_kanban.onEventSendKanbanTask(allocator, .{
        .action = "moved",
        .workspace_id = ws_id,
        .item_id = item_id,
        .task_id = task_id,
        .new_column_id = parsed.column_id,
        .new_position = parsed.position,
    }) catch |err| {
        std.log.warn(
            "tasks_move: SSE emit failed (non-fatal): {s}",
            .{@errorName(err)},
        );
    };

    return res.jsonResponse(.{
        .status_code = 200,
        .data = try std.json.Stringify.valueAlloc(
            allocator,
            MoveTaskResponse{
                .task_id = task_id,
                .column_id = parsed.column_id,
                .position = parsed.position,
            },
            .{},
        ),
    });
}