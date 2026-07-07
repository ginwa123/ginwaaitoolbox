//! `DELETE /api/workspaces/:workspace_id/items/:item_id/design/pages/:page_id/elements/:element_id`.
//!
//! Delete a single design element. `design_model.deleteElement`
//! unlinks the on-disk html file and removes the DB row in one
//! transaction (idempotent — returns `false` when the id is
//! missing, no error).
//!
//! No request body. Returns 200 with `{deleted:bool, element_id}`.
//! Emits `design_element_deleted` SSE event on the actually-deleted
//! path (frontend removes the positioned div + frees iframe).
//!
//! Errors:
//!   - 400 missing `item_id`/`page_id`/`element_id`
//!   - 500 DB / IO failure
//!
//! Plan: docs/superpowers/plans/2026-07-06-design-fs-rewrite.md
//!   (Chunk 2, Task 2.10)

const std = @import("std");
const nalarcore = @import("nalarcore");
const gserverz = nalarcore.gserverz;
const http_response = @import("http_response.zig");
const design_model = @import("../design_model.zig");
const on_event_sent_design = nalarcore.ai_mod.on_event_sent_design;

const DeleteElementResponse = struct {
    deleted: bool,
    element_id: []const u8,
};

pub const DesignElementsDeleteError = error{
    ItemIdRequired,
    PageIdRequired,
    ElementIdRequired,
    DeleteFailed,
    OutOfMemory,
};

fn useCase(
    allocator: std.mem.Allocator,
    db: *nalarcore.sqlite.SqliteBackend,
    element_id: []const u8,
) DesignElementsDeleteError!bool {
    if (element_id.len == 0) return error.ElementIdRequired;
    const deleted = design_model.deleteElement(allocator, db, element_id) catch return error.DeleteFailed;
    return deleted;
}

pub fn designPageElementsDeleteHandler(
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
    const ws_id = req.params.get("workspace_id") orelse "";
    const page_id = req.params.get("page_id") orelse "";
    if (page_id.len == 0) {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "page_id required" }),
        });
    }
    const element_id = req.params.get("element_id") orelse "";
    if (element_id.len == 0) {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "element_id required" }),
        });
    }

    const deleted = useCase(allocator, sqlite_db, element_id) catch |err| {
        const status: u16 = switch (err) {
            error.ItemIdRequired => 400,
            error.PageIdRequired => 400,
            error.ElementIdRequired => 400,
            error.DeleteFailed => 500,
            error.OutOfMemory => 500,
        };
        const message: []const u8 = switch (err) {
            error.ItemIdRequired => "item_id required",
            error.PageIdRequired => "page_id required",
            error.ElementIdRequired => "element_id required",
            error.DeleteFailed => "Failed to delete design element",
            error.OutOfMemory => "Out of memory",
        };
        return res.jsonResponse(.{
            .status_code = status,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = message }),
        });
    };

    if (deleted) {
        on_event_sent_design.onEventSendDesignElementDeleted(allocator, .{
            .workspace_id = ws_id,
            .item_id = item_id,
            .page_id = page_id,
            .element_id = element_id,
        }) catch |err| {
            std.log.warn("design_page_elements_delete: SSE emit failed (non-fatal): {s}", .{@errorName(err)});
        };
    }

    return res.jsonResponse(.{
        .status_code = 200,
        .data = try std.json.Stringify.valueAlloc(
            allocator,
            DeleteElementResponse{ .deleted = deleted, .element_id = element_id },
            .{},
        ),
    });
}
