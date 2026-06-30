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
const on_event_sent_kanban = nalarcore.ai_mod.on_event_sent_kanban;

/// Request body for column-update.
///
/// All fields are optional. At least one must be present (validated
/// in the handler body). The model functions are called only for
/// fields that are non-null, so an absent `name` keeps the existing
/// name, an absent `description` keeps the existing description,
/// and an absent `position` keeps the existing position.
///
/// Distinguish two states for `description`:
///   - field absent → `null` → "leave unchanged"
///   - field present with `""` → "clear" (the Settings UI sends
///     explicit `""` when the user empties the description textarea;
///     this is distinct from omitting the field).
/// See `kanban_model.updateColumn` for the SQL-level handling.
const UpdateColumnBody = struct {
    name: ?[]const u8 = null,
    /// New description: `null` leaves the existing description
    /// unchanged; `""` clears it; non-empty replaces it.
    description: ?[]const u8 = null,
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

    if (parsed.name == null and parsed.description == null and parsed.position == null) {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "At least one of name, description, or position is required" }),
        });
    }

    if (parsed.name != null or parsed.description != null) {
        kanban_model.updateColumn(allocator, sqlite_db, item_id, column_id, parsed.name, parsed.description) catch {
            return res.jsonResponse(.{
                .status_code = 500,
                .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Failed to update column" }),
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

    // Emit SSE event so other connected clients refresh their kanban
    // view. `reordered` takes precedence over `updated` when the body
    // sets `position` — reordering changes the column order even if
    // the name is also being changed, so the frontend re-fetches
    // either way. Both fields are included in the payload so the
    // frontend can dispatch on action without re-parsing the body.
    const action: []const u8 = if (parsed.position != null) "reordered" else "updated";
    on_event_sent_kanban.onEventSendKanbanColumn(allocator, .{
        .action = action,
        .workspace_id = ws_id,
        .item_id = item_id,
        .column_id = column_id,
        .new_name = parsed.name,
        .new_description = parsed.description,
        .new_position = parsed.position,
    }) catch |err| {
        std.log.warn(
            "kanban_columns_update: SSE emit failed (non-fatal): {s}",
            .{@errorName(err)},
        );
    };

    return res.jsonResponse(.{
        .status_code = 200,
        .data = try http_response.makeKanbanColumnListResponse(allocator, cols),
    });
}