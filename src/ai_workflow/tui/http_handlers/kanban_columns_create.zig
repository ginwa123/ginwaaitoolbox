//! POST /api/workspaces/:workspace_id/items/:item_id/kanban/columns
//!
//! Append a new column to the end of a kanban's column sequence (or at
//! an explicit `position` if the caller passes one). Thin wrapper
//! around `kanban_model.addColumn`.
//!
//! Body: `{name, position?}` where `name` is required and `position`
//! is optional (default `MAX(position) + 1`).
//!
//! Response shape: `KanbanColumnResponse` for the newly-created column
//! (built by `http_response.makeKanbanColumnResponse`).
//!
//! Errors:
//!   - 400 missing/invalid JSON body, missing/empty `name`
//!   - 400 missing `item_id` path param
//!   - 500 DB failure
//!
//! Plan: docs/superpowers/plans/2026-06-21-workspace-item-kanban.md
//!   (Chunk 3, Task 3.4)

const std = @import("std");
const nalarcore = @import("nalarcore");
const gserverz = nalarcore.gserverz;
const http_response = @import("http_response.zig");
const kanban_model = @import("../kanban_model.zig");
const on_event_sent_kanban = nalarcore.ai_mod.on_event_sent_kanban;

/// Request body for column-create.
///
/// `position` is optional; `null` → place at `MAX(position) + 1`.
/// `description` is optional; `null` → stored as the empty string
/// (the "no description" sentinel).
const CreateColumnBody = struct {
    name: []const u8,
    description: ?[]const u8 = null,
    position: ?i64 = null,
};

pub fn kanbanColumnsCreateHandler(
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

    if (req.body.len == 0) {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Request body required" }),
        });
    }

    const parsed = std.json.parseFromSliceLeaky(CreateColumnBody, allocator, req.body, .{}) catch {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Invalid JSON body" }),
        });
    };

    if (parsed.name.len == 0) {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "name is required" }),
        });
    }

    // Empty string is the "no description" sentinel (the DB column is
    // NOT NULL DEFAULT '', and the frontend renders "" as the
    // "Add a description..." placeholder).
    const description = parsed.description orelse "";
    const new_id = kanban_model.addColumn(allocator, sqlite_db, item_id, parsed.name, description, parsed.position) catch {
        return res.jsonResponse(.{
            .status_code = 500,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Failed to add column" }),
        });
    };
    defer allocator.free(new_id);

    // Return the freshly-created column as a single KanbanColumnResponse.
    // We need its `name`, `position`, and `workspace_item_id` (already in
    // scope) plus its `id` and `created_at` (need to re-query because
    // `addColumn` doesn't return the full row).
    const cols = kanban_model.listColumns(allocator, sqlite_db, item_id) catch {
        return res.jsonResponse(.{
            .status_code = 500,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Failed to fetch new column" }),
        });
    };
    defer kanban_model.freeColumns(allocator, cols);

    // Find the column with the freshly-generated id.
    for (cols) |c| {
        if (std.mem.eql(u8, c.id, new_id)) {
            // Emit SSE event so other connected clients refresh
            // their kanban view. action="created" matches the
            // frontend's `KanbanColumnEvent` union variant. The
            // emit is fire-and-forget: `event_bus.emit` returns
            // void and silently no-ops when no SSE client is
            // subscribed, so tests that don't stand up an SSE
            // server still pass.
            on_event_sent_kanban.onEventSendKanbanColumn(allocator, .{
                .action = "created",
                .workspace_id = ws_id,
                .item_id = item_id,
                .column_id = c.id,
                .new_description = c.description,
            }) catch |err| {
                std.log.warn(
                    "kanban_columns_create: SSE emit failed (non-fatal): {s}",
                    .{@errorName(err)},
                );
            };
            return res.jsonResponse(.{
                .status_code = 201,
                .data = try std.json.Stringify.valueAlloc(
                    allocator,
                    http_response.KanbanColumnResponse{
                        .id = c.id,
                        .workspace_item_id = c.workspace_item_id,
                        .name = c.name,
                        .description = c.description,
                        .position = c.position,
                        .created_at = c.created_at,
                    },
                    .{},
                ),
            });
        }
    }

    return res.jsonResponse(.{
        .status_code = 500,
        .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Column was added but not visible in list" }),
    });
}