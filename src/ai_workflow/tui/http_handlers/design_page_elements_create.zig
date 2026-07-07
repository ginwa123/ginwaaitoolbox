//! `POST /api/workspaces/:workspace_id/items/:item_id/design/pages/:page_id/elements`.
//!
//! Create a new design element on a page. Writes the html body
//! to disk at `<workspace_item.path>/.nalar/design/<page_name>/<sanitized>.html`
//! and INSERTs the metadata row.
//!
//! Body: `{name, html, x?, y?, width?, height?, z_index?}` — `name`
//! and `html` are required; the geometry fields default to the
//! schema defaults (375×667 at (0,0), z_index 0).
//!
//! Response: 201 Created with `{element: DesignElementFullResponse}`
//! (re-fetched with the html body so the frontend can render
//! immediately without a follow-up GET). Emits
//! `design_element_created` SSE event.
//!
//! Errors:
//!   - 400 missing/empty body, invalid JSON, missing `name` or
//!     `html`, missing `item_id` or `page_id`, name sanitized to
//!     empty (`error.InvalidFilename`)
//!   - 500 DB / IO failure
//!     (WorkspaceItemPathRequired surfaces as 500 — the design
//!     item has no path so file IO is impossible; the user
//!     must set the path via the workspace item PUT handler.
//!     ElementNotFound/PageNotFound on the model layer surface
//!     as 500 because they're inconsistent, transient errors)
//!
//! Plan: docs/superpowers/plans/2026-07-06-design-fs-rewrite.md
//!   (Chunk 2, Task 2.8)

const std = @import("std");
const nalarcore = @import("nalarcore");
const gserverz = nalarcore.gserverz;
const http_response = @import("http_response.zig");
const design_model = @import("../design_model.zig");
const on_event_sent_design = nalarcore.ai_mod.on_event_sent_design;

const CreateElementBody = struct {
    name: []const u8,
    html: []const u8,
    x: ?i64 = null,
    y: ?i64 = null,
    width: ?i64 = null,
    height: ?i64 = null,
    z_index: ?i64 = null,
};

pub const DesignElementsCreateError = error{
    ItemIdRequired,
    PageIdRequired,
    NameRequired,
    HtmlRequired,
    InvalidFilename,
    PageNotFound,
    WorkspaceItemNotFound,
    WorkspaceItemPathRequired,
    AddFailed,
    FetchFailed,
    OutOfMemory,
};

pub const CreateElementInput = struct {
    item_id: []const u8,
    workspace_id: []const u8,
    page_id: []const u8,
    name: []const u8,
    html: []const u8,
    x: i64,
    y: i64,
    width: i64,
    height: i64,
    z_index: i64,
};

pub const CreateElementOutput = struct {
    element: design_model.DesignPageElementFull,
};

// =====================================================================
// Use case
// =====================================================================

fn useCase(
    allocator: std.mem.Allocator,
    io: std.Io,
    db: *nalarcore.sqlite.SqliteBackend,
    input: CreateElementInput,
) DesignElementsCreateError!CreateElementOutput {
    if (input.item_id.len == 0) return error.ItemIdRequired;
    if (input.page_id.len == 0) return error.PageIdRequired;
    if (input.name.len == 0) return error.NameRequired;
    if (input.html.len == 0) return error.HtmlRequired;

    const new_id = design_model.addElement(
        allocator,
        io,
        db,
        input.page_id,
        input.name,
        input.html,
        input.x,
        input.y,
        input.width,
        input.height,
        input.z_index,
    ) catch |err| {
        return switch (err) {
            error.InvalidFilename => error.InvalidFilename,
            error.PageNotFound => error.PageNotFound,
            error.WorkspaceItemNotFound => error.WorkspaceItemNotFound,
            error.WorkspaceItemPathRequired => error.WorkspaceItemPathRequired,
            else => error.AddFailed,
        };
    };
    defer allocator.free(new_id);

    // Re-fetch the new element so the response carries the html body
    // (the create call doesn't echo the file contents).
    const element = design_model.getElement(allocator, io, db, new_id) catch return error.FetchFailed;
    return .{ .element = element };
}

// =====================================================================
// Handler
// =====================================================================

pub fn designPageElementsCreateHandler(
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

    if (req.body.len == 0) {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Request body required" }),
        });
    }

    const parsed = std.json.parseFromSliceLeaky(CreateElementBody, allocator, req.body, .{}) catch {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Invalid JSON body" }),
        });
    };

    if (parsed.name.len == 0) {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "name is required" }),
        });
    }
    if (parsed.html.len == 0) {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "html is required" }),
        });
    }

    const x = parsed.x orelse 0;
    const y = parsed.y orelse 0;
    const width = parsed.width orelse 375;
    const height = parsed.height orelse 667;
    const z_index = parsed.z_index orelse 0;

    const output = useCase(allocator, io, sqlite_db, .{
        .item_id = item_id,
        .workspace_id = ws_id,
        .page_id = page_id,
        .name = parsed.name,
        .html = parsed.html,
        .x = x,
        .y = y,
        .width = width,
        .height = height,
        .z_index = z_index,
    }) catch |err| {
        const status: u16 = switch (err) {
            error.ItemIdRequired => 400,
            error.PageIdRequired => 400,
            error.NameRequired => 400,
            error.HtmlRequired => 400,
            error.InvalidFilename => 400,
            error.PageNotFound => 500,
            error.WorkspaceItemNotFound => 500,
            error.WorkspaceItemPathRequired => 500,
            error.AddFailed => 500,
            error.FetchFailed => 500,
            error.OutOfMemory => 500,
        };
        const message: []const u8 = switch (err) {
            error.ItemIdRequired => "item_id required",
            error.PageIdRequired => "page_id required",
            error.NameRequired => "name is required",
            error.HtmlRequired => "html is required",
            error.InvalidFilename => "name sanitizes to empty filename",
            error.PageNotFound => "page not found",
            error.WorkspaceItemNotFound => "workspace item not found",
            error.WorkspaceItemPathRequired => "workspace item has no path; set the path first",
            error.AddFailed => "Failed to create element",
            error.FetchFailed => "Failed to fetch created element",
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

    // Build the SSE payload (summary, no html — file on disk is the
    // source of truth). The frontend reads the html via
    // getElement when it renders.
    on_event_sent_design.onEventSendDesignElementCreated(allocator, .{
        .action = "created",
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
        std.log.warn("design_page_elements_create: SSE emit failed (non-fatal): {s}", .{@errorName(err)});
    };

    return res.jsonResponse(.{
        .status_code = 201,
        .data = try http_response.makeDesignElementFullResponse(allocator, output.element),
    });
}
