//! `GET /api/workspaces/:workspace_id/items/:item_id/design/pages/:page_id`.
//!
//! Fetch a single design page including its full HTML body. Used by
//! the frontend's DesignView when the user clicks a tab — the page
//! list endpoint (Task 2.3) excludes html for size, so this endpoint
//! lazy-loads it on demand.
//!
//! Errors:
//!   - 400 missing `page_id` / `item_id` / `workspace_id`
//!   - 404 page does not exist
//!   - 500 DB failure
//!
//! Layered as `useCase` (validate + fetch + return JSON) and a thin
//! handler that maps the outcome + errors to status codes.
//!
//! Plan: docs/superpowers/plans/2026-07-05-design-mode.md (Chunk 2,
//! Task 2.4).

const std = @import("std");
const nalarcore = @import("nalarcore");
const gserverz = nalarcore.gserverz;
const design_model = @import("../design_model.zig");

pub const DesignPagesGetError = error{
    WorkspaceIdRequired,
    ItemIdRequired,
    PageIdRequired,
    PageNotFound,
    GetFailed,
    /// `valueAlloc` for the JSON response can fail with OOM on the
    /// per-request arena. The arena reaps the failure memory, but
    /// the type system requires the variant in the error set.
    OutOfMemory,
};

pub const DesignPagesGetInput = struct {
    workspace_id: []const u8,
    item_id: []const u8,
    page_id: []const u8,
};

pub const DesignPagesGetResult = []const u8; // pre-serialized JSON

// =====================================================================
// Use case
// =====================================================================

fn useCase(
    allocator: std.mem.Allocator,
    db: *nalarcore.sqlite.SqliteBackend,
    input: DesignPagesGetInput,
) DesignPagesGetError!DesignPagesGetResult {
    if (input.workspace_id.len == 0) return error.WorkspaceIdRequired;
    if (input.item_id.len == 0) return error.ItemIdRequired;
    if (input.page_id.len == 0) return error.PageIdRequired;

    const page = design_model.getPage(allocator, db, input.page_id) catch |err| switch (err) {
        error.PageNotFound => return error.PageNotFound,
        else => return error.GetFailed,
    };
    defer design_model.freePageFull(allocator, page);

    return std.json.Stringify.valueAlloc(allocator, page, .{}) catch return error.OutOfMemory;
}

// =====================================================================
// Handler
// =====================================================================

pub fn designPagesGetHandler(
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
            error.PageNotFound => 404,
            error.GetFailed => 500,
            error.OutOfMemory => 500,
        };
        const message: []const u8 = switch (err) {
            error.WorkspaceIdRequired => "workspace_id required",
            error.ItemIdRequired => "item_id required",
            error.PageIdRequired => "page_id required",
            error.PageNotFound => "Page not found",
            error.GetFailed => "Failed to get design page",
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
