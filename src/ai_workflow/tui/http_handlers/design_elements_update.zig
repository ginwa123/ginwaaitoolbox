//! `PUT /api/workspaces/:workspace_id/items/:item_id/design/pages/:page_id/elements/:element_id`.
//!
//! Update an existing design element. Each non-null field in the
//! request body is SET in the SQL UPDATE; null fields are left
//! unchanged. If `html` is provided, the element's on-disk HTML
//! file is rewritten atomically. Delegates to
//! `design_model.updateElement`.
//!
//! Body: same fields as the create body, all optional. The wire
//! `type` string is translated to the `ElementType` enum.
//!
//! Response shape: `DesignElementResponse` for the updated element.
//! The element is re-fetched via `design_model.getElement` so the
//! response reflects the post-update state (instead of returning
//! just the id like the model does).
//!
//! Errors:
//!   - 400 missing `element_id` path param, invalid JSON body, no
//!     fields provided (no-op), invalid `type` string
//!   - 404 `element_id` not found
//!   - 500 DB failure or file-write failure
//!
//! Plan: docs/superpowers/plans/2026-07-08-design-mode-redesign.md
//!   (Chunk 3, Task 3.3)

const std = @import("std");
const nalarcore = @import("nalarcore");
const gserverz = nalarcore.gserverz;
const http_response = @import("http_response.zig");
const design_model = @import("../design_model.zig");

/// HTTP request body for element-update. All fields optional so
/// callers can PATCH a single field at a time (the wire shape is
/// the same for PUT and PATCH in this design — the route paths
/// differ). The `type` field is the wire string; translated to
/// the `ElementType` enum at the handler boundary.
const UpdateElementBody = struct {
    name: ?[]const u8 = null,
    type: ?[]const u8 = null,
    html: ?[]const u8 = null,
    x: ?i64 = null,
    y: ?i64 = null,
    width: ?i64 = null,
    height: ?i64 = null,
    rotation: ?f64 = null,
    fill: ?[]const u8 = null,
    stroke: ?[]const u8 = null,
    stroke_width: ?i64 = null,
    corner_radius: ?i64 = null,
    opacity: ?f64 = null,
    text_content: ?[]const u8 = null,
    text_style: ?[]const u8 = null,
    image_url: ?[]const u8 = null,
    /// Re-parent the element. Semantics:
    ///   - `null` (omitted) — leave parent unchanged.
    ///   - empty string `""` — DETACH (set DB column NULL). The
    ///     element becomes top-level; useful for "ungroup".
    ///   - non-empty string — set parent_id to that value. The
    ///     target must exist on the same page, have type `frame`
    ///     or `group`, and not be a descendant of this element
    ///     (otherwise the model returns `InvalidParent`).
    /// Self-parent (`parent_id == element_id`) is also rejected
    /// with `InvalidParent`.
    parent_id: ?[]const u8 = null,
};

/// Domain-level error set for `useCase`. The handler maps each
/// variant to an HTTP status code + message via two exhaustive
/// switches.
///
/// Adding a new variant fails to compile in the handler until both
/// switches are updated — that's intentional, to keep status codes
/// in lockstep with the error set.
pub const DesignElementUpdateError = error{
    /// `:element_id` path param was missing or empty.
    ElementIdRequired,
    /// `type` field was not a valid `ElementType` enum variant.
    InvalidType,
    /// No fields were provided in the body — would result in a
    /// no-op UPDATE. Maps to 400 so the frontend gets explicit
    /// feedback (instead of silently returning the existing row).
    NoChanges,
    /// `design_model.updateElement` returned `ElementNotFound`
    /// (no row with that `element_id`).
    ElementNotFound,
    /// `design_model.updateElement` returned `FileWriteFailed`
    /// (atomic-rename failed for the new `html` content).
    FileWriteFailed,
    /// `parent_id` was set but failed validation: missing target,
    /// cross-page, target is not a container (`frame`/`group`),
    /// or re-parenting would create a cycle.
    InvalidParent,
    /// `updateElement` failed for some other DB reason.
    DbError,
    /// Update succeeded but the element wasn't visible in the
    /// subsequent `getElement` (consistency violation).
    ElementNotVisible,
    /// `allocator.dupe` failed while building the output struct.
    OutOfMemory,
};

/// Inputs to the update-element use-case.
pub const UpdateElementInput = struct {
    element_id: []const u8,
    name: ?[]const u8,
    elem_type: ?design_model.ElementType,
    html: ?[]const u8,
    x: ?i64,
    y: ?i64,
    width: ?i64,
    height: ?i64,
    rotation: ?f64,
    fill: ?[]const u8,
    stroke: ?[]const u8,
    stroke_width: ?i64,
    corner_radius: ?i64,
    opacity: ?f64,
    text_content: ?[]const u8,
    text_style: ?[]const u8,
    image_url: ?[]const u8,
    parent_id: ?[]const u8,
};

/// Output of the update-element use-case.
pub const UpdateElementOutput = struct {
    /// The updated element (post-update state, via `getElement`).
    /// Heap-owned by the use-case (mirrors the create pattern).
    element: design_model.DesignElement,
};

// =====================================================================
// Use case
// =====================================================================

