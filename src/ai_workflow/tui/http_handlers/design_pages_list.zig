//! `GET /api/workspaces/:workspace_id/items/:item_id/design/pages`.
//!
//! Lists the design pages of a workspace item (item_type='design').
//! Returns metadata only — no html bodies (the v5 file-backed
//! schema: pages have no html column, only `design_page_elements`
//! carry html on disk).
//!
//! Response: `{"pages":[DesignPageSummary, ...]}` built via
//! `makeDesignPageListResponse` (typed envelope, no hand-rolled
//! JSON).
//!
//! Errors:
//!   - 400 missing `item_id`
//!   - 500 DB failure
//!
//! Plan: docs/superpowers/plans/2026-07-06-design-fs-rewrite.md
//!   (Chunk 2, Task 2.1)

const std = @import("std");
const nalarcore = @import("nalarcore");
const gserverz = nalarcore.gserverz;
const http_response = @import("http_response.zig");
const design_model = @import("../design_model.zig");

pub const DesignPagesListError = error{
    ItemIdRequired,
    ListFailed,
    OutOfMemory,
};

pub const DesignPagesListResult = []const u8; // pre-serialized JSON

// =====================================================================
// Use case
// =====================================================================

fn useCase(
    allocator: std.mem.Allocator,
    db: *nalarcore.sqlite.SqliteBackend,
    item_id: []const u8,
) DesignPagesListError!DesignPagesListResult {
    if (item_id.len == 0) return error.ItemIdRequired;

    const pages = design_model.listPages(allocator, db, item_id) catch return error.ListFailed;
    defer design_model.freePageSummaries(allocator, pages);

    return try http_response.makeDesignPageListResponse(allocator, pages);
}

// =====================================================================
// Handler
// =====================================================================

pub fn designPagesListHandler(
    ctx: gserverz.HttpContext,
    req: gserverz.HttpRequest,
    res: gserverz.HttpResponse,
) !gserverz.HttpResponse {
    const allocator = ctx.allocator;

    const di = try nalarcore.getSingleton();
    const sqlite_db = di.db;

    const item_id = req.params.get("item_id") orelse "";

    const data = useCase(allocator, sqlite_db, item_id) catch |err| {
        const status: u16 = switch (err) {
            error.ItemIdRequired => 400,
            error.ListFailed => 500,
            error.OutOfMemory => 500,
        };
        const message: []const u8 = switch (err) {
            error.ItemIdRequired => "item_id required",
            error.ListFailed => "Failed to list design pages",
            error.OutOfMemory => "Out of memory",
        };
        return res.jsonResponse(.{
            .status_code = status,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = message }),
        });
    };

    return res.jsonResponse(.{ .status_code = 200, .data = data });
}
