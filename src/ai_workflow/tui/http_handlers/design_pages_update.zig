//! `PUT /api/workspaces/:workspace_id/items/:item_id/design/pages/:page_id`.
//!
//! Replace a design page's HTML body. Emits a `design_page_updated`
//! SSE event on success so other connected clients refresh their
//! canvas (mirrors the kanban_columns_update.zig pattern).
//!
//! Body: `{html}` — `html` is required.
//!
//! Errors:
//!   - 400 missing path params / body / html
//!   - 404 page does not exist
//!   - 413 html > 5 MB
//!   - 500 DB failure
//!
//! Layered as `useCase` (validate + size check + update + refetch +
//! emit SSE + return JSON) and a thin handler that maps the outcome
//! + errors to status codes.
//!
//! Plan: docs/superpowers/plans/2026-07-05-design-mode.md (Chunk 2,
//! Task 2.5).

const std = @import("std");
const nalarcore = @import("nalarcore");
const gserverz = nalarcore.gserverz;
const design_model = @import("../design_model.zig");
const on_event_sent_design = nalarcore.ai_mod.on_event_sent_design;

/// 5 MB hard cap on page HTML size. The frontend's textarea + the
/// LLM tool rarely produce more than ~200 KB; this guards against
/// pathological inputs (huge base64 blobs pasted by mistake).
pub const MAX_HTML_BYTES: usize = 5 * 1024 * 1024;

const UpdatePageBody = struct {
    html: []const u8,
};

pub const DesignPagesUpdateError = error{
    WorkspaceIdRequired,
    ItemIdRequired,
    PageIdRequired,
    MissingBody,
    InvalidJson,
    HtmlTooLarge,
    PageNotFound,
    UpdateFailed,
    RefetchFailed,
    /// `valueAlloc` for the JSON response can fail with OOM on the
    /// per-request arena. The arena reaps the failure memory, but
    /// the type system requires the variant in the error set.
    OutOfMemory,
};

pub const DesignPagesUpdateInput = struct {
    workspace_id: []const u8,
    item_id: []const u8,
    page_id: []const u8,
    body: UpdatePageBody,
};

pub const DesignPagesUpdateResult = []const u8; // pre-serialized JSON

// =====================================================================
// Use case
// =====================================================================

fn useCase(
    allocator: std.mem.Allocator,
    db: *nalarcore.sqlite.SqliteBackend,
    input: DesignPagesUpdateInput,
) DesignPagesUpdateError!DesignPagesUpdateResult {
    if (input.workspace_id.len == 0) return error.WorkspaceIdRequired;
    if (input.item_id.len == 0) return error.ItemIdRequired;
    if (input.page_id.len == 0) return error.PageIdRequired;

    if (input.body.html.len > MAX_HTML_BYTES) return error.HtmlTooLarge;

    const updated = design_model.updatePageHtml(allocator, db, input.page_id, input.body.html) catch return error.UpdateFailed;
    if (!updated) return error.PageNotFound;

    // Re-fetch so we can emit the SSE event with the persisted row
    // (the model just rewrote it; updated_at was bumped by SQLite).
    const page = design_model.getPage(allocator, db, input.page_id) catch return error.RefetchFailed;
    defer design_model.freePageFull(allocator, page);

    // Fire-and-forget SSE event. Logs + swallows failures so the
    // HTTP 200 still succeeds even if no client is subscribed.
    on_event_sent_design.onEventSendDesignPageUpdated(allocator, .{
        .action = "updated",
        .workspace_id = input.workspace_id,
        .item_id = input.item_id,
        .page = .{
            .id = page.id,
            .workspace_item_id = page.workspace_item_id,
            .name = page.name,
            .html = page.html,
            .position = page.position,
            .created_at = page.created_at,
            .updated_at = page.updated_at,
        },
    });

    return std.json.Stringify.valueAlloc(allocator, page, .{}) catch return error.OutOfMemory;
}

// =====================================================================
// Handler
// =====================================================================

pub fn designPagesUpdateHandler(
    ctx: gserverz.HttpContext,
    req: gserverz.HttpRequest,
    res: gserverz.HttpResponse,
) !gserverz.HttpResponse {
    const allocator = ctx.allocator;

    const workspace_id = req.params.get("workspace_id") orelse "";
    const item_id = req.params.get("item_id") orelse "";
    const page_id = req.params.get("page_id") orelse "";

    if (req.body.len == 0) {
        const http_response = @import("http_response.zig");
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Request body required" }),
        });
    }

    // Parse the body. The per-request arena owns the parsed result;
    // no explicit deinit needed (see project memory
    // `custom-http-server-per-request-arena`).
    const parsed = std.json.parseFromSliceLeaky(UpdatePageBody, allocator, req.body, .{}) catch {
        const http_response = @import("http_response.zig");
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Invalid JSON body" }),
        });
    };

    const di = try nalarcore.getSingleton();
    const data = useCase(allocator, di.db, .{
        .workspace_id = workspace_id,
        .item_id = item_id,
        .page_id = page_id,
        .body = parsed,
    }) catch |err| {
        const status: u16 = switch (err) {
            error.WorkspaceIdRequired => 400,
            error.ItemIdRequired => 400,
            error.PageIdRequired => 400,
            error.MissingBody => 400,
            error.InvalidJson => 400,
            error.HtmlTooLarge => 413,
            error.PageNotFound => 404,
            error.UpdateFailed => 500,
            error.RefetchFailed => 500,
            error.OutOfMemory => 500,
        };
        const message: []const u8 = switch (err) {
            error.WorkspaceIdRequired => "workspace_id required",
            error.ItemIdRequired => "item_id required",
            error.PageIdRequired => "page_id required",
            error.MissingBody => "Request body required",
            error.InvalidJson => "Invalid JSON body",
            error.HtmlTooLarge => "html exceeds maximum size of 5 MB",
            error.PageNotFound => "Page not found",
            error.UpdateFailed => "Failed to update design page",
            error.RefetchFailed => "Failed to refetch updated page",
            error.OutOfMemory => "Out of memory",
        };
        const http_response = @import("http_response.zig");
        return res.jsonResponse(.{
            .status_code = status,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = message }),
        });
    };

    return res.jsonResponse(.{
        .status_code = 200,
        .data = data,
    });
}
