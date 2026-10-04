//! `GET /api/workspaces/:workspace_id/items/:item_id/design/pages`.
//!
//! List the design pages belonging to a workspace item of
//! `item_type='design'`. Thin wrapper around
//! `design_model.listPages` — no body parsing, just path-param
//! validation, the DB call, and the response envelope.
//!
//! Response shape: `{"pages":[DesignPageResponse, ...], "count": N}`
//! (built by `http_response.makeDesignPageListResponse`). An empty
//! page list returns `{pages: [], count: 0}` with 200 OK — not 404,
//! because "this design has no pages yet" is a normal state.
//!
//! Errors:
//!   - 400 missing `item_id` path param
//!   - 500 DB failure
//!
//! Plan: docs/superpowers/plans/2026-07-08-design-mode-redesign.md
//!   (Chunk 3, Task 3.2)

const std = @import("std");
const pabrikcore = @import("pabrikcore");
const gserverz = pabrikcore.gserverz;
const http_response = @import("http_response.zig");
const design_model = @import("../agentic_loop/design_model.zig");

pub const DesignPagesListError = error{
    ItemIdRequired,
    QueryFailed,
    /// `makeDesignPageListResponse` returns `![]u8` (its body uses
    /// `std.json.Stringify.valueAlloc` which can fail with
    /// `OutOfMemory`). Effectively unreachable on the per-request
    /// arena, but the type system requires the variant.
    OutOfMemory,
};

pub const DesignPagesListResult = []const u8; // pre-serialized JSON

// =====================================================================
// Use case
// =====================================================================

fn useCase(
    allocator: std.mem.Allocator,
    db: *pabrikcore.sqlite.SqliteBackend,
    item_id: []const u8,
) DesignPagesListError!DesignPagesListResult {
    if (item_id.len == 0) return error.ItemIdRequired;

    const pages = design_model.listPages(allocator, db, item_id) catch return error.QueryFailed;
    defer design_model.freePages(allocator, pages);

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

    const di = try pabrikcore.getSingleton();
    const sqlite_db = di.db;

    const item_id = req.params.get("item_id") orelse "";

    const data = useCase(allocator, sqlite_db, item_id) catch |err| {
        const status: u16 = switch (err) {
            error.ItemIdRequired => 400,
            error.QueryFailed => 500,
            error.OutOfMemory => 500,
        };
        const message: []const u8 = switch (err) {
            error.ItemIdRequired => "item_id required",
            error.QueryFailed => "Failed to list design pages",
            error.OutOfMemory => "Out of memory",
        };
        return res.jsonResponse(.{
            .status_code = status,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = message }),
        });
    };

    return res.jsonResponse(.{ .status_code = 200, .data = data });
}
