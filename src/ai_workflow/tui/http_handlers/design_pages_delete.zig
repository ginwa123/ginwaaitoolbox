//! `DELETE /api/workspaces/:workspace_id/items/:item_id/design/pages/:page_id`.
//!
//! Delete a design page. The on-disk `<item_path>/.nalar/design/<page>/`
//! folder is recursively unlinked AFTER the SQL DELETE succeeds
//! (defer-pattern) via `design_model.deletePage`. The DB FK
//! `ON DELETE CASCADE` on `design_page_elements.page_id` cleans up
//! the child element rows in the same transaction. UI-only — no LLM
//! tool exposes this endpoint, only the DesignView tab-strip × button.
//!
//! Response shape: `{"success": true}` on a successful delete.
//! Returns 404 if the page did not exist (so the frontend can
//! distinguish "already gone" from "deleted right now"). The frontend
//! treats both as success (idempotent — no need to surface a toast
//! for an already-deleted page).
//!
//! Errors:
//!   - 400 missing `page_id` path param
//!   - 404 page not found
//!   - 500 DB failure
//!
//! Plan: docs/superpowers/plans/2026-07-25-design-page-delete-button.md
//!   (Chunk 1)

const std = @import("std");
const nalarcore = @import("nalarcore");
const gserverz = nalarcore.gserverz;
const http_response = @import("http_response.zig");
const design_model = @import("../agentic_loop/design_model.zig");

pub const DesignPageDeleteError = error{
    /// `:page_id` path param was missing or empty.
    PageIdRequired,
    /// `design_model.deletePage` returned `false` (no such row).
    PageNotFound,
    /// `deletePage` failed for some other DB reason.
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
    io: std.Io,
    db: *nalarcore.sqlite.SqliteBackend,
    page_id: []const u8,
) DesignPageDeleteError!void {
    if (page_id.len == 0) return error.PageIdRequired;

    const deleted = design_model.deletePage(allocator, io, db, page_id) catch return error.DbError;
    if (!deleted) return error.PageNotFound;
}

// =====================================================================
// Handler
// =====================================================================

pub fn designPagesDeleteHandler(
    ctx: gserverz.HttpContext,
    req: gserverz.HttpRequest,
    res: gserverz.HttpResponse,
) !gserverz.HttpResponse {
    const allocator = ctx.allocator;
    const io = ctx.io;

    const di = try nalarcore.getSingleton();
    const sqlite_db = di.db;

    const page_id = req.params.get("page_id") orelse "";

    useCase(allocator, io, sqlite_db, page_id) catch |err| {
        const status: u16 = switch (err) {
            error.PageIdRequired => 400,
            error.PageNotFound => 404,
            error.DbError => 500,
            error.OutOfMemory => 500,
        };
        const message: []const u8 = switch (err) {
            error.PageIdRequired => "page_id required",
            error.PageNotFound => "Page not found",
            error.DbError => "Failed to delete page",
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
