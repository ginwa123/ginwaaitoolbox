//! `GET /api/workspaces/:workspace_id/items/:item_id/design/pages/:page_id/elements/:element_id`.
//!
//! Fetch a single design element by id, INCLUDING the html body
//! read from disk at `<workspace_item.path>/.nalar/design/<page_name>/<element_name>.html`.
//!
//! Response: `{element: DesignElementFullResponse}` (with html).
//!
//! Errors:
//!   - 400 missing `item_id`, `page_id`, or `element_id`
//!   - 404 element not found
//!   - 500 DB / IO failure
//!
//! Plan: docs/superpowers/plans/2026-07-06-design-fs-rewrite.md
//!   (Chunk 2, Task 2.7)

const std = @import("std");
const nalarcore = @import("nalarcore");
const gserverz = nalarcore.gserverz;
const http_response = @import("http_response.zig");
const design_model = @import("../design_model.zig");

pub const DesignElementsGetError = error{
    ItemIdRequired,
    PageIdRequired,
    ElementIdRequired,
    ElementNotFound,
    GetFailed,
    OutOfMemory,
};

pub const DesignElementsGetResult = []const u8;

fn useCase(
    allocator: std.mem.Allocator,
    io: std.Io,
    db: *nalarcore.sqlite.SqliteBackend,
    item_id: []const u8,
    page_id: []const u8,
    element_id: []const u8,
) DesignElementsGetError!DesignElementsGetResult {
    if (item_id.len == 0) return error.ItemIdRequired;
    if (page_id.len == 0) return error.PageIdRequired;
    if (element_id.len == 0) return error.ElementIdRequired;

    const element = design_model.getElement(allocator, io, db, element_id) catch |err| {
        if (err == error.ElementNotFound) return error.ElementNotFound;
        return error.GetFailed;
    };

    return try http_response.makeDesignElementFullResponse(allocator, element);
}

pub fn designPageElementsGetHandler(
    ctx: gserverz.HttpContext,
    req: gserverz.HttpRequest,
    res: gserverz.HttpResponse,
) !gserverz.HttpResponse {
    const allocator = ctx.allocator;
    const io = ctx.io;

    const di = try nalarcore.getSingleton();
    const sqlite_db = di.db;

    const item_id = req.params.get("item_id") orelse "";
    const page_id = req.params.get("page_id") orelse "";
    const element_id = req.params.get("element_id") orelse "";

    const data = useCase(allocator, io, sqlite_db, item_id, page_id, element_id) catch |err| {
        const status: u16 = switch (err) {
            error.ItemIdRequired => 400,
            error.PageIdRequired => 400,
            error.ElementIdRequired => 400,
            error.ElementNotFound => 404,
            error.GetFailed => 500,
            error.OutOfMemory => 500,
        };
        const message: []const u8 = switch (err) {
            error.ItemIdRequired => "item_id required",
            error.PageIdRequired => "page_id required",
            error.ElementIdRequired => "element_id required",
            error.ElementNotFound => "design element not found",
            error.GetFailed => "Failed to fetch design element",
            error.OutOfMemory => "Out of memory",
        };
        return res.jsonResponse(.{
            .status_code = status,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = message }),
        });
    };

    return res.jsonResponse(.{ .status_code = 200, .data = data });
}
