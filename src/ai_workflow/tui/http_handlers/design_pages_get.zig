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
//! Plan: docs/superpowers/plans/2026-07-05-design-mode.md (Chunk 2,
//! Task 2.4).

const std = @import("std");
const nalarcore = @import("nalarcore");
const gserverz = nalarcore.gserverz;
const http_response = @import("http_response.zig");
const design_model = @import("../design_model.zig");

pub fn designPagesGetHandler(
    ctx: gserverz.HttpContext,
    req: gserverz.HttpRequest,
    res: gserverz.HttpResponse,
) !gserverz.HttpResponse {
    const allocator = ctx.allocator;

    const workspace_id = req.params.get("workspace_id") orelse "";
    const item_id = req.params.get("item_id") orelse "";
    const page_id = req.params.get("page_id") orelse "";
    if (workspace_id.len == 0 or item_id.len == 0 or page_id.len == 0) {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "workspace_id, item_id, and page_id required" }),
        });
    }

    const di = try nalarcore.getSingleton();
    const page = design_model.getPage(allocator, &di.db, page_id) catch |err| switch (err) {
        error.PageNotFound => return res.jsonResponse(.{
            .status_code = 404,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Page not found" }),
        }),
        else => return res.jsonResponse(.{
            .status_code = 500,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Failed to get design page" }),
        }),
    };
    defer design_model.freePageFull(allocator, page);

    return res.jsonResponse(.{
        .status_code = 200,
        .data = try std.json.Stringify.valueAlloc(allocator, page, .{}),
    });
}