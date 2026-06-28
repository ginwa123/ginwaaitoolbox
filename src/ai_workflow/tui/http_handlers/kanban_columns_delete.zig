//! DELETE /api/workspaces/:workspace_id/items/:item_id/kanban/columns/:column_id
//!
//! Delete a kanban column. Thin wrapper around `kanban_model.deleteColumn`.
//!
//! Before calling `deleteColumn`, the handler runs a `COUNT(*)` against
//! `workspace_item_tasks.kanban_column_id` to refuse the delete when
//! the column still has tasks. This protects against silently
//! re-parenting tasks to "unassigned" without the user's consent —
//! the user must first move the tasks to another column.
//!
//! On the success path (no tasks using the column), tasks that WERE
//! assigned to this column have their `kanban_column_id` set to NULL
//! by `deleteColumn` (the tasks themselves are NOT removed); the
//! frontend surfaces them in the "Unassigned" group of the folder-
//! list view. In practice this only applies to a column whose tasks
//! were all moved away earlier but the column was never deleted —
//! the normal end-of-life path is "user moves tasks → user deletes
//! column".
//!
//! No request body. Returns 200 with `{"success": true}` on success.
//!
//! Errors:
//!   - 400 missing column_id or item_id
//!   - 409 column still has N task(s) assigned — caller must move them first
//!   - 500 DB failure
//!
//! Plan: docs/superpowers/plans/2026-06-21-workspace-item-kanban.md
//!   (Chunk 3, Task 3.6)

const std = @import("std");
const nalarcore = @import("nalarcore");
const gserverz = nalarcore.gserverz;
const http_response = @import("http_response.zig");
const kanban_model = @import("../kanban_model.zig");
const on_event_sent_kanban = nalarcore.ai_mod.on_event_sent_kanban;

/// Response shape for column-delete.
const DeleteColumnResponse = struct {
    success: bool = true,
    column_id: []const u8,
};

pub fn kanbanColumnsDeleteHandler(
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
    const column_id = req.params.get("column_id") orelse "";
    if (column_id.len == 0) {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "column_id required" }),
        });
    }

    // Refuse to delete a column that still has tasks assigned. The
    // user must move the tasks to another column first; the
    // `kanban_task` SSE event from `tasksMoveHandler` will then
    // trigger a board refresh on every connected client. We surface
    // the count in the error so the frontend can render a precise
    // message ("This column has 3 tasks — move them first") instead
    // of a generic "cannot delete".
    const task_count = kanban_model.countTasksInColumn(allocator, sqlite_db, column_id) catch {
        return res.jsonResponse(.{
            .status_code = 500,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Failed to check column usage" }),
        });
    };
    if (task_count > 0) {
        const msg = try std.fmt.allocPrint(
            allocator,
            "Cannot delete column: {d} task{s} still assigned. Move them to another column first.",
            .{ task_count, if (task_count == 1) "" else "s" },
        );
        defer allocator.free(msg);
        return res.jsonResponse(.{
            .status_code = 409,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = msg }),
        });
    }

    kanban_model.deleteColumn(allocator, sqlite_db, item_id, column_id) catch {
        return res.jsonResponse(.{
            .status_code = 500,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Failed to delete column" }),
        });
    };

    // Emit SSE event so other connected clients refresh their kanban
    // view. action="deleted" matches the frontend's `KanbanColumnEvent`
    // union variant. The frontend's SSE handler is responsible for
    // re-fetching the column list AND the unassigned tasks (tasks
    // that were on this column get their `kanban_column_id` set to
    // NULL by `deleteColumn`).
    on_event_sent_kanban.onEventSendKanbanColumn(allocator, .{
        .action = "deleted",
        .workspace_id = ws_id,
        .item_id = item_id,
        .column_id = column_id,
    }) catch |err| {
        std.log.warn(
            "kanban_columns_delete: SSE emit failed (non-fatal): {s}",
            .{@errorName(err)},
        );
    };

    return res.jsonResponse(.{
        .status_code = 200,
        .data = try std.json.Stringify.valueAlloc(
            allocator,
            DeleteColumnResponse{ .column_id = column_id },
            .{},
        ),
    });
}