//! `PATCH /api/workspaces/:workspace_id/items/:item_id/design/pages/:page_id/elements/:element_id/move`.
//!
//! Low-latency x/y update for drag-to-move. Body: `{x, y}` (both
//! required). Calls `design_model.moveElement` which updates
//! `x`, `y`, `updated_at` only — the html file is untouched.
//!
//! Response: 200 with `{element: DesignElementFullResponse}` (the
//! updated row incl. geometry). Emits `design_element_updated` SSE
//! event on success.
//!
//! Errors:
//!   - 400 missing `item_id`/`page_id`/`element_id`, empty body,
//!     invalid JSON, missing `x` or `y`
//!   - 404 element not found
//!   - 500 DB failure
//!
//! Plan: docs/superpowers/plans/2026-07-06-design-fs-rewrite.md
//!   (Chunk 2, Task 2.11)

const std = @import("std");
const nalarcore = @import("nalarcore");
const gserverz = nalarcore.gserverz;
const http_response = @import("http_response.zig");
const design_model = @import("../design_model.zig");
const on_event_sent_design = nalarcore.ai_mod.on_event_sent_design;

const MoveElementBody = struct {
    x: ?i64 = null,
    y: ?i64 = null,
};

pub const DesignElementsMoveError = error{
    ItemIdRequired,
    PageIdRequired,
    ElementIdRequired,
    XRequired,
    YRequired,
    ElementNotFound,
    MoveFailed,
    FetchFailed,
    OutOfMemory,
};

pub const MoveElementInput = struct {
    item_id: []const u8,
    workspace_id: []const u8,
    page_id: []const u8,
    element_id: []const u8,
    x: i64,
    y: i64,
};

pub const MoveElementOutput = struct {
    element: design_model.DesignPageElementFull,
};

fn useCase(
    allocator: std.mem.Allocator,
    io: std.Io,
    db: *nalarcore.sqlite.SqliteBackend,
    input: MoveElementInput,
) DesignElementsMoveError!MoveElementOutput {
    if (input.element_id.len == 0) return error.ElementIdRequired;

    design_model.moveElement(allocator, db, input.element_id, input.x, input.y) catch |err| {
        if (err == error.ElementNotFound) return error.ElementNotFound;
        return error.MoveFailed;
    };
    const element = design_model.getElement(allocator, io, db, input.element_id) catch return error.FetchFailed;
    return .{ .element = element };
}

pub fn designPageElementsMoveHandler(
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

    const parsed = std.json.parseFromSliceLeaky(MoveElementBody, allocator, req.body, .{}) catch {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Invalid JSON body" }),
        });
    };

    if (parsed.x == null) {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "x is required" }),
        });
    }
    if (parsed.y == null) {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "y is required" }),
        });
    }

    const output = useCase(allocator, io, sqlite_db, .{
        .item_id = item_id,
        .workspace_id = ws_id,
        .page_id = page_id,
        .element_id = element_id,
        .x = parsed.x.?,
        .y = parsed.y.?,
    }) catch |err| {
        const status: u16 = switch (err) {
            error.ItemIdRequired => 400,
            error.PageIdRequired => 400,
            error.ElementIdRequired => 400,
            error.XRequired => 400,
            error.YRequired => 400,
            error.ElementNotFound => 404,
            error.MoveFailed => 500,
            error.FetchFailed => 500,
            error.OutOfMemory => 500,
        };
        const message: []const u8 = switch (err) {
            error.ItemIdRequired => "item_id required",
            error.PageIdRequired => "page_id required",
            error.ElementIdRequired => "element_id required",
            error.XRequired => "x is required",
            error.YRequired => "y is required",
            error.ElementNotFound => "design element not found",
            error.MoveFailed => "Failed to move design element",
            error.FetchFailed => "Failed to fetch moved design element",
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
        std.log.warn("design_page_elements_move: SSE emit failed (non-fatal): {s}", .{@errorName(err)});
    };

    return res.jsonResponse(.{
        .status_code = 200,
        .data = try http_response.makeDesignElementFullResponse(allocator, output.element),
    });
}
