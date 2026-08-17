//! `POST /api/workspaces/:workspace_id/items/:item_id/design/pages/:page_id/elements/:element_id/translate`.
//!
//! Translate (move) a single element by a `(dx, dy)` delta. Replaces
//! the older "PATCH .../geometry" endpoint, which conflated move
//! with resize.
//!
//! ## Cascade behavior
//!
//! If the target element is a `group` or `frame`, the server cascades
//! the delta to every transitive descendant of the element via the
//! existing recursive CTE (the same code path used by `move-batch`).
//! This matches Figma's group-drag UX: dragging a group moves its
//! whole subtree, including nested groups.
//!
//! For leaves (rectangle/ellipse/text/image) the cascade is a no-op
//! because leaves have no children — only the leaf itself is
//! translated.
//!
//! ## Body
//!
//! `{ "dx": <int>, "dy": <int> }` — both required. The delta is in
//! design-px (CSS pixels at zoom = 1). Caller is responsible for any
//! zoom conversion (the frontend computes `dx = (clientX - startX) / zoom`).
//!
//! ## Response
//!
//! `{ "updated": [DesignElement, ...] }` — `updated` is an array with
//! either:
//!   - 1 element (leaf translation), OR
//!   - 1 + N elements (group/frame translation: root + every cascadee).
//!
//! Always an array (never a single object) so the frontend's
//! local-mirror loop has uniform shape — the cascade case and the
//! leaf case iterate the same way.
//!
//! ## Errors
//!
//!   - 400 missing `:element_id` path param
//!   - 400 invalid JSON body
//!   - 400 missing `dx` or `dy` field
//!   - 404 `:element_id` not found on the page
//!   - 500 DB failure
//!
//! Plan: docs/superpowers/plans/2026-08-06-split-move-resize.md
//!   (Task 1.1: split /geometry into /translate + /resize)

const std = @import("std");
const nalarcore = @import("nalarcore");
const gserverz = nalarcore.gserverz;
const sqlite = nalarcore.sqlite;
const design_model = @import("../agentic_loop/design_model.zig");

/// HTTP request body. Both `dx` and `dy` are required.
const TranslateBody = struct {
    dx: ?i64 = null,
    dy: ?i64 = null,
};

/// Domain-level error set for `useCase`. The handler maps each
/// variant to an HTTP status code + message.
pub const DesignElementTranslateError = error{
    ElementIdRequired,
    /// `dx` or `dy` was missing from the body.
    MissingDelta,
    ElementNotFound,
    DbError,
    OutOfMemory,
};

pub const TranslateOutput = struct {
    /// The cascaded set of updated elements (1 element for leaves,
    /// 1 + N for group/frame cascade). Heap-owned; caller frees
    /// with `design_model.freeElements`.
    updated: []design_model.DesignElement,
};

pub fn useCase(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    page_id: []const u8,
    element_id: []const u8,
    dx: i64,
    dy: i64,
) DesignElementTranslateError!TranslateOutput {
    if (element_id.len == 0) return error.ElementIdRequired;

    // Look up the element so we can decide single-element vs cascade.
    const target = design_model.getElement(allocator, db, element_id) catch
        |err| switch (err) {
            error.ElementNotFound => return error.ElementNotFound,
            else => return error.DbError,
        };
    defer design_model.freeElement(allocator, target);

    // Cascade if the target is a group/frame. The recursive CTE walks
    // DOWN through `parent_id` and updates the whole subtree in one
    // SQL transaction. For leaves, the cascade CTE returns just the
    // leaf itself (no children to visit), so the UPDATE applies the
    // delta to a single row — identical behaviour to the leaf-only
    // path, just with one extra SELECT.
    if (std.mem.eql(u8, target.elem_type, "group") or
        std.mem.eql(u8, target.elem_type, "frame"))
    {
        const items = [_]design_model.MoveItem{.{
            .element_id = element_id,
            .dx = dx,
            .dy = dy,
        }};
        const updated = design_model.moveElementsWithDescendantsBatch(
            allocator,
            db,
            .{ .page_id = page_id, .items = &items },
        ) catch |err| switch (err) {
            error.EmptyItems => unreachable, // we just constructed 1 item
            error.PageNotFound => return error.DbError,
            error.ElementNotFound => return error.ElementNotFound,
            else => return error.DbError,
        };
        return .{ .updated = updated };
    }

    // Leaf: just translate the single row.
    const updated_id = design_model.updateElement(allocator, db, .{
        .element_id = element_id,
        .x = target.x + dx,
        .y = target.y + dy,
    }) catch |err| switch (err) {
        error.ElementNotFound => return error.ElementNotFound,
        else => return error.DbError,
    };
    defer allocator.free(updated_id);

    const element = design_model.getElement(allocator, db, updated_id) catch
        return error.DbError;

    // Wrap the single element in a 1-element slice so the response
    // shape is uniform with the cascade path. (SSE event for OTHER
    // tabs/clients is emitted by the handler — keeping the useCase
    // pure-model and free of the singleton dependency.)
    const wrapped = try allocator.alloc(design_model.DesignElement, 1);
    wrapped[0] = element;
    return .{ .updated = wrapped };
}

pub fn designElementsTranslateHandler(
    ctx: gserverz.HttpContext,
    req: gserverz.HttpRequest,
    res: gserverz.HttpResponse,
) !gserverz.HttpResponse {
    const allocator = ctx.allocator;

    const di = try nalarcore.getSingleton();
    const sqlite_db = di.db;

    const element_id = req.params.get("element_id") orelse "";
    if (element_id.len == 0) {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try makeErrorJson(allocator, "element_id required"),
        });
    }

    const page_id = req.params.get("page_id") orelse "";
    if (page_id.len == 0) {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try makeErrorJson(allocator, "page_id required"),
        });
    }

    if (req.body.len == 0) {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try makeErrorJson(allocator, "Request body required"),
        });
    }

    const parsed = std.json.parseFromSliceLeaky(
        TranslateBody,
        allocator,
        req.body,
        .{},
    ) catch {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try makeErrorJson(allocator, "Invalid JSON body"),
        });
    };

    const dx = parsed.dx orelse {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try makeErrorJson(allocator, "dx is required"),
        });
    };
    const dy = parsed.dy orelse {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try makeErrorJson(allocator, "dy is required"),
        });
    };

    const output = useCase(allocator, sqlite_db, page_id, element_id, dx, dy) catch |err| {
        const status: u16 = switch (err) {
            error.ElementIdRequired => 400,
            error.MissingDelta => 400,
            error.ElementNotFound => 404,
            error.DbError => 500,
            error.OutOfMemory => 500,
        };
        const message: []const u8 = switch (err) {
            error.ElementIdRequired => "element_id required",
            error.MissingDelta => "dx and dy are both required",
            error.ElementNotFound => "Element not found",
            error.DbError => "Failed to translate element",
            error.OutOfMemory => "Out of memory",
        };
        return res.jsonResponse(.{
            .status_code = status,
            .data = try makeErrorJson(allocator, message),
        });
    };
    defer design_model.freeElements(allocator, output.updated);

    return res.jsonResponse(.{
        .status_code = 200,
        .data = try std.json.Stringify.valueAlloc(
            allocator,
            struct { updated: []const design_model.DesignElement }{ .updated = output.updated },
            .{},
        ),
    });
}

fn makeErrorJson(allocator: std.mem.Allocator, message: []const u8) ![]u8 {
    return try std.json.Stringify.valueAlloc(
        allocator,
        struct { @"error": []const u8 }{ .@"error" = message },
        .{},
    );
}
