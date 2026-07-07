//! `GET /api/workspaces/:workspace_id/items/:item_id/design/pages/:page_id/elements`.
//!
//! Lists the elements of a design page (metadata only — no html
//! bodies). The frontend calls this once when a tab is activated,
//! then fetches html on demand via `GET /elements/:eid`.
//!
//! Response: `{elements:[DesignElementSummary, ...]}` built via
//! `makeDesignElementListResponse`.
//!
//! Errors:
//!   - 400 missing `page_id` or `item_id`
//!   - 500 DB failure
//!
//! Plan: docs/superpowers/plans/2026-07-06-design-fs-rewrite.md
//!   (Chunk 2, Task 2.6)

const std = @import("std");
const nalarcore = @import("nalarcore");
const gserverz = nalarcore.gserverz;
const http_response = @import("http_response.zig");
const design_model = @import("../design_model.zig");

pub const DesignElementsListError = error{
    PageIdRequired,
    ItemIdRequired,
    ListFailed,
    OutOfMemory,
};

pub const DesignElementsListResult = []const u8; // pre-serialized JSON

fn useCase(
    allocator: std.mem.Allocator,
    db: *nalarcore.sqlite.SqliteBackend,
    item_id: []const u8,
    page_id: []const u8,
) DesignElementsListError!DesignElementsListResult {
    if (item_id.len == 0) return error.ItemIdRequired;
    if (page_id.len == 0) return error.PageIdRequired;

    const elements = design_model.listElements(allocator, db, page_id) catch return error.ListFailed;
    defer design_model.freeElements(allocator, elements);

    return try http_response.makeDesignElementListResponse(allocator, elements);
}

pub fn designPageElementsListHandler(
    ctx: gserverz.HttpContext,
    req: gserverz.HttpRequest,
    res: gserverz.HttpResponse,
) !gserverz.HttpResponse {
    const allocator = ctx.allocator;

    const di = try nalarcore.getSingleton();
    const sqlite_db = di.db;

    const item_id = req.params.get("item_id") orelse "";
    const page_id = req.params.get("page_id") orelse "";

    const data = useCase(allocator, sqlite_db, item_id, page_id) catch |err| {
        const status: u16 = switch (err) {
            error.ItemIdRequired => 400,
            error.PageIdRequired => 400,
            error.ListFailed => 500,
            error.OutOfMemory => 500,
        };
        const message: []const u8 = switch (err) {
            error.ItemIdRequired => "item_id required",
            error.PageIdRequired => "page_id required",
            error.ListFailed => "Failed to list design elements",
            error.OutOfMemory => "Out of memory",
        };
        return res.jsonResponse(.{
            .status_code = status,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = message }),
        });
    };

    return res.jsonResponse(.{ .status_code = 200, .data = data });
}
