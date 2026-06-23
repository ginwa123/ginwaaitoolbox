//! DELETE /api/workspaces/:workspace_id/items/:item_id/kanban/columns/:column_id
//!
//! Delete a kanban column. Thin wrapper around `kanban_model.deleteColumn`.
//!
//! Tasks that were assigned to this column have their `kanban_column_id`
//! set to NULL by `deleteColumn` (the tasks themselves are NOT removed);
//! the frontend surfaces them in the "Unassigned" group of the folder-
//! list view.
//!
//! No request body. Returns 200 with `{"success": true}` on success.
//!
//! Errors:
//!   - 400 missing column_id or item_id
//!   - 500 DB failure
//!
//! Plan: docs/superpowers/plans/2026-06-21-workspace-item-kanban.md
//!   (Chunk 3, Task 3.6)

const std = @import("std");
const nalarcore = @import("nalarcore");
const gserverz = nalarcore.gserverz;
const http_response = @import("http_response.zig");
const kanban_model = @import("../kanban_model.zig");

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
    const column_id = req.params.get("column_id") orelse "";
    if (column_id.len == 0) {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "column_id required" }),
        });
    }

    kanban_model.deleteColumn(allocator, sqlite_db, item_id, column_id) catch {
        return res.jsonResponse(.{
            .status_code = 500,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Failed to delete column" }),
        });
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