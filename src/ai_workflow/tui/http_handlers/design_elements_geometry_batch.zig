//! `POST /api/workspaces/:workspace_id/items/:item_id/design/pages/:page_id/elements/geometry-batch`.
//!
//! Atomic N-element geometry update. Used by the canvas drag/resize
//! handlers when multiple elements are selected (multi-element drag,
//! a `group`/`frame` element being moved). Single SQL transaction
//! (all-or-nothing), single `design_elements_geometry_batch_updated`
//! SSE event carrying the full id context.
//!
//! Body: `{ updates: [{element_id, x?, y?, width?, height?, rotation?}, …] }`
//! At least one `updates` entry is required.
//!
//! Response shape: `{ updated: DesignElementResponse[] }` — the
//! post-batch elements in INPUT order. Built via
//! `std.json.Stringify.valueAlloc`.
//!
//! Errors:
//!   - 400 empty `updates` array (`EmptyUpdates`)
//!   - 400 malformed JSON body
//!   - 404 `:page_id` not found
//!   - 404 any `element_id` not found on the page (`ElementNotFound`)
//!   - 500 DB failure (DbError)
//!
//! Plan: docs/superpowers/plans/2026-07-30-design-drag-debounce-batch.md
//!   (Chunk 1, Task 1.3)

const std = @import("std");
const nalarcore = @import("nalarcore");
const gserverz = nalarcore.gserverz;
const design_model = @import("../design_model.zig");

/// HTTP request body for batch-geometry-update. Each `updates[i]` is a
/// partial geometry patch — only the listed fields are SET in the SQL
/// UPDATE; null fields are left unchanged. At least one field per
/// element is recommended (a fully-empty entry is a no-op UPDATE for
/// that element, which the SQL still happily applies).
const BatchBody = struct {
    updates: []const SingleUpdate = &.{},
};

const SingleUpdate = struct {
    element_id: []const u8 = "",
    x: ?i64 = null,
    y: ?i64 = null,
    width: ?i64 = null,
    height: ?i64 = null,
    rotation: ?f64 = null,
};

/// Domain-level error set for `useCase`. The handler maps each
/// variant to an HTTP status code via a single exhaustive switch.
pub const DesignElementGeometryBatchError = error{
    /// `updates` array was empty — would result in a no-op transaction.
    /// Maps to 400.
    EmptyUpdates,
    /// `design_model.updateElementsBatch` returned `PageNotFound` —
    /// the `:page_id` path param doesn't resolve.
    /// Maps to 404.
    PageNotFound,
    /// One or more `element_id` values didn't resolve on the page.
    /// Whole batch is rejected — no partial writes.
    /// Maps to 404.
    ElementNotFound,
    /// Any DB-level failure (PrepareFailed, ExecuteFailed, BindFailed,
    /// QueryFailed, RowNotFound, DatabaseCorrupt, DiskFull, etc.).
    /// Maps to 500.
    DbError,
    /// `allocator.dupe` / `std.json.Stringify.valueAlloc` failed while
    /// building the response body. Maps to 500.
    OutOfMemory,
};

/// Output of the batch-geometry-update use-case. Heap-owned; caller
/// releases `updated` via `freeElements(allocator, updated)`.
pub const UpdateGeometryBatchOutput = struct {
    updated: []design_model.DesignElement,
};

// =====================================================================
// Use case
// =====================================================================

pub const UseCaseInput = struct {
    page_id: []const u8,
    updates: []const design_model.UpdateElementInput,
};

pub fn useCase(
    allocator: std.mem.Allocator,
    db: *nalarcore.sqlite.SqliteBackend,
    input: UseCaseInput,
) DesignElementGeometryBatchError!UpdateGeometryBatchOutput {
    if (input.updates.len == 0) return error.EmptyUpdates;

    const updated = design_model.updateElementsBatch(allocator, db, .{
        .page_id = input.page_id,
        .updates = input.updates,
    }) catch |err| switch (err) {
        error.EmptyUpdates => return error.EmptyUpdates,
        error.PageNotFound => return error.PageNotFound,
        error.ElementNotFound => return error.ElementNotFound,
        else => return error.DbError,
    };

    return .{ .updated = updated };
}

