//! `POST /api/workspaces/:workspace_id/items/:item_id/design/pages/:page_id/elements/:element_id/resize`.
//!
//! Resize a single element (set absolute x/y/width/height/rotation).
//! Replaces the older "PATCH .../geometry" endpoint, which conflated
//! move with resize.
//!
//! ## Cascade behavior
//!
//! None. Resize is per-element by Figma convention — resizing a
//! group changes ONLY the group's bounding box; the children keep
//! their own positions and sizes. (To translate a whole group, use
//! `/translate` or `/move-batch`.)
//!
//! ## Body
//!
//! `{ "x"?: <int>, "y"?: <int>, "width"?: <int>, "height"?: <int>,
//!   "rotation"?: <float> }` — at least one field is required.
//! A fully-empty body is a client bug (no-op UPDATE) and is
//! rejected with 400.
//!
//! ## Response
//!
//! Single `DesignElement` (post-update). Mirrors the existing
//! `/geometry` endpoint's response shape for back-compat with any
//! caller that already parses a single element.
//!
//! ## Errors
//!
//!   - 400 missing `:element_id` path param
//!   - 400 invalid JSON body
//!   - 400 no geometry fields provided (no-op)
//!   - 404 `:element_id` not found
//!   - 500 DB failure
//!
//! Plan: docs/superpowers/plans/2026-08-06-split-move-resize.md
//!   (Task 1.2: split /geometry into /translate + /resize)

const std = @import("std");
const nalarcore = @import("nalarcore");
const gserverz = nalarcore.gserverz;
const sqlite = nalarcore.sqlite;
const design_model = @import("../agentic_loop/design_model.zig");
const http_response = @import("http_response.zig");

const ResizeBody = struct {
    x: ?i64 = null,
    y: ?i64 = null,
    width: ?i64 = null,
    height: ?i64 = null,
    rotation: ?f64 = null,
};

pub const DesignElementResizeError = error{
    ElementIdRequired,
    /// No geometry fields were provided in the body — would result
    /// in a no-op UPDATE.
    NoChanges,
    ElementNotFound,
    DbError,
    OutOfMemory,
};

pub const ResizeOutput = struct {
    /// The post-update element. Heap-owned.
    element: design_model.DesignElement,
};

pub fn useCase(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    element_id: []const u8,
    x: ?i64,
    y: ?i64,
    width: ?i64,
    height: ?i64,
    rotation: ?f64,
) DesignElementResizeError!ResizeOutput {
    if (element_id.len == 0) return error.ElementIdRequired;

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

    const element = design_model.getElement(allocator, db, updated_id) catch
        return error.ElementNotFound;
    errdefer design_model.freeElement(allocator, element);

    return .{ .element = element };
}

pub fn designElementsResizeHandler(
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

    if (req.body.len == 0) {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try makeErrorJson(allocator, "Request body required"),
        });
    }

    const parsed = std.json.parseFromSliceLeaky(
        ResizeBody,
        allocator,
        req.body,
        .{},
    ) catch {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try makeErrorJson(allocator, "Invalid JSON body"),
        });
    };

    const output = useCase(
        allocator,
        sqlite_db,
        element_id,
        parsed.x,
        parsed.y,
        parsed.width,
        parsed.height,
        parsed.rotation,
    ) catch |err| {
        const status: u16 = switch (err) {
            error.ElementIdRequired => 400,
            error.NoChanges => 400,
            error.ElementNotFound => 404,
            error.DbError => 500,
            error.OutOfMemory => 500,
        };
        const message: []const u8 = switch (err) {
            error.ElementIdRequired => "element_id required",
            error.NoChanges => "At least one of x/y/width/height/rotation is required",
            error.ElementNotFound => "Element not found",
            error.DbError => "Failed to resize element",
            error.OutOfMemory => "Out of memory",
        };
        return res.jsonResponse(.{
            .status_code = status,
            .data = try makeErrorJson(allocator, message),
        });
    };
    defer design_model.freeElement(allocator, output.element);

    return res.jsonResponse(.{
        .status_code = 200,
        .data = try std.json.Stringify.valueAlloc(
            allocator,
            http_response.makeDesignElementResponse(output.element),
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
