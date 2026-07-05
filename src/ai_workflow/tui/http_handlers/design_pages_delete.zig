//! `DELETE /api/workspaces/:workspace_id/items/:item_id/design/pages/:page_id`.
//!
//! Removes a design page row. Idempotent: deleting a missing page
//! returns 200 with `deleted: false` (matches the `deletePage`
//! model contract). Emits a `design_page_deleted` SSE event on
//! success so other connected clients refresh their tab strip.
//!
//! Errors:
//!   - 400 missing path params
//!   - 500 DB failure
//!
//! Layered as `useCase` (validate + lookup + delete + emit SSE +
//! return JSON) and a thin handler that maps the outcome + errors
//! to status codes.
//!
//! Plan: docs/superpowers/plans/2026-07-05-design-mode.md (Chunk 2,
//! Task 2.6).

const std = @import("std");
const nalarcore = @import("nalarcore");
const gserverz = nalarcore.gserverz;
const design_model = @import("../design_model.zig");
const on_event_sent_design = nalarcore.ai_mod.on_event_sent_design;

pub const DesignPagesDeleteError = error{
    WorkspaceIdRequired,
    ItemIdRequired,
    PageIdRequired,
    LookupFailed,
    DeleteFailed,
    /// `valueAlloc` for the JSON response can fail with OOM on the
    /// per-request arena. The arena reaps the failure memory, but
    /// the type system requires the variant in the error set.
    OutOfMemory,
};

pub const DesignPagesDeleteInput = struct {
    workspace_id: []const u8,
    item_id: []const u8,
    page_id: []const u8,
};

/// JSON shape for the DELETE response. `page_name` is included
/// alongside `deleted=true` for symmetry with the SSE payload; for
/// the `deleted=false` (idempotent no-op) case it's `""`.
pub const DesignPagesDeleteResult = []const u8; // pre-serialized JSON

// =====================================================================
// Use case
// =====================================================================

fn useCase(
    allocator: std.mem.Allocator,
    db: *nalarcore.sqlite.SqliteBackend,
    input: DesignPagesDeleteInput,
) DesignPagesDeleteError!DesignPagesDeleteResult {
    if (input.workspace_id.len == 0) return error.WorkspaceIdRequired;
    if (input.item_id.len == 0) return error.ItemIdRequired;
    if (input.page_id.len == 0) return error.PageIdRequired;

    // Look up the page name BEFORE deletion so we can emit it in the
    // SSE event (the row vanishes on delete). If the row is missing,
    // skip the lookup and treat the request as a no-op.
    var page_name_buf: [256]u8 = undefined;
    var page_name: []const u8 = "";
    if (design_model.getPage(allocator, db, input.page_id)) |page| {
        defer design_model.freePageFull(allocator, page);
        const len = @min(page.name.len, page_name_buf.len);
        @memcpy(page_name_buf[0..len], page.name[0..len]);
        page_name = page_name_buf[0..len];
    } else |err| switch (err) {
        error.PageNotFound => {
            // Page doesn't exist — return idempotent 200.
            return std.json.Stringify.valueAlloc(allocator, struct {
                deleted: bool = false,
                page_id: []const u8,
            }{ .page_id = input.page_id }, .{}) catch return error.OutOfMemory;
        },
        else => return error.LookupFailed,
    }

    _ = design_model.deletePage(allocator, db, input.page_id) catch return error.DeleteFailed;

    // Fire-and-forget SSE event.
    on_event_sent_design.onEventSendDesignPageDeleted(allocator, .{
        .workspace_id = input.workspace_id,
        .item_id = input.item_id,
        .page_id = input.page_id,
        .page_name = page_name,
    });

    return std.json.Stringify.valueAlloc(allocator, struct {
        deleted: bool = true,
        page_id: []const u8,
    }{ .page_id = input.page_id }, .{}) catch return error.OutOfMemory;
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

    const workspace_id = req.params.get("workspace_id") orelse "";
    const item_id = req.params.get("item_id") orelse "";
    const page_id = req.params.get("page_id") orelse "";

    const di = try nalarcore.getSingleton();
    const data = useCase(allocator, di.db, .{
        .workspace_id = workspace_id,
        .item_id = item_id,
        .page_id = page_id,
    }) catch |err| {
        const status: u16 = switch (err) {
            error.WorkspaceIdRequired => 400,
            error.ItemIdRequired => 400,
            error.PageIdRequired => 400,
            error.LookupFailed => 500,
            error.DeleteFailed => 500,
            error.OutOfMemory => 500,
        };
        const message: []const u8 = switch (err) {
            error.WorkspaceIdRequired => "workspace_id required",
            error.ItemIdRequired => "item_id required",
            error.PageIdRequired => "page_id required",
            error.LookupFailed => "Failed to look up design page",
            error.DeleteFailed => "Failed to delete design page",
            error.OutOfMemory => "Out of memory",
        };
        const http_response = @import("http_response.zig");
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
