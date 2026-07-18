//! `PATCH /api/workspaces/:workspace_id/items/:item_id/design/pages/:page_id`.
//!
//! Update an existing design page's width/height by id. UPDATE-only;
//! does NOT insert — see `design_pages_create.zig` for the upsert
//! path used by the agent's `set_design_page` tool.
//!
//! Body: `{width: number, height: number}`. Both required, both
//! must validate against `updateDesignPage`'s range (width
//! 320-4096, height 240-4096). Out-of-range is rejected with 400
//! so the frontend gets explicit feedback (no silent clamping).
//!
//! Response shape: `DesignPageResponse` for the post-update page.
//! Built by `http_response.makeDesignPageResponse` and wrapped via
//! `std.json.Stringify.valueAlloc`.
//!
//! Layered as:
//!   - `useCase` — validates input, delegates to
//!     `design_model.updateDesignPage`, returns the post-update
//!     `DesignPage` (heap-owned, must be freed by the caller).
//!   - `designPagesUpdateHandler` — thin orchestrator: parses the
//!     HTTP request, resolves the singleton DB handle, delegates to
//!     `useCase`, maps the use-case outcome to an HTTP response
//!     (200 / 400 / 404 / 500).
//!
//! Errors:
//!   - 400 missing `page_id` path param, invalid JSON body,
//!     out-of-range width / height
//!   - 404 page_id not found in `design_pages`
//!   - 500 DB failure (update, fetch, or consistency violation)
//!
//! Plan: docs/superpowers/plans/2026-07-19-design-canvas-resize-and-zoom.md
//!   (Chunk 1, Task 1.2)

const std = @import("std");
const nalarcore = @import("nalarcore");
const gserverz = nalarcore.gserverz;
const http_response = @import("http_response.zig");
const design_model = @import("../design_model.zig");

/// HTTP request body for page-update. Both fields required; the
/// backend rejects missing or out-of-range with 400.
const UpdatePageBody = struct {
    width: i64,
    height: i64,
};

/// Domain-level error set for `useCase`. The handler maps each
/// variant to an HTTP status code + message via two exhaustive
/// switches (one for status, one for the user-facing message).
///
/// Adding a new variant fails to compile in the handler until both
/// switches are updated — that's intentional, to keep status codes
/// in lockstep with the error set.
pub const DesignPageUpdateError = error{
    /// `:page_id` path param was missing or empty.
    PageIdRequired,
    /// Body `width` field was < 320 or > 4096.
    WidthOutOfRange,
    /// Body `height` field was < 240 or > 4096.
    HeightOutOfRange,
    /// `design_model.updateDesignPage` returned `PageNotFound`
    /// (no row with that `page_id`).
    PageNotFound,
    /// `updateDesignPage` failed for some other DB reason.
    DbError,
    /// `allocator.dupe` failed while building the output struct.
    OutOfMemory,
};

/// Inputs to the update-page use-case. The handler maps the parsed
/// HTTP body + path param into this struct; the use-case is then
/// transport-agnostic.
pub const UpdatePageInput = struct {
    page_id: []const u8,
    width: i64,
    height: i64,
};

/// Output of the update-page use-case.
pub const UpdatePageOutput = struct {
    /// The post-update page. The slice fields are HEAP-OWNED by the
    /// use-case (duplicated out of the internal `listPages` result
    /// so the output survives the useCase's internal `freePages`
    /// defer). Caller MUST free the per-field slices (or pass the
    /// whole struct to `design_model.freePages` wrapped in a
    /// single-element array).
    page: design_model.DesignPage,
};

// =====================================================================
// Use case
// =====================================================================

/// Update an existing design page's width/height.
///
/// Steps:
///   1. Validate `page_id` non-empty.
///   2. Delegate to `design_model.updateDesignPage` (which validates
///      the width/height range and re-fetches the row).
///   3. Return the heap-owned `DesignPage` for the response.
///
/// Allocator-agnostic: works for both the per-request arena
/// (production HTTP handler) and a leak-tracker allocator (unit
/// tests). All allocations are paired with `errdefer` / `defer` for
/// non-arena safety.
fn useCase(
    allocator: std.mem.Allocator,
    db: *nalarcore.sqlite.SqliteBackend,
    input: UpdatePageInput,
) DesignPageUpdateError!UpdatePageOutput {
    if (input.page_id.len == 0) return error.PageIdRequired;

    const page = design_model.updateDesignPage(allocator, db, .{
        .page_id = input.page_id,
        .width = input.width,
        .height = input.height,
    }) catch |err| switch (err) {
        error.PageIdRequired => return error.PageIdRequired,
        error.WidthOutOfRange => return error.WidthOutOfRange,
        error.HeightOutOfRange => return error.HeightOutOfRange,
        error.PageNotFound => return error.PageNotFound,
        else => return error.DbError,
    };

    return .{ .page = page };
}

// =====================================================================
// Handler
// =====================================================================

/// Thin orchestrator over `useCase`. Validates the HTTP request,
/// resolves the singleton DB handle, delegates to `useCase`, and
/// maps the use-case outcome to an HTTP response.
pub fn designPagesUpdateHandler(
    ctx: gserverz.HttpContext,
    req: gserverz.HttpRequest,
    res: gserverz.HttpResponse,
) !gserverz.HttpResponse {
    const allocator = ctx.allocator;

    const di = try nalarcore.getSingleton();
    const sqlite_db = di.db;

    // 1. Validate path params + body presence + JSON shape.
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

    const parsed = std.json.parseFromSliceLeaky(UpdatePageBody, allocator, req.body, .{}) catch {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Invalid JSON body" }),
        });
    };

    // 2. Delegate to the use-case.
    const output = useCase(allocator, sqlite_db, .{
        .page_id = page_id,
        .width = parsed.width,
        .height = parsed.height,
    }) catch |err| {
        // 3. Map the use-case error to an HTTP response. Both
        //    switches are exhaustive over the inferred error set —
        //    adding a new `DesignPageUpdateError` variant will fail
        //    to compile here (intentional, to keep status codes in
        //    sync). No `else` prong needed.
        const status: u16 = switch (err) {
            error.PageIdRequired => 400,
            error.WidthOutOfRange => 400,
            error.HeightOutOfRange => 400,
            error.PageNotFound => 404,
            error.DbError => 500,
            error.OutOfMemory => 500,
        };
        const message: []const u8 = switch (err) {
            error.PageIdRequired => "page_id required",
            error.WidthOutOfRange => "width must be between 320 and 4096",
            error.HeightOutOfRange => "height must be between 240 and 4096",
            error.PageNotFound => "Page not found",
            error.DbError => "Failed to update page",
            error.OutOfMemory => "Out of memory",
        };
        return res.jsonResponse(.{
            .status_code = status,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = message }),
        });
    };

    // Free the useCase's heap-owned page slices. On the per-request
    // arena this is a no-op (the arena reaps at request end) but the
    // explicit frees are defensive + document ownership.
    defer {
        allocator.free(output.page.id);
        allocator.free(output.page.workspace_item_id);
        allocator.free(output.page.name);
        allocator.free(output.page.created_at);
        allocator.free(output.page.updated_at);
    }

    // 4. Build the success response (200 OK — PATCH is an update,
    //    not a creation).
    return res.jsonResponse(.{
        .status_code = 200,
        .data = try std.json.Stringify.valueAlloc(
            allocator,
            http_response.makeDesignPageResponse(output.page),
            .{},
        ),
    });
}
