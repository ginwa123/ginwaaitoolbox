//! `PUT /api/workspaces/:workspace_id/items/:item_id/design/pages/:page_id`.
//!
//! Update a design page's canvas geometry (width/height/x/y).
//! Name is NOT updatable — to rename a page, delete + recreate via
//! `POST /design/pages` (which is idempotent on `(item_id, name)`).
//!
//! Body: `{width?, height?, x?, y?}` — at least one of the four
//! geometry fields must be present. The model function
//! `updatePageGeometry` requires all four, so the use-case defaults
//! missing fields to the existing row's values (read first, then
//! write back).
//!
//! Response: 200 with `{page: DesignPageFullResponse}` (re-fetched
//! after the update so the timestamps reflect the new write).
//! Emits `design_page_updated` SSE event.
//!
//! Errors:
//!   - 400 missing `item_id` or `page_id`, empty body, invalid JSON,
//!     `error.NothingToUpdate` (no geometry fields present), missing
//!     body
//!   - 404 page not found
//!   - 500 DB failure
//!
//! Plan: docs/superpowers/plans/2026-07-06-design-fs-rewrite.md
//!   (Chunk 2, Task 2.4)

const std = @import("std");
const nalarcore = @import("nalarcore");
const gserverz = nalarcore.gserverz;
const http_response = @import("http_response.zig");
const design_model = @import("../design_model.zig");
const on_event_sent_design = nalarcore.ai_mod.on_event_sent_design;

const UpdatePageBody = struct {
    width: ?i64 = null,
    height: ?i64 = null,
    x: ?i64 = null,
    y: ?i64 = null,
};

pub const DesignPagesUpdateError = error{
    ItemIdRequired,
    PageIdRequired,
    NothingToUpdate,
    PageNotFound,
    UpdateFailed,
    FetchFailed,
    OutOfMemory,
};

pub const UpdatePageInput = struct {
    item_id: []const u8,
    workspace_id: []const u8,
    page_id: []const u8,
    body: UpdatePageBody,
};

pub const UpdatePageOutput = struct {
    page: design_model.DesignPageFull,
};

// =====================================================================
// Use case
// =====================================================================

fn useCase(
    allocator: std.mem.Allocator,
    db: *nalarcore.sqlite.SqliteBackend,
    input: UpdatePageInput,
) DesignPagesUpdateError!UpdatePageOutput {
    if (input.item_id.len == 0) return error.ItemIdRequired;
    if (input.page_id.len == 0) return error.PageIdRequired;

    const body = input.body;
    if (body.width == null and body.height == null and body.x == null and body.y == null) {
        return error.NothingToUpdate;
    }

    // The model writes all four geometry fields, so fetch the
    // existing row to default any missing ones.
    const existing = design_model.getPage(allocator, db, input.page_id) catch |err| {
        if (err == error.PageNotFound) return error.PageNotFound;
        return error.FetchFailed;
    };
    defer design_model.freePageFull(allocator, existing);

    const new_width = body.width orelse existing.width;
    const new_height = body.height orelse existing.height;
    const new_x = body.x orelse existing.x;
    const new_y = body.y orelse existing.y;
    // Free existing's heap copies before calling update (which may
    // fail on OOM and propagate).
    allocator.free(existing.id);
    allocator.free(existing.workspace_item_id);
    allocator.free(existing.name);
    allocator.free(existing.created_at);
    allocator.free(existing.updated_at);

    const updated = design_model.updatePageGeometry(
        allocator,
        db,
        input.page_id,
        new_width,
        new_height,
        new_x,
        new_y,
    ) catch |err| {
        if (err == error.PageNotFound) return error.PageNotFound;
        return error.UpdateFailed;
    };
    if (!updated) return error.PageNotFound;

    // Re-fetch to surface the new updated_at + (possibly changed)
    // geometry.
    const page = design_model.getPage(allocator, db, input.page_id) catch return error.FetchFailed;
    return .{ .page = page };
}

// =====================================================================
// Handler
// =====================================================================

pub fn designPagesUpdateHandler(
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

    if (req.body.len == 0) {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Request body required" }),
        });
    }

    const parsed = std.json.parseFromSliceLeaky(UpdatePageBody, allocator, req.body, .{}) catch {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Invalid JSON body" }),
        });
    };

    const output = useCase(allocator, sqlite_db, .{
        .item_id = item_id,
        .workspace_id = ws_id,
        .page_id = page_id,
        .body = parsed,
    }) catch |err| {
        const status: u16 = switch (err) {
            error.ItemIdRequired => 400,
            error.PageIdRequired => 400,
            error.NothingToUpdate => 400,
            error.PageNotFound => 404,
            error.UpdateFailed => 500,
            error.FetchFailed => 500,
            error.OutOfMemory => 500,
        };
        const message: []const u8 = switch (err) {
            error.ItemIdRequired => "item_id required",
            error.PageIdRequired => "page_id required",
            error.NothingToUpdate => "At least one of width/height/x/y is required",
            error.PageNotFound => "design page not found",
            error.UpdateFailed => "Failed to update design page",
            error.FetchFailed => "Failed to fetch updated design page",
            error.OutOfMemory => "Out of memory",
        };
        return res.jsonResponse(.{
            .status_code = status,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = message }),
        });
    };

    defer {
        allocator.free(output.page.id);
        allocator.free(output.page.workspace_item_id);
        allocator.free(output.page.name);
        allocator.free(output.page.created_at);
        allocator.free(output.page.updated_at);
    }

    // Emit the SSE "updated" event so other clients refresh.
    on_event_sent_design.onEventSendDesignPageUpdated(allocator, .{
        .action = "updated",
        .workspace_id = ws_id,
        .item_id = item_id,
        .page = .{
            .id = output.page.id,
            .workspace_item_id = output.page.workspace_item_id,
            .name = output.page.name,
            .width = output.page.width,
            .height = output.page.height,
            .x = output.page.x,
            .y = output.page.y,
            .position = output.page.position,
            .created_at = output.page.created_at,
            .updated_at = output.page.updated_at,
        },
    }) catch |err| {
        std.log.warn("design_pages_update: SSE emit failed (non-fatal): {s}", .{@errorName(err)});
    };

    return res.jsonResponse(.{
        .status_code = 200,
        .data = try http_response.makeDesignPageFullResponse(allocator, output.page),
    });
}
