//! `PATCH /api/workspaces/:workspace_id/items/:item_id/design/pages/:page_id/elements/:element_id/geometry`.
//!
//! ⚠️  DEPRECATED — replaced by two distinct endpoints:
//!   - `POST .../elements/:element_id/translate` — for moves (delta-based,
//!     cascades to descendants for groups).
//!   - `POST .../elements/:element_id/resize` — for resizes (absolute
//!     fields, no cascade, per-element only by Figma convention).
//!
//! This handler is kept for back-compat with any client still wired
//! to the old single endpoint. New code MUST use /translate or
//! /resize. See `docs/superpowers/plans/2026-08-06-split-move-resize.md`.
//!
//! Update an element's geometry (x/y/width/height/rotation). Used
//! by the canvas drag/resize handlers in `DesignElement.vue` —
//! fires on every pointer-move tick during a drag (debounced on
//! the frontend; this endpoint is the final SAVE on mouseup).
//!
//! Body: `{x?, y?, width?, height?, rotation?}` — all optional.
//! At least one field must be present (a fully-empty body is
//! treated as a client bug and rejected with 400).
//!
//! Response shape: `DesignElementResponse` for the post-update
//! element. Built by `http_response.makeDesignElementResponse`
//! and wrapped via `std.json.Stringify.valueAlloc`.
//!
//! Errors:
//!   - 400 missing `element_id` path param, invalid JSON body, no
//!     geometry fields provided (no-op)
//!   - 404 `element_id` not found
//!   - 500 DB failure
//!
//! Plan: docs/superpowers/plans/2026-07-08-design-mode-redesign.md
//!   (Chunk 3, Task 3.4) — original endpoint.
//! Plan: docs/superpowers/plans/2026-08-06-split-move-resize.md
//!   (Task 2: deprecation — keep working but route new clients to
//!   /translate + /resize).

const std = @import("std");
const pabrikcore = @import("pabrikcore");
const gserverz = pabrikcore.gserverz;
const http_response = @import("http_response.zig");
const design_model = @import("../agentic_loop/design_model.zig");

/// HTTP request body for geometry-update. All fields optional.
const UpdateGeometryBody = struct {
    x: ?i64 = null,
    y: ?i64 = null,
    width: ?i64 = null,
    height: ?i64 = null,
    rotation: ?f64 = null,
};

/// Domain-level error set for `useCase`. The handler maps each
/// variant to an HTTP status code + message via two exhaustive
/// switches.
pub const DesignElementGeometryUpdateError = error{
    /// `:element_id` path param was missing or empty.
    ElementIdRequired,
    /// No geometry fields were provided in the body — would result
    /// in a no-op UPDATE. Maps to 400 so the frontend gets explicit
    /// feedback (instead of silently succeeding).
    NoChanges,
    /// `design_model.updateElement` returned `ElementNotFound`.
    ElementNotFound,
    /// `updateElement` failed for some other DB reason.
    DbError,
    /// Update succeeded but the element wasn't visible in the
    /// subsequent `getElement`.
    ElementNotVisible,
    /// `allocator.dupe` failed while building the output struct.
    OutOfMemory,
    // Note: `FileWriteFailed` is NOT in this set — geometry updates
    // never rewrite the HTML file, so the model layer cannot surface
    // that error here. The spec's "Error mapping" section for
    // geometry does not list FileWriteFailed either.
};

/// Output of the update-geometry use-case.
pub const UpdateGeometryOutput = struct {
    /// The post-update element. Heap-owned by the use-case.
    element: design_model.DesignElement,
};

// =====================================================================
// Use case
// =====================================================================

fn useCase(
    allocator: std.mem.Allocator,
    db: *pabrikcore.sqlite.SqliteBackend,
    element_id: []const u8,
    x: ?i64,
    y: ?i64,
    width: ?i64,
    height: ?i64,
    rotation: ?f64,
) DesignElementGeometryUpdateError!UpdateGeometryOutput {
    if (element_id.len == 0) return error.ElementIdRequired;

    // Detect "no changes" at the use-case boundary.
    const any_change = x != null or y != null or width != null or
        height != null or rotation != null;
    if (!any_change) return error.NoChanges;

    const updated_id = design_model.updateElement(allocator, db, .{
        .element_id = element_id,
        .x = x,
        .y = y,
        .width = width,
        .height = height,
        .rotation = rotation,
    }) catch |err| switch (err) {
        error.ElementNotFound => return error.ElementNotFound,
        else => return error.DbError,
    };
    defer allocator.free(updated_id);

    const element = design_model.getElement(allocator, db, updated_id) catch return error.ElementNotVisible;
    errdefer design_model.freeElement(allocator, element);

    return .{ .element = element };
}

// =====================================================================
// Handler
// =====================================================================

