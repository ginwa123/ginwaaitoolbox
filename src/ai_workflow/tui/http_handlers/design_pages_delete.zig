//! `DELETE /api/workspaces/:workspace_id/items/:item_id/design/pages/:page_id`.
//!
//! Delete a design page row. The `design_model.deletePage` function:
//!   - Returns `false` if no row matches (idempotent — 200 with
//!     `{deleted:false}`).
//!   - Returns `true` after a successful delete (200 with
//!     `{deleted:true}`).
//!
//! The page's element rows are dropped automatically (ON DELETE
//! CASCADE on `design_page_elements.page_id`). **The element html
//! files on disk are NOT cleaned up** by the model — see
//! `design_model.deletePage`'s docstring for the
//! design-fs-rewrite limitation (chunk 2 cleans up the metadata
//! only; orphan files are a known issue tracked separately).
//!
//! No request body. Emits `design_page_deleted` SSE event with
//! the page's id + name + workspace id + item id on the
//! actually-deleted path (frontend removes the tab strip entry).
//!
//! Errors:
//!   - 400 missing `item_id` or `page_id` path param
//!   - 500 DB failure
//!
//! Plan: docs/superpowers/plans/2026-07-06-design-fs-rewrite.md
//!   (Chunk 2, Task 2.5)

const std = @import("std");
const nalarcore = @import("nalarcore");
const gserverz = nalarcore.gserverz;
const http_response = @import("http_response.zig");
const design_model = @import("../design_model.zig");
const on_event_sent_design = nalarcore.ai_mod.on_event_sent_design;

const DeletePageResponse = struct {
    deleted: bool,
    page_id: []const u8,
};

pub const DesignPagesDeleteError = error{
    ItemIdRequired,
    PageIdRequired,
    LookupFailed,
    DeleteFailed,
    OutOfMemory,
};

// =====================================================================
// Use case
// =====================================================================

fn useCase(
    allocator: std.mem.Allocator,
    db: *nalarcore.sqlite.SqliteBackend,
    item_id: []const u8,
    page_id: []const u8,
) DesignPagesDeleteError!struct { deleted: bool, page_name: []u8 } {
    if (item_id.len == 0) return error.ItemIdRequired;
    if (page_id.len == 0) return error.PageIdRequired;

    // Fetch the page so we can carry `page_name` through to the
    // SSE event. If the row is already gone (404), return an
    // empty name + deleted=false — the DELETE itself becomes a
    // no-op.
    var page_name_owned: []u8 = allocator.dupe(u8, "") catch return error.LookupFailed;
    errdefer allocator.free(page_name_owned);

    if (design_model.getPage(allocator, db, page_id)) |existing| {
        // Replace the empty placeholder with the actual name.
        allocator.free(page_name_owned);
        page_name_owned = existing.name; // takes ownership of the dup'd string
        // freePageFull will free ALL the other duped strings but
        // NOT `existing.name` (we moved it out). Free the rest
        // manually.
        allocator.free(existing.id);
        allocator.free(existing.workspace_item_id);
        allocator.free(existing.created_at);
        allocator.free(existing.updated_at);
        // existing itself is a by-value struct, no allocation to free.

        const deleted = design_model.deletePage(allocator, db, page_id) catch return error.DeleteFailed;
        return .{ .deleted = deleted, .page_name = page_name_owned };
    } else |err| {
        if (err == error.PageNotFound) {
            // Idempotent no-op: row was already gone.
            return .{ .deleted = false, .page_name = page_name_owned };
        }
        return error.LookupFailed;
    }
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

    const outcome = useCase(allocator, sqlite_db, item_id, page_id) catch |err| {
        const status: u16 = switch (err) {
            error.ItemIdRequired => 400,
            error.PageIdRequired => 400,
            error.LookupFailed => 500,
            error.DeleteFailed => 500,
            error.OutOfMemory => 500,
        };
        const message: []const u8 = switch (err) {
            error.ItemIdRequired => "item_id required",
            error.PageIdRequired => "page_id required",
            error.LookupFailed => "Failed to look up design page",
            error.DeleteFailed => "Failed to delete design page",
            error.OutOfMemory => "Out of memory",
        };
        return res.jsonResponse(.{
            .status_code = status,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = message }),
        });
    };
    // Capture the page name BEFORE freeing it (the SSE event needs
    // it for the payload, even on the idempotent no-op path).
    const page_name_owned = outcome.page_name;
    defer allocator.free(page_name_owned);

    // Emit SSE only on the "actually deleted" path (the frontend
    // doesn't need a refresh when the row was already gone).
    if (outcome.deleted) {
        on_event_sent_design.onEventSendDesignPageDeleted(allocator, .{
            .workspace_id = ws_id,
            .item_id = item_id,
            .page_id = page_id,
            .page_name = page_name_owned,
        }) catch |err| {
            std.log.warn("design_pages_delete: SSE emit failed (non-fatal): {s}", .{@errorName(err)});
        };
    }

    return res.jsonResponse(.{
        .status_code = 200,
        .data = try std.json.Stringify.valueAlloc(
            allocator,
            DeletePageResponse{ .deleted = outcome.deleted, .page_id = page_id },
            .{},
        ),
    });
}