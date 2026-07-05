//! `GET /api/workspaces/:workspace_id/items/:item_id/design/pages`.
//!
//! Lists all pages of a design item, ordered by `position`. Excludes
//! the `html` field — lazy-loaded by `design_pages_get`.
//!
//! Plan: docs/superpowers/plans/2026-07-05-design-mode.md (Chunk 2,
//! Task 2.3).

const std = @import("std");
const nalarcore = @import("nalarcore");
const gserverz = nalarcore.gserverz;
const http_response = @import("http_response.zig");
const design_model = @import("../design_model.zig");

pub fn designPagesListHandler(
    ctx: gserverz.HttpContext,
    req: gserverz.HttpRequest,
    res: gserverz.HttpResponse,
) !gserverz.HttpResponse {
    const allocator = ctx.allocator;

    const workspace_id = req.params.get("workspace_id") orelse "";
    const item_id = req.params.get("item_id") orelse "";
    if (workspace_id.len == 0 or item_id.len == 0) {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "workspace_id and item_id required" }),
        });
    }

    const di = try nalarcore.getSingleton();
    const pages = design_model.listPages(allocator, &di.db, item_id) catch {
        return res.jsonResponse(.{
            .status_code = 500,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Failed to list design pages" }),
        });
    };
    defer design_model.freePageSummaries(allocator, pages);

    return res.jsonResponse(.{
        .status_code = 200,
        .data = try std.json.Stringify.valueAlloc(allocator, pages, .{}),
    });
}