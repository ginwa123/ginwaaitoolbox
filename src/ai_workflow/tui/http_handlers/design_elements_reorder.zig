//! `POST /api/workspaces/:workspace_id/items/:item_id/design/pages/:page_id/elements/reorder`.
//!
//! Reorder 1+ elements on a page along the z-axis. The 4 modes:
//!   - `bring_to_front`: selected ids jump above all non-selected
//!     elements in the user-specified input order.
//!   - `send_to_back`: mirror of bring_to_front.
//!   - `bring_forward`: each selected swaps with its next non-selected
//!     sibling above (multi-selection moves up by one slot).
//!   - `send_backward`: mirror of bring_forward.
//!
//! Body: `{ mode: "bring_to_front"|"send_to_back"|"bring_forward"|"send_backward",
//!          element_ids: ["elem_a", "elem_b"] }`.
//!
//! Response 200: `{ reordered: <DesignElementResponse>[] }` (top-to-bottom).
//!
//! Errors:
//!   - 400 BadMode, NoElementIds, EmptyElementIds, BadElementId
//!   - 404 PageNotFound
//!   - 500 DbError, OutOfMemory
//!
//! Plan: docs/superpowers/plans/2026-07-29-design-right-click-group-menu.md (Chunk 5)

const std = @import("std");
const nalarcore = @import("nalarcore");
const gserverz = nalarcore.gserverz;
const http_response = @import("http_response.zig");
const design_model = @import("../design_model.zig");

/// Request body shape.
const ReorderElementsBody = struct {
    mode: []const u8,
    element_ids: []const []const u8 = &.{},
};

/// Domain-level error set. The handler maps each variant to an
/// HTTP status code via two exhaustive switches below.
pub const DesignElementsReorderError = error{
    /// `:page_id` path param was missing or empty.
    PageIdRequired,
    /// `mode` field was missing or not one of the 4 valid modes.
    BadMode,
    /// `element_ids` was missing or empty.
    EmptyElementIds,
    /// `design_model.reorderElements` returned `BadElementId`.
    BadElementId,
    /// `design_model.reorderElements` returned `PageNotFound`.
    PageNotFound,
    /// `design_model.reorderElements` returned `CrossPageIds`.
    CrossPageIds,
    /// `design_model.reorderElements` returned `DbError`.
    DbError,
    /// `allocator.dupe` failed while building the output struct.
    OutOfMemory,
};

/// Map a `design_model.ReorderMode` enum variant to its lowercase
/// string form. The wire side (`parsed.mode`) is the string; the
/// model side wants the enum. `std.meta.stringToEnum` does the
/// inverse.
fn modeFromString(s: []const u8) ?design_model.ReorderMode {
    return std.meta.stringToEnum(design_model.ReorderMode, s);
}

pub fn designElementsReorderHandler(
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

    const parsed = std.json.parseFromSliceLeaky(ReorderElementsBody, allocator, req.body, .{}) catch {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Invalid JSON body" }),
        });
    };

    // 2. Translate mode string to enum. Empty / unknown → 400.
    if (parsed.mode.len == 0) {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "mode is required" }),
        });
    }
    const mode = modeFromString(parsed.mode) orelse {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{
                .@"error" = "mode must be one of: bring_to_front, send_to_back, bring_forward, send_backward",
            }),
        });
    };

    // 3. Reject empty element_ids BEFORE the model lookup (defence in
    //    depth — the model would also reject, but we'd waste a
    //    page_id SELECT round-trip).
    if (parsed.element_ids.len == 0) {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "element_ids must be non-empty" }),
        });
    }

    // 4. Delegate to the model.
    const reordered = design_model.reorderElements(allocator, sqlite_db, .{
        .page_id = page_id,
        .mode = mode,
        .element_ids = parsed.element_ids,
    }) catch |err| switch (err) {
        error.BadElementId => {
            return res.jsonResponse(.{
                .status_code = 400,
                .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "One or more element_ids is invalid" }),
            });
        },
        error.PageNotFound => {
            return res.jsonResponse(.{
                .status_code = 404,
                .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Page not found" }),
            });
        },
        error.CrossPageIds => {
            return res.jsonResponse(.{
                .status_code = 409,
                .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "All element_ids must be on the same page" }),
            });
        },
        else => {
            const message: []const u8 = switch (err) {
                error.DbError => "Failed to reorder elements",
                error.OutOfMemory => "Out of memory",
                else => "Internal error",
            };
            return res.jsonResponse(.{
                .status_code = 500,
                .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = message }),
            });
        },
    };
    defer {
        for (reordered) |e| design_model.freeElement(allocator, e);
        allocator.free(reordered);
    }

    // 5. Build the success response (200 OK) with the `{reordered}`
    //    envelope, in top-to-bottom z-order.
    const Response = struct {
        reordered: []const http_response.DesignElementResponse,
    };

    const mapped = try allocator.alloc(http_response.DesignElementResponse, reordered.len);
    defer allocator.free(mapped);
    for (reordered, 0..) |e, i| mapped[i] = http_response.makeDesignElementResponse(e);

    return res.jsonResponse(.{
        .status_code = 200,
        .data = try std.json.Stringify.valueAlloc(
            allocator,
            Response{ .reordered = mapped },
            .{},
        ),
    });
}
