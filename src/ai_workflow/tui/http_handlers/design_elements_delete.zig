//! `DELETE /api/workspaces/:workspace_id/items/:item_id/design/pages/:page_id/elements/:element_id`.
//!
//! Delete a design element. The on-disk HTML file is unlinked
//! AFTER the SQL DELETE succeeds (defer-pattern) via
//! `design_model.deleteElement`. UI-only — no LLM tool exposes this
//! endpoint, only the DesignView.vue "delete" button.
//!
//! Response shape: `{"success": true}` on a successful delete.
//! Returns 404 if the element did not exist (so the frontend can
//! distinguish "already gone" from "deleted right now").
//!
//! Errors:
//!   - 400 missing `element_id` path param
//!   - 404 element not found
//!   - 500 DB failure
//!
//! Plan: docs/superpowers/plans/2026-07-08-design-mode-redesign.md
//!   (Chunk 3, Task 3.3)

const std = @import("std");
const nalarcore = @import("nalarcore");
const gserverz = nalarcore.gserverz;
const http_response = @import("http_response.zig");
const design_model = @import("../../../agentic_loop/design_model.zig");

pub const DesignElementDeleteError = error{
    /// `:element_id` path param was missing or empty.
    ElementIdRequired,
    /// `design_model.deleteElement` returned `false` (no such row).
    ElementNotFound,
    /// `deleteElement` failed for some other DB reason.
    DbError,
    /// `std.json.Stringify.valueAlloc` failed for the response
    /// envelope (effectively unreachable on the per-request arena).
    OutOfMemory,
};

// =====================================================================
// Use case
// =====================================================================

fn useCase(
    allocator: std.mem.Allocator,
    db: *nalarcore.sqlite.SqliteBackend,
    element_id: []const u8,
) DesignElementDeleteError!void {
    if (element_id.len == 0) return error.ElementIdRequired;

    const deleted = design_model.deleteElement(allocator, db, element_id) catch return error.DbError;
    if (!deleted) return error.ElementNotFound;
}

// =====================================================================
// Handler
// =====================================================================

pub fn designElementsDeleteHandler(
    ctx: gserverz.HttpContext,
    req: gserverz.HttpRequest,
    res: gserverz.HttpResponse,
) !gserverz.HttpResponse {
    const allocator = ctx.allocator;

    const di = try nalarcore.getSingleton();
    const sqlite_db = di.db;

    const element_id = req.params.get("element_id") orelse "";

    useCase(allocator, sqlite_db, element_id) catch |err| {
        const status: u16 = switch (err) {
            error.ElementIdRequired => 400,
            error.ElementNotFound => 404,
            error.DbError => 500,
            error.OutOfMemory => 500,
        };
        const message: []const u8 = switch (err) {
            error.ElementIdRequired => "element_id required",
            error.ElementNotFound => "Element not found",
            error.DbError => "Failed to delete element",
            error.OutOfMemory => "Out of memory",
        };
        return res.jsonResponse(.{
            .status_code = status,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = message }),
        });
    };

    const SuccessResponse = struct { success: bool = true };
    return res.jsonResponse(.{
        .status_code = 200,
        .data = try std.json.Stringify.valueAlloc(
            allocator,
            SuccessResponse{},
            .{},
        ),
    });
}