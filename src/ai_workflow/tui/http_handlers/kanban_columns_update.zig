//! PATCH /api/workspaces/:workspace_id/items/:item_id/kanban/columns/:column_id
//!
//! Rename and/or reorder a kanban column. Thin wrapper around
//! `kanban_model.renameColumn` + `kanban_model.reorderColumn`.
//!
//! Body: `{name?, position?}` — at least one of the two fields must be
//! present; otherwise the handler returns 400 ("nothing to update").
//! Both fields are optional because the frontend uses PATCH as a
//! single endpoint for "rename", "reorder", and "rename+reorder".
//!
//! Response shape: `{"columns": [...], "count": N}` (the updated
//! board) — the frontend re-renders the entire board from this list.
//!
//! Errors:
//!   - 400 missing/invalid JSON body, missing column_id or item_id
//!   - 400 empty body (both name and position are null)
//!   - 500 DB failure
//!
//! Plan: docs/superpowers/plans/2026-06-21-workspace-item-kanban.md
//!   (Chunk 3, Task 3.5)

const std = @import("std");
const nalarcore = @import("nalarcore");
const gserverz = nalarcore.gserverz;
const http_response = @import("http_response.zig");
const kanban_model = @import("../kanban_model.zig");

/// Request body for column-update.
///
/// Both fields are optional. At least one must be present (validated
/// in the handler body). The model functions are called only for
/// fields that are non-null, so an absent `name` keeps the existing
/// name and an absent `position` keeps the existing position.
const UpdateColumnBody = struct {
    name: ?[]const u8 = null,
    position: ?i64 = null,
};

pub fn kanbanColumnsUpdateHandler(
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

    if (req.body.len == 0) {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Request body required" }),
        });
    }

    const parsed = std.json.parseFromSliceLeaky(UpdateColumnBody, allocator, req.body, .{}) catch {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Invalid JSON body" }),
        });
    };

    if (parsed.name == null and parsed.position == null) {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "At least one of name or position is required" }),
        });
    }

    if (parsed.name) |new_name| {
        kanban_model.renameColumn(allocator, sqlite_db, item_id, column_id, new_name) catch {
            return res.jsonResponse(.{
                .status_code = 500,
                .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Failed to rename column" }),
            });
        };
    }

    if (parsed.position) |new_pos| {
        kanban_model.reorderColumn(allocator, sqlite_db, item_id, column_id, new_pos) catch {
            return res.jsonResponse(.{
                .status_code = 500,
                .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Failed to reorder column" }),
            });
        };
    }

    // Return the updated board so the frontend can re-render without
    // a separate GET round-trip.
    const cols = kanban_model.listColumns(allocator, sqlite_db, item_id) catch {
        return res.jsonResponse(.{
            .status_code = 500,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Failed to list updated columns" }),
        });
    };
    defer kanban_model.freeColumns(allocator, cols);

    return res.jsonResponse(.{
        .status_code = 200,
        .data = try http_response.makeKanbanColumnListResponse(allocator, cols),
    });
}