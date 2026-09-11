//! `GET /api/workspaces/:workspace_id/items/:item_id/design/pages/:page_id/elements/:element_id/html`.
//!
//! Lazy-load an element's full HTML body. The page+elements GET
//! (`design_pages_get`) deliberately omits HTML bodies to keep the
//! payload small for designs with many elements. The iframe
//! preview fetches bodies via this endpoint as the user selects
//! each element.
//!
//! Response shape: `{"html": string}` (built via
//! `std.json.Stringify.valueAlloc` so the HTML body is properly
//! JSON-escaped — quotes, backslashes, newlines, control chars).
//!
//! Errors:
//!   - 400 missing `element_id` path param
//!   - 404 element not found (or file not found on disk)
//!   - 500 DB / IO failure
//!
//! Plan: docs/superpowers/plans/2026-07-08-design-mode-redesign.md
//!   (Chunk 3, Task 3.4)

const std = @import("std");
const nalarcore = @import("nalarcore");
const gserverz = nalarcore.gserverz;
const http_response = @import("http_response.zig");
const design_model = @import("../../../agentic_loop/design_model.zig");

pub const DesignElementHtmlGetError = error{
    /// `:element_id` path param was missing or empty.
    ElementIdRequired,
    /// `design_model.loadElementHtml` returned `ElementNotFound` or
    /// `FileNotFound` (no row or the file is missing on disk).
    ElementNotFound,
    /// `loadElementHtml` failed for some other DB / IO reason.
    QueryFailed,
    /// `std.json.Stringify.valueAlloc` failed (effectively
    /// unreachable on the per-request arena).
    OutOfMemory,
};

pub const DesignElementHtmlResponse = struct { html: []const u8 };

// =====================================================================
// Use case
// =====================================================================

fn useCase(
    allocator: std.mem.Allocator,
    db: *nalarcore.sqlite.SqliteBackend,
    io: std.Io,
    element_id: []const u8,
) DesignElementHtmlGetError![]u8 {
    if (element_id.len == 0) return error.ElementIdRequired;

    const html = design_model.loadElementHtml(allocator, io, db, element_id) catch |err| switch (err) {
        error.ElementNotFound, error.FileNotFound => return error.ElementNotFound,
        else => return error.QueryFailed,
    };
    defer allocator.free(html);

    const response = DesignElementHtmlResponse{ .html = html };
    return try std.json.Stringify.valueAlloc(allocator, response, .{});
}

// =====================================================================
// Handler
// =====================================================================

pub fn designElementsHtmlGetHandler(
    ctx: gserverz.HttpContext,
    req: gserverz.HttpRequest,
    res: gserverz.HttpResponse,
) !gserverz.HttpResponse {
    const allocator = ctx.allocator;

    const di = try nalarcore.getSingleton();
    const sqlite_db = di.db;

    const element_id = req.params.get("element_id") orelse "";

    const data = useCase(allocator, sqlite_db, ctx.io, element_id) catch |err| {
        const status: u16 = switch (err) {
            error.ElementIdRequired => 400,
            error.ElementNotFound => 404,
            error.QueryFailed => 500,
            error.OutOfMemory => 500,
        };
        const message: []const u8 = switch (err) {
            error.ElementIdRequired => "element_id required",
            error.ElementNotFound => "Element not found",
            error.QueryFailed => "Failed to load element HTML",
            error.OutOfMemory => "Out of memory",
        };
        return res.jsonResponse(.{
            .status_code = status,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = message }),
        });
    };

    return res.jsonResponse(.{ .status_code = 200, .data = data });
}