// =====================================================================
// Handler
// =====================================================================

pub fn designElementsGeometryBatchHandler(
    ctx: gserverz.HttpContext,
    req: gserverz.HttpRequest,
    res: gserverz.HttpResponse,
) !gserverz.HttpResponse {
    const allocator = ctx.allocator;

    const di = try nalarcore.getSingleton();
    const sqlite_db = di.db;

    // 1. Validate the page_id path param. Empty → 400.
    const page_id = req.params.get("page_id") orelse "";
    if (page_id.len == 0) {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try makeErrorJson(allocator, "page_id required"),
        });
    }

    // 2. Validate body presence + JSON shape.
    if (req.body.len == 0) {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try makeErrorJson(allocator, "Request body required"),
        });
    }

    const parsed = std.json.parseFromSliceLeaky(
        BatchBody,
        allocator,
        req.body,
        .{},
    ) catch {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try makeErrorJson(allocator, "Invalid JSON body"),
        });
    };

    // 3. Translate the wire body's `SingleUpdate[]` into
    //    `design_model.UpdateElementInput[]`. Reuse the model struct so
    //    the use-case layer doesn't have to invent its own.
    var inputs_buf: std.ArrayList(design_model.UpdateElementInput) = .empty;
    defer inputs_buf.deinit(allocator);
    for (parsed.updates) |u| {
        // Empty element_id → 400 with an explicit message (the model
        // would also reject these as ElementNotFound, but a clearer
        // 400 here helps the frontend debug its batch construction).
        if (u.element_id.len == 0) {
            return res.jsonResponse(.{
                .status_code = 400,
                .data = try makeErrorJson(allocator, "element_id is required for every update"),
            });
        }
        inputs_buf.append(allocator, .{
            .element_id = u.element_id,
            .x = u.x,
            .y = u.y,
            .width = u.width,
            .height = u.height,
            .rotation = u.rotation,
        }) catch return error.OutOfMemory;
    }

    // 4. Delegate to the use-case.
    const output = useCase(allocator, sqlite_db, .{
        .page_id = page_id,
        .updates = inputs_buf.items,
    }) catch |err| {
        const status: u16 = switch (err) {
            error.EmptyUpdates => 400,
            error.PageNotFound => 404,
            error.ElementNotFound => 404,
            error.DbError => 500,
            error.OutOfMemory => 500,
        };
        const message: []const u8 = switch (err) {
            error.EmptyUpdates => "updates array must contain at least one element",
            error.PageNotFound => "Page not found",
            error.ElementNotFound => "One or more element_ids not found on this page",
            error.DbError => "Failed to update element geometries",
            error.OutOfMemory => "Out of memory",
        };
        return res.jsonResponse(.{
            .status_code = status,
            .data = try makeErrorJson(allocator, message),
        });
    };

    // 4. Build the success response (200 OK). We can't use the
    //    shared `http_response.makeDesignElementResponse` from the
    //    per-element handler without a circular import — instead
    //    serialize via std.json.Stringify.valueAlloc, which
    //    recursively walks the `DesignElement` fields and produces
    //    wire-compatible JSON.
    defer {
        design_model.freeElements(allocator, output.updated);
    }

    return res.jsonResponse(.{
        .status_code = 200,
        .data = try std.json.Stringify.valueAlloc(
            allocator,
            struct {
                updated: []const design_model.DesignElement = output.updated,
            }{ .updated = output.updated },
            .{},
        ),
    });
}

// Local helper — mirrors `http_response.makeErrorResponse` but avoids
// the cross-import. The handler is the only caller; the helper is here
// so the response-building block stays small.
fn makeErrorJson(allocator: std.mem.Allocator, message: []const u8) ![]u8 {
    return try std.json.Stringify.valueAlloc(
        allocator,
        struct {
            @"error": []const u8 = message,
        }{ .@"error" = message },
        .{},
    );
}