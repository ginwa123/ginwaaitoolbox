//! `GET /api/workspaces/:workspace_id/items/:item_id/design/pages`.
//!
//! Lists all pages of a design item, ordered by `position`. Excludes
//! the `html` field — lazy-loaded by `design_pages_get`.
//!
//! Layered as `useCase` (validate + list + return JSON) and a thin
//! handler that maps the outcome + errors to status codes.
//!
//! Plan: docs/superpowers/plans/2026-07-05-design-mode.md (Chunk 2,
//! Task 2.3).

const std = @import("std");
const nalarcore = @import("nalarcore");
const gserverz = nalarcore.gserverz;
const design_model = @import("../design_model.zig");

pub const DesignPagesListError = error{
    WorkspaceIdRequired,
    ItemIdRequired,
    ListFailed,
    /// `valueAlloc` for the JSON response can fail with OOM on the
    /// per-request arena. The arena reaps the failure memory, but
    /// the type system requires the variant in the error set.
    OutOfMemory,
};

pub const DesignPagesListInput = struct {
    workspace_id: []const u8,
    item_id: []const u8,
};

pub const DesignPagesListResult = []const u8; // pre-serialized JSON

// =====================================================================
// Use case
// =====================================================================

fn useCase(
    allocator: std.mem.Allocator,
    db: *nalarcore.sqlite.SqliteBackend,
    input: DesignPagesListInput,
) DesignPagesListError!DesignPagesListResult {
    if (input.workspace_id.len == 0) return error.WorkspaceIdRequired;
    if (input.item_id.len == 0) return error.ItemIdRequired;

    const pages = design_model.listPages(allocator, db, input.item_id) catch return error.ListFailed;
    defer design_model.freePageSummaries(allocator, pages);

    return std.json.Stringify.valueAlloc(allocator, pages, .{}) catch return error.OutOfMemory;
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

    const workspace_id = req.params.get("workspace_id") orelse "";
    const item_id = req.params.get("item_id") orelse "";

    const di = try nalarcore.getSingleton();
    const data = useCase(allocator, di.db, .{
        .workspace_id = workspace_id,
        .item_id = item_id,
    }) catch |err| {
        const status: u16 = switch (err) {
            error.WorkspaceIdRequired => 400,
            error.ItemIdRequired => 400,
            error.ListFailed => 500,
            error.OutOfMemory => 500,
        };
        const message: []const u8 = switch (err) {
            error.WorkspaceIdRequired => "workspace_id required",
            error.ItemIdRequired => "item_id required",
            error.ListFailed => "Failed to list design pages",
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
