//! `PUT /api/workspaces/:workspace_id/items/:item_id/design/pages/:page_id/elements/:element_id`.
//!
//! Partial update of a design element. Any field that's omitted
//! from the body is left unchanged.
//!
//! Body: `{name?, html?, x?, y?, width?, height?, z_index?}` — at
//! least one field must be present.
//!
//!   - `name` change → new on-disk file path (derived from
//!     `sanitizeFilename(name)`). If `html` was also provided in
//!     the same PUT, the new html is written to the new path and
//!     the old file is unlinked. If just `name`, the existing
//!     file is renamed atomically on POSIX.
//!   - `html` change → overwrite the existing file.
//!   - `x`/`y`/`width`/`height`/`z_index` change → column UPDATE.
//!
//! Response: 200 with `{element: DesignElementFullResponse}` (the
//! updated row + html body). Emits `design_element_updated` SSE
//! event.
//!
//! Errors:
//!   - 400 missing `page_id`/`element_id`/`item_id`, empty body,
//!     invalid JSON, empty patch (`error.NothingToUpdate`), name
//!     sanitized to empty (`error.InvalidFilename`)
//!   - 404 element not found (`error.ElementNotFound`)
//!   - 500 DB / IO failure
//!
//! Plan: docs/superpowers/plans/2026-07-06-design-fs-rewrite.md
//!   (Chunk 2, Task 2.9)

const std = @import("std");
const nalarcore = @import("nalarcore");
const gserverz = nalarcore.gserverz;
const http_response = @import("http_response.zig");
const design_model = @import("../design_model.zig");
const on_event_sent_design = nalarcore.ai_mod.on_event_sent_design;

const UpdateElementBody = struct {
    name: ?[]const u8 = null,
    html: ?[]const u8 = null,
    x: ?i64 = null,
    y: ?i64 = null,
    width: ?i64 = null,
    height: ?i64 = null,
    z_index: ?i64 = null,
};

pub const DesignElementsUpdateError = error{
    ItemIdRequired,
    PageIdRequired,
    ElementIdRequired,
    NothingToUpdate,
    InvalidFilename,
    ElementNotFound,
    UpdateFailed,
    FetchFailed,
    OutOfMemory,
};

pub const UpdateElementInput = struct {
    item_id: []const u8,
    workspace_id: []const u8,
    page_id: []const u8,
    element_id: []const u8,
    body: UpdateElementBody,
};

pub const UpdateElementOutput = struct {
    element: design_model.DesignPageElementFull,
};

// =====================================================================
// Use case
// =====================================================================

fn useCase(
    allocator: std.mem.Allocator,
    io: std.Io,
    db: *nalarcore.sqlite.SqliteBackend,
    input: UpdateElementInput,
) DesignElementsUpdateError!UpdateElementOutput {
    if (input.item_id.len == 0) return error.ItemIdRequired;
    if (input.page_id.len == 0) return error.PageIdRequired;
    if (input.element_id.len == 0) return error.ElementIdRequired;

    const body = input.body;
    // Reject empty patches early. The model has its own "nothing to
    // update" sentinel but the SQL `WHERE id = ?` would silently no-op,
    // returning a successful but bogus 200 — better to surface 400.
    if (body.name == null and body.html == null and body.x == null and
        body.y == null and body.width == null and body.height == null and
        body.z_index == null)
    {
        return error.NothingToUpdate;
    }

    const patch: design_model.ElementUpdate = .{
        .html = body.html,
        .x = body.x,
        .y = body.y,
        .width = body.width,
        .height = body.height,
        .z_index = body.z_index,
        .name = body.name,
    };

    design_model.updateElement(allocator, io, db, input.element_id, patch) catch |err| {
        return switch (err) {
            error.InvalidFilename => error.InvalidFilename,
            error.ElementNotFound => error.ElementNotFound,
            error.PageNotFound => error.ElementNotFound,
            else => error.UpdateFailed,
        };
    };

    // Re-fetch so the response carries the html body after a
    // potential name + html update.
    const element = design_model.getElement(allocator, io, db, input.element_id) catch
        return error.FetchFailed;
    return .{ .element = element };
}

// =====================================================================
// Handler
// =====================================================================

pub fn designPageElementsUpdateHandler(
    ctx: gserverz.HttpContext,
    req: gserverz.HttpRequest,
    res: gserverz.HttpResponse,
) !gserverz.HttpResponse {
    const allocator = ctx.allocator;
    const io = ctx.io;

    const di = try nalarcore.getSingleton();
    const sqlite_db = di.db;

    const item_id = req.params.get("item_id") orelse "";
    if (item_id.len == 0) {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "item_id required" }),
        });
    }
    const ws_id = req.params.get("workspace_id") orelse "";
    const page_id = req.params.get("page_id") orelse "";
    if (page_id.len == 0) {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "page_id required" }),
        });
    }
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

    const output = useCase(allocator, io, sqlite_db, .{
        .item_id = item_id,
        .workspace_id = ws_id,
        .page_id = page_id,
        .element_id = element_id,
        .body = parsed,
    }) catch |err| {
        const status: u16 = switch (err) {
            error.ItemIdRequired => 400,
            error.PageIdRequired => 400,
            error.ElementIdRequired => 400,
            error.NothingToUpdate => 400,
            error.InvalidFilename => 400,
            error.ElementNotFound => 404,
            error.UpdateFailed => 500,
            error.FetchFailed => 500,
            error.OutOfMemory => 500,
        };
        const message: []const u8 = switch (err) {
            error.ItemIdRequired => "item_id required",
            error.PageIdRequired => "page_id required",
            error.ElementIdRequired => "element_id required",
            error.NothingToUpdate => "At least one of name/html/x/y/width/height/z_index is required",
            error.InvalidFilename => "name sanitizes to empty filename",
            error.ElementNotFound => "design element not found",
            error.UpdateFailed => "Failed to update design element",
            error.FetchFailed => "Failed to fetch updated design element",
            error.OutOfMemory => "Out of memory",
        };
        return res.jsonResponse(.{
            .status_code = status,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = message }),
        });
    };

    defer {
        allocator.free(output.element.id);
        allocator.free(output.element.page_id);
        allocator.free(output.element.name);
        allocator.free(output.element.file_path);
        allocator.free(output.element.created_at);
        allocator.free(output.element.updated_at);
        allocator.free(output.element.html);
    }

    on_event_sent_design.onEventSendDesignElementUpdated(allocator, .{
        .action = "updated",
        .workspace_id = ws_id,
        .item_id = item_id,
        .page_id = page_id,
        .element = .{
            .id = output.element.id,
            .page_id = output.element.page_id,
            .name = output.element.name,
            .file_path = output.element.file_path,
            .x = output.element.x,
            .y = output.element.y,
            .width = output.element.width,
            .height = output.element.height,
            .z_index = output.element.z_index,
            .position = output.element.position,
        },
    }) catch |err| {
        std.log.warn("design_page_elements_update: SSE emit failed (non-fatal): {s}", .{@errorName(err)});
    };

    return res.jsonResponse(.{
        .status_code = 200,
        .data = try http_response.makeDesignElementFullResponse(allocator, output.element),
    });
}