pub fn designElementsGeometryUpdateHandler(
    ctx: gserverz.HttpContext,
    req: gserverz.HttpRequest,
    res: gserverz.HttpResponse,
) !gserverz.HttpResponse {
    const allocator = ctx.allocator;

    const di = try pabrikcore.getSingleton();
    const sqlite_db = di.db;

    // 1. Validate path params + body presence + JSON shape.
    const element_id = req.params.get("element_id") orelse "";
    if (element_id.len == 0) {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "element_id required" }),
        });
    }

    if (req.body.len == 0) {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Request body required" }),
        });
    }

    const parsed = std.json.parseFromSliceLeaky(UpdateGeometryBody, allocator, req.body, .{}) catch {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Invalid JSON body" }),
        });
    };

    // 2. Delegate to the use-case.
    const output = useCase(allocator, sqlite_db, element_id, parsed.x, parsed.y, parsed.width, parsed.height, parsed.rotation) catch |err| {
        const status: u16 = switch (err) {
            error.ElementIdRequired => 400,
            error.NoChanges => 400,
            error.ElementNotFound => 404,
            error.DbError => 500,
            error.ElementNotVisible => 500,
            error.OutOfMemory => 500,
        };
        const message: []const u8 = switch (err) {
            error.ElementIdRequired => "element_id required",
            error.NoChanges => "No geometry fields to update",
            error.ElementNotFound => "Element not found",
            error.DbError => "Failed to update element geometry",
            error.ElementNotVisible => "Element was updated but not visible",
            error.OutOfMemory => "Out of memory",
        };
        return res.jsonResponse(.{
            .status_code = status,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = message }),
        });
    };

    // Free the useCase's heap-owned element slices (no-op on arena).
    defer design_model.freeElement(allocator, output.element);

    // 4. Build the success response (200 OK).
    return res.jsonResponse(.{
        .status_code = 200,
        .data = try std.json.Stringify.valueAlloc(
            allocator,
            http_response.makeDesignElementResponse(output.element),
            .{},
        ),
    });
}

// ===== Tests merged from design_elements_geometry_update_test.zig (2026-09-11 flatten) =====
// Static regression checks for the `PATCH .../elements/:eid/geometry` handler.
// 
// Why this file exists
// ────────────────────
// The element-geometry-update endpoint modifies an element&apos;s
// x/y/width/height/rotation (used by the canvas drag/resize
// handlers). The handler must:
//   1. Parse `{x?, y?, width?, height?, rotation?}` via
//      `parseFromSliceLeaky`.
//   2. Call `design_model.updateElement(allocator, db, .{element_id,
//      x, y, width, height, rotation})`.
//   3. Return 200 with the post-update element as a
//      `DesignElementResponse`.
// 
// These contracts are enforced by static substring checks.
// 
// Plan: docs/superpowers/plans/2026-07-08-design-mode-redesign.md
//   (Chunk 3, Task 3.4)

const testing = std.testing;
const text_normalize = @import("helpers").text_normalize;

const HANDLER_PATH = "src/http_handlers/design_elements_geometry_update.zig";

fn readSource(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const raw = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        path,
        allocator,
        .limited(256 * 1024),
    );
    const normalized = try text_normalize.normalizeLineEndings(allocator, raw);
    allocator.free(raw);
    return normalized;
}

// ─── Contract 1: handler uses parseFromSliceLeaky ────────────────────────

test "design_elements_geometry_update handler parses body with parseFromSliceLeaky" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    if (std.mem.indexOf(u8, source, "parseFromSliceLeaky") == null) {
        std.debug.print(
            "\n!! {s} does not use parseFromSliceLeaky !!\n" ++
                "   The patch-body contract is broken. Switch from `parseFromSlice`\n" ++
                "   to `parseFromSliceLeaky`.\n",
            .{HANDLER_PATH},
        );
        return error.ParseFromSliceLeakyMissing;
    }
}

// ─── Contract 2: handler calls design_model.updateElement ────────────────

test "design_elements_geometry_update handler calls design_model.updateElement" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    if (std.mem.indexOf(u8, source, "design_model.updateElement") == null) {
        std.debug.print(
            "\n!! {s} does not call design_model.updateElement !!\n" ++
                "   The PATCH-geometry contract is broken: the handler must\n" ++
                "   delegate to `design_model.updateElement` with the geometry fields.\n",
            .{HANDLER_PATH},
        );
        return error.UpdateElementCallMissing;
    }
}

// ─── Contract 3: handler returns 200 on success ──────────────────────────

test "design_elements_geometry_update handler returns 200 on success" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    if (std.mem.indexOf(u8, source, ".status_code = 200") == null) {
        std.debug.print(
            "\n!! {s} does not return 200 on success !!\n" ++
                "   Use `.status_code = 200` on the success branch.\n",
            .{HANDLER_PATH},
        );
        return error.Status200Missing;
    }
}

// ─── Contract 4: handler maps ElementNotFound to 404 ─────────────────────

test "design_elements_geometry_update handler maps ElementNotFound to 404" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    if (std.mem.indexOf(u8, source, "error.ElementNotFound => 404") == null) {
        std.debug.print(
            "\n!! {s} does not map ElementNotFound to 404 !!\n" ++
                "   The status contract is broken: missing elements must return 404.\n",
            .{HANDLER_PATH},
        );
        return error.ElementNotFoundStatusMissing;
    }
}

// ─── Contract 5: handler extracts geometry fields from parsed body ───────

test "design_elements_geometry_update handler extracts geometry fields" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    if (std.mem.indexOf(u8, source, "parsed.x") == null or
        std.mem.indexOf(u8, source, "parsed.y") == null)
    {
        std.debug.print(
            "\n!! {s} does not extract parsed.x and parsed.y !!\n" ++
                "   The patch contract is broken: the handler must reference\n" ++
                "   `parsed.x` and `parsed.y` for the new geometry values.\n",
            .{HANDLER_PATH},
        );
        return error.GeometryFieldsMissing;
    }
}

// ─── Contract 6: handler validates the element_id path param ───────────

test "design_elements_geometry_update handler validates element_id path param" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    if (std.mem.indexOf(u8, source, "req.params.get(\"element_id\")") == null) {
        std.debug.print(
            "\n!! {s} does not read the element_id path param !!\n" ++
                "   The path-param contract is broken: the handler must read\n" ++
                "   `req.params.get(\"element_id\")` and return 400 when missing.\n",
            .{HANDLER_PATH},
        );
        return error.ElementIdParamMissing;
    }
}
