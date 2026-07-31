//! `POST /api/workspaces/:workspace_id/items/:item_id/design/pages/:page_id/elements/reparent-batch`.
//!
//! Atomic N-element reparent. Used by the drag-to-reparent UX so
//! dragging 1 or N selected rows into a group uses one round-trip
//! instead of N parallel PUTs.
//!
//! Body: `{ element_ids: ["a","b","c"], new_parent_id: "group_x" | null,
//!          reposition: "last_in_parent" }`.
//!
//! Response 200: `{ updated: DesignElementResponse[] }` in input order.
//!
//! Errors:
//!   - 400 EmptyElementIds, BadElementId, BadNewParentId (leaf type,
//!     missing, or cross-page), BadReparent (cycle)
//!   - 404 PageNotFound
//!   - 409 CrossPageIds
//!   - 500 DbError, OutOfMemory
//!
//! Plan: docs/superpowers/plans/2026-07-30-design-layer-drag-join-or-leave-group.md
//! (Chunk 1b Tasks 1b.2 + 1b.3)

const std = @import("std");
const nalarcore = @import("nalarcore");
const gserverz = nalarcore.gserverz;
const http_response = @import("http_response.zig");
const design_model = @import("../design_model.zig");

/// Request body shape.
const ReparentBatchBody = struct {
    element_ids: []const []const u8 = &.{},
    new_parent_id: ?[]const u8 = null,
    reposition: []const u8 = "",
};

/// Domain-level error set. The handler maps each variant to an
/// HTTP status code via two exhaustive switches below.
pub const DesignElementsReparentError = error{
    /// `:page_id` path param was missing or empty.
    PageIdRequired,
    /// `element_ids` was missing or empty.
    EmptyElementIds,
    /// `new_parent_id` was non-null but the target element doesn't
    /// exist, isn't on this page, or isn't a `group`/`frame`.
    BadNewParentId,
    /// One or more element_ids is missing from the DB.
    BadElementId,
    /// Any element_id is on a different page.
    CrossPageIds,
    /// The batch would close a cycle (atomic rejection — no writes).
    BadReparent,
    /// `design_model.reparentElements` returned `PageNotFound`.
    PageNotFound,
    /// `design_model.reparentElements` returned a DB error.
    DbError,
    /// `allocator.dupe` failed while building the output struct.
    OutOfMemory,
};

/// Translate the wire `reposition` string to the enum. Unknown
/// values silently map to `null` (no position recompute) for
/// forward compatibility.
fn repositionFromString(s: []const u8) ?design_model.RepositionMode {
    if (std.mem.eql(u8, s, "last_in_parent")) return .last_in_parent;
    return null;
}

/// Inputs to the reparent-batch use-case.
pub const ReparentBatchInput = struct {
    page_id: []const u8,
    element_ids: []const []const u8,
    /// null = top-level. The handler passes empty string or null;
    /// both map to "no parent".
    new_parent_id: ?[]const u8,
    reposition: ?design_model.RepositionMode,
};

/// Use case — thin wrapper over `design_model.reparentElements`
/// that maps the model's `anyerror` set to the handler's structured
/// `DesignElementsReparentError`.
pub fn useCase(
    allocator: std.mem.Allocator,
    db: *nalarcore.sqlite.SqliteBackend,
    input: ReparentBatchInput,
) DesignElementsReparentError![]design_model.DesignElement {
    if (input.page_id.len == 0) return error.PageIdRequired;

    return design_model.reparentElements(allocator, db, .{
        .page_id = input.page_id,
        .element_ids = input.element_ids,
        .new_parent_id = input.new_parent_id,
        .reposition = input.reposition orelse .last_in_parent,
    }) catch |err| switch (err) {
        error.EmptyElementIds => return error.EmptyElementIds,
        error.BadElementId => return error.BadElementId,
        error.CrossPageIds => return error.CrossPageIds,
        error.CycleDetected => return error.BadReparent,
        error.BadNewParentId => return error.BadNewParentId,
        error.PageNotFound => return error.PageNotFound,
        else => return error.DbError,
    };
}

/// Thin orchestrator over `useCase`. Validates the HTTP request,
/// delegates, and maps the outcome to an HTTP response.
pub fn designElementsReparentBatchHandler(
    ctx: gserverz.HttpContext,
    req: gserverz.HttpRequest,
    res: gserverz.HttpResponse,
) !gserverz.HttpResponse {
    const allocator = ctx.allocator;

    const di = try nalarcore.getSingleton();
    const sqlite_db = di.db;

    // 1. Validate path params + body presence.
    const page_id = req.params.get("page_id") orelse "";
    if (page_id.len == 0) {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "page_id required" }),
        });
    }

    if (req.body.len == 0) {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Request body required" }),
        });
    }

    const parsed = std.json.parseFromSliceLeaky(ReparentBatchBody, allocator, req.body, .{}) catch {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Invalid JSON body" }),
        });
    };

    // Translate wire `new_parent_id: null` AND `""` to null
    // (SQL COALESCE convention: empty string IS top-level).
    const new_parent_id: ?[]const u8 = if (parsed.new_parent_id) |p|
        if (p.len == 0) null else p
    else
        null;

    // 2. Delegate to the use-case.
    const updated = useCase(allocator, sqlite_db, .{
        .page_id = page_id,
        .element_ids = parsed.element_ids,
        .new_parent_id = new_parent_id,
        .reposition = repositionFromString(parsed.reposition),
    }) catch |err| {
        const status: u16 = switch (err) {
            error.PageIdRequired => 400,
            error.EmptyElementIds => 400,
            error.BadElementId => 400,
            error.BadNewParentId => 400,
            error.BadReparent => 400,
            error.CrossPageIds => 409,
            error.PageNotFound => 404,
            error.DbError => 500,
            error.OutOfMemory => 500,
        };
        const message: []const u8 = switch (err) {
            error.PageIdRequired => "page_id required",
            error.EmptyElementIds => "element_ids must be non-empty",
            error.BadElementId => "One or more element_ids is invalid",
            error.BadNewParentId => "new_parent_id must reference an existing group or frame on this page",
            error.BadReparent => "Reparenting would create a cycle",
            error.CrossPageIds => "All element_ids must be on the same page",
            error.PageNotFound => "Page not found",
            error.DbError => "Failed to reparent elements",
            error.OutOfMemory => "Out of memory",
        };
        return res.jsonResponse(.{
            .status_code = status,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = message }),
        });
    };

    // 3. Free the useCase's heap-owned element slices.
    defer {
        for (updated) |e| design_model.freeElement(allocator, e);
        allocator.free(updated);
    }

    // 4. Build the success response (200 OK with { updated: [...] }).
    const mapped = try allocator.alloc(http_response.DesignElementResponse, updated.len);
    defer allocator.free(mapped);
    for (updated, 0..) |e, i| mapped[i] = http_response.makeDesignElementResponse(e);

    const Response = struct {
        updated: []const http_response.DesignElementResponse,
    };

    return res.jsonResponse(.{
        .status_code = 200,
        .data = try std.json.Stringify.valueAlloc(
            allocator,
            Response{ .updated = mapped },
            .{},
        ),
    });
}