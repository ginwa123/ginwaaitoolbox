//! `GET /api/workspaces/:workspace_id/items/:item_id/design/pages/:page_id`.
//!
//! Fetch a single design page by id. Returns the full page
//! metadata. Pages have no html column (the file-backed v5
//! schema — only elements store html), so no html is included in
//! the response.
//!
//! Response: `{page: DesignPageFullResponse}` built via
//! `makeDesignPageFullResponse` (typed envelope).
//!
//! Errors:
//!   - 400 missing `item_id` or `page_id` path param
//!   - 404 page not found (`design_model.getPage` returns
//!     `error.PageNotFound`)
//!   - 500 DB failure
//!
//! Plan: docs/superpowers/plans/2026-07-06-design-fs-rewrite.md
//!   (Chunk 2, Task 2.2)

const std = @import("std");
const nalarcore = @import("nalarcore");
const gserverz = nalarcore.gserverz;
const http_response = @import("http_response.zig");
const design_model = @import("../design_model.zig");

pub const DesignPagesGetError = error{
    ItemIdRequired,
    PageIdRequired,
    PageNotFound,
    GetFailed,
    OutOfMemory,
};

pub const DesignPagesGetResult = []const u8; // pre-serialized JSON

fn useCase(
    allocator: std.mem.Allocator,
    db: *nalarcore.sqlite.SqliteBackend,
    item_id: []const u8,
    page_id: []const u8,
) DesignPagesGetError!DesignPagesGetResult {
    if (item_id.len == 0) return error.ItemIdRequired;
    if (page_id.len == 0) return error.PageIdRequired;

    const page = design_model.getPage(allocator, db, page_id) catch |err| {
        if (err == error.PageNotFound) return error.PageNotFound;
        return error.GetFailed;
    };
    defer design_model.freePageFull(allocator, page);

    return try http_response.makeDesignPageFullResponse(allocator, page);
}

pub fn designPagesGetHandler(
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
            error.PageNotFound => 404,
            error.GetFailed => 500,
            error.OutOfMemory => 500,
        };
        const message: []const u8 = switch (err) {
            error.ItemIdRequired => "item_id required",
            error.PageIdRequired => "page_id required",
            error.PageNotFound => "design page not found",
            error.GetFailed => "Failed to fetch design page",
            error.OutOfMemory => "Out of memory",
        };
        return res.jsonResponse(.{
            .status_code = status,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = message }),
        });
    };

    return res.jsonResponse(.{ .status_code = 200, .data = data });
}
