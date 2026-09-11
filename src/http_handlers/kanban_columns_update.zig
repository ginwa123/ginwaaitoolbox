//! `PATCH /api/workspaces/:workspace_id/items/:item_id/kanban/columns/:column_id`.
//!
//! Rename and/or reorder a kanban column.
//!
//! Body: `{name?, description?, position?}` — at least one of the
//! three fields must be present; otherwise the use-case returns
//! `error.NothingToUpdate` (mapped to 400).
//!
//! All three fields are optional because the frontend uses PATCH as
//! a single endpoint for "rename", "reorder", "rename+reorder",
//! "set description", etc.
//!
//! Response shape: `{"columns": [...], "count": N}` (the updated
//! board) — the frontend re-renders the entire board from this list.
//!
//! Layered as `useCase` (validate + rename/reorder + list + emit
//! SSE + return JSON) and a thin handler that maps the outcome +
//! errors to status codes.
//!
//! Plan: docs/superpowers/plans/2026-06-21-workspace-item-kanban.md
//!   (Chunk 3, Task 3.5)

const std = @import("std");
const nalarcore = @import("nalarcore");
const gserverz = nalarcore.gserverz;
const http_response = @import("http_response.zig");
const kanban_model = @import("../agentic_loop/kanban_model.zig");
const on_event_sent_kanban = nalarcore.ai_mod.on_event_sent_kanban;

/// Request body for column-update.
///
/// All fields are optional. At least one must be present (validated
/// in the use-case). The model functions are called only for fields
/// that are non-null, so an absent `name` keeps the existing name,
/// an absent `description` keeps the existing description, and an
/// absent `position` keeps the existing position.
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

pub const KanbanColumnUpdateError = error{
    ItemIdRequired,
    ColumnIdRequired,
    MissingBody,
    InvalidJson,
    NothingToUpdate,
    UpdateFailed,
    ReorderFailed,
    ListFailed,
    /// `makeKanbanColumnListResponse` returns `![]u8` — its body
    /// uses `std.json.Stringify.valueAlloc` which can fail with
    /// `OutOfMemory`. Unreachable on the per-request arena, but
    /// the type system requires the variant.
    OutOfMemory,
};

pub const KanbanColumnUpdateInput = struct {
    item_id: []const u8,
    workspace_id: []const u8,
    column_id: []const u8,
    body: UpdateColumnBody,
};

pub const KanbanColumnUpdateResult = []const u8; // pre-serialized JSON

// =====================================================================
// Use case
// =====================================================================

fn useCase(
    allocator: std.mem.Allocator,
    db: *nalarcore.sqlite.SqliteBackend,
    input: KanbanColumnUpdateInput,
) KanbanColumnUpdateError!KanbanColumnUpdateResult {
    if (input.item_id.len == 0) return error.ItemIdRequired;
    if (input.column_id.len == 0) return error.ColumnIdRequired;

    // Empty-body check is in the handler (`req.body.len` is HTTP-layer).
    // Body-shape validation is also handler-layer (parses JSON). Here
    // we just enforce "at least one field present".
    const parsed = input.body;
    if (parsed.name == null and parsed.description == null and parsed.position == null) {
        return error.NothingToUpdate;
    }

    // Update name + description (if either is set).
    if (parsed.name != null or parsed.description != null) {
        kanban_model.updateColumn(
            allocator,
            db,
            input.item_id,
            input.column_id,
            parsed.name,
            parsed.description,
        ) catch return error.UpdateFailed;
    }

    // Reorder (if position is set). Independent of name/description —
    // a single PATCH can do both.
    if (parsed.position) |new_pos| {
        kanban_model.reorderColumn(
            allocator,
            db,
            input.item_id,
            input.column_id,
            new_pos,
        ) catch return error.ReorderFailed;
    }

    // Return the updated board so the frontend can re-render without
    // a separate GET round-trip.
    const cols = kanban_model.listColumns(allocator, db, input.item_id) catch return error.ListFailed;
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
        .workspace_id = input.workspace_id,
        .item_id = input.item_id,
        .column_id = input.column_id,
        .new_name = parsed.name,
        .new_description = parsed.description,
        .new_position = parsed.position,
    }) catch |err| {
        std.log.warn(
            "kanban_columns_update: SSE emit failed (non-fatal): {s}",
            .{@errorName(err)},
        );
    };

    return try http_response.makeKanbanColumnListResponse(allocator, cols);
}

// =====================================================================
// Handler
// =====================================================================

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
    // workspace_id is required for the SSE payload (the frontend uses
    // it to filter events for the active workspace). Empty is fine —
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

    const data = useCase(allocator, sqlite_db, .{
        .item_id = item_id,
        .workspace_id = ws_id,
        .column_id = column_id,
        .body = parsed,
    }) catch |err| {
        const status: u16 = switch (err) {
            error.ItemIdRequired => 400,
            error.ColumnIdRequired => 400,
            error.MissingBody => 400,
            error.InvalidJson => 400,
            error.NothingToUpdate => 400,
            error.UpdateFailed, error.ReorderFailed, error.ListFailed => 500,
            error.OutOfMemory => 500,
        };
        const message: []const u8 = switch (err) {
            error.ItemIdRequired => "item_id required",
            error.ColumnIdRequired => "column_id required",
            error.MissingBody => "Request body required",
            error.InvalidJson => "Invalid JSON body",
            error.NothingToUpdate => "At least one of name, description, or position is required",
            error.UpdateFailed => "Failed to update column",
            error.ReorderFailed => "Failed to reorder column",
            error.ListFailed => "Failed to list updated columns",
            error.OutOfMemory => "Out of memory",
        };
        return res.jsonResponse(.{
            .status_code = status,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = message }),
        });
    };

    return res.jsonResponse(.{
        .status_code = 200,
        .data = data,
    });
}