/// Update a design element.
///
/// Steps:
///   1. Validate `element_id`.
///   2. Call `design_model.updateElement(...)` — returns the
///      element_id (even if no fields changed — see `NoChanges`
///      detection below).
///   3. Re-query via `design_model.getElement(...)` to fetch the
///      full row.
///   4. Return a heap-owned `DesignElement` for the response.
fn useCase(
    allocator: std.mem.Allocator,
    db: *nalarcore.sqlite.SqliteBackend,
    input: UpdateElementInput,
) DesignElementUpdateError!UpdateElementOutput {
    // 1. Validate.
    if (input.element_id.len == 0) return error.ElementIdRequired;

    // 2. Detect "no changes" at the use-case boundary (the model
    //    silently no-ops when only `updated_at` is set; we surface
    //    that as a 400 to the client).
    const any_change = input.name != null or
        input.elem_type != null or
        input.html != null or
        input.x != null or
        input.y != null or
        input.width != null or
        input.height != null or
        input.rotation != null or
        input.fill != null or
        input.stroke != null or
        input.stroke_width != null or
        input.corner_radius != null or
        input.opacity != null or
        input.text_content != null or
        input.text_style != null or
        input.image_url != null or
        input.parent_id != null;
    if (!any_change) return error.NoChanges;

    // 3. Apply the UPDATE.
    const updated_id = design_model.updateElement(allocator, db, .{
        .element_id = input.element_id,
        .name = input.name,
        .elem_type = input.elem_type,
        .html = input.html,
        .x = input.x,
        .y = input.y,
        .width = input.width,
        .height = input.height,
        .rotation = input.rotation,
        .fill = input.fill,
        .stroke = input.stroke,
        .stroke_width = input.stroke_width,
        .corner_radius = input.corner_radius,
        .opacity = input.opacity,
        .text_content = input.text_content,
        .text_style = input.text_style,
        .image_url = input.image_url,
        .parent_id = input.parent_id,
    }) catch |err| switch (err) {
        error.ElementNotFound => return error.ElementNotFound,
        error.FileWriteFailed => return error.FileWriteFailed,
        error.InvalidParent => return error.InvalidParent,
        else => return error.DbError,
    };
    defer allocator.free(updated_id);

    // 4. Re-query to get the full row (post-update state).
    const element = design_model.getElement(allocator, db, updated_id) catch return error.ElementNotVisible;
    errdefer design_model.freeElement(allocator, element);

    return .{ .element = element };
}

// =====================================================================
// Handler
// =====================================================================

/// Thin orchestrator over `useCase`. Validates the HTTP request,
/// resolves the singleton DB handle, delegates to `useCase`, and
/// maps the use-case outcome to an HTTP response.
pub fn designElementsUpdateHandler(
    ctx: gserverz.HttpContext,
    req: gserverz.HttpRequest,
    res: gserverz.HttpResponse,
) !gserverz.HttpResponse {
    const allocator = ctx.allocator;

    const di = try nalarcore.getSingleton();
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

    const parsed = std.json.parseFromSliceLeaky(UpdateElementBody, allocator, req.body, .{}) catch {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Invalid JSON body" }),
        });
    };

    // Translate the wire `type` string to the enum (if provided).
    var elem_type: ?design_model.ElementType = null;
    if (parsed.type) |t| {
        elem_type = std.meta.stringToEnum(design_model.ElementType, t) orelse {
            return res.jsonResponse(.{
                .status_code = 400,
                .data = try http_response.makeErrorResponse(allocator, .{
                    .@"error" = "type must be one of: rectangle, ellipse, text, image, frame, group",
                }),
            });
        };
    }

    // 2. Delegate to the use-case.
    const output = useCase(allocator, sqlite_db, .{
        .element_id = element_id,
        .name = parsed.name,
        .elem_type = elem_type,
        .html = parsed.html,
        .x = parsed.x,
        .y = parsed.y,
        .width = parsed.width,
        .height = parsed.height,
        .rotation = parsed.rotation,
        .fill = parsed.fill,
        .stroke = parsed.stroke,
        .stroke_width = parsed.stroke_width,
        .corner_radius = parsed.corner_radius,
        .opacity = parsed.opacity,
        .text_content = parsed.text_content,
        .text_style = parsed.text_style,
        .image_url = parsed.image_url,
        .parent_id = parsed.parent_id,
    }) catch |err| {
        const status: u16 = switch (err) {
            error.ElementIdRequired => 400,
            error.InvalidType => 400,
            error.NoChanges => 400,
            error.InvalidParent => 400,
            error.ElementNotFound => 404,
            error.FileWriteFailed => 500,
            error.DbError => 500,
            error.ElementNotVisible => 500,
            error.OutOfMemory => 500,
        };
        const message: []const u8 = switch (err) {
            error.ElementIdRequired => "element_id required",
            error.InvalidType => "type must be one of: rectangle, ellipse, text, image, frame, group",
            error.NoChanges => "No fields to update",
            error.InvalidParent => "parent_id must reference a frame or group on the same page (or be empty string to detach)",
            error.ElementNotFound => "Element not found",
            error.FileWriteFailed => "Failed to write element HTML file",
            error.DbError => "Failed to update element",
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

    // 4. Build the success response (200 OK — PUT that updates an
    //    existing resource, not 201 Created).
    return res.jsonResponse(.{
        .status_code = 200,
        .data = try std.json.Stringify.valueAlloc(
            allocator,
            http_response.makeDesignElementResponse(output.element),
            .{},
        ),
    });
}