//! GET /api/workspaces/:workspace_id/items/:item_id/kanban/columns
//!
//! Returns the kanban column list for a workspace item. Thin wrapper
//! around `kanban_model.listColumns` — no body parsing, just path
//! param validation, the DB call, and the response envelope.
//!
//! Response shape: `{"columns":[KanbanColumnResponse, ...], "count": N}`
//! (built by `http_response.makeKanbanColumnListResponse`).
//!
//! Errors:
//!   - 400 missing `item_id` path param
//!   - 500 DB failure
//!
//! Plan: docs/superpowers/plans/2026-06-21-workspace-item-kanban.md
//!   (Chunk 3, Task 3.3)

const std = @import("std");
const nalarcore = @import("nalarcore");
const gserverz = nalarcore.gserverz;
const http_response = @import("http_response.zig");
const kanban_model = @import("../kanban_model.zig");

pub fn kanbanColumnsListHandler(
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

    const cols = kanban_model.listColumns(allocator, sqlite_db, item_id) catch {
        return res.jsonResponse(.{
            .status_code = 500,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Failed to list kanban columns" }),
        });
    };
    defer kanban_model.freeColumns(allocator, cols);

    return res.jsonResponse(.{
        .status_code = 200,
        .data = try http_response.makeKanbanColumnListResponse(allocator, cols),
    });
}