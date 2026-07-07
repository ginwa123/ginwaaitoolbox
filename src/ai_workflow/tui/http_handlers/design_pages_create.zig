//! `POST /api/workspaces/:workspace_id/items/:item_id/design/pages`.
//!
//! Create (or replace) a design page. The backend model function
//! `design_model.addPage` is idempotent on `(workspace_item_id,
//! name)` — re-issuing with the same name updates width/height/x/y
//! in place and the same row id is preserved (the caller gets the
//! existing id back). So this single endpoint covers CREATE and
//! UPDATE-by-name without a separate PUT handler.
//!
//! Body: `{name, width?, height?, x?, y?}` — name is required; the
//! geometry fields default to the schema defaults (1440×1024 at
//! (0,0)).
//!
//! Response: 201 Created with `{page: DesignPageFullResponse}`.
//! Emits `design_page_created` (first write on a fresh name) or
//! `design_page_updated` (idempotent replacement) SSE event so
//! other connected clients patch the tab strip.
//!
//! Errors:
//!   - 400 missing/empty body, invalid JSON, missing `item_id`,
//!     missing/empty `name`
//!   - 500 DB failure
//!
//! Plan: docs/superpowers/plans/2026-07-06-design-fs-rewrite.md
//!   (Chunk 2, Task 2.3)

const std = @import("std");
const nalarcore = @import("nalarcore");
const gserverz = nalarcore.gserverz;
const http_response = @import("http_response.zig");
const design_model = @import("../design_model.zig");
const on_event_sent_design = nalarcore.ai_mod.on_event_sent_design;

/// Request body for create-page.
const CreatePageBody = struct {
    name: []const u8,
    width: ?i64 = null,
    height: ?i64 = null,
    x: ?i64 = null,
    y: ?i64 = null,
};

pub const DesignPagesCreateError = error{
    ItemIdRequired,
    NameRequired,
    AddPageFailed,
    FetchFailed,
    OutOfMemory,
};

pub const CreatePageInput = struct {
    item_id: []const u8,
    workspace_id: []const u8,
    name: []const u8,
    width: i64,
    height: i64,
    x: i64,
    y: i64,
};

pub const CreatePageOutput = struct {
    page: design_model.DesignPageFull,
    /// "created" when the row did not exist before (first write on
    /// this name); "updated" when the row existed and the geometry
    /// was replaced in place. Drives the SSE event variant.
    was_created: bool,
};

// =====================================================================
// Use case
// =====================================================================

fn useCase(
    allocator: std.mem.Allocator,
    db: *nalarcore.sqlite.SqliteBackend,
    input: CreatePageInput,
) DesignPagesCreateError!CreatePageOutput {
    if (input.item_id.len == 0) return error.ItemIdRequired;
    if (input.name.len == 0) return error.NameRequired;

    // Detect "created" vs "updated" by snapshotting whether the row
    // existed before addPage (addPage is idempotent on
    // (workspace_item_id, name) and does NOT return a discriminator).
    const pre_existed = blk: {
        const lookup = design_model.listPages(allocator, db, input.item_id) catch return error.FetchFailed;
        defer design_model.freePageSummaries(allocator, lookup);
        for (lookup) |p| {
            if (std.mem.eql(u8, p.name, input.name)) break :blk true;
        }
        break :blk false;
    };

    _ = design_model.addPage(
        allocator,
        db,
        input.item_id,
        input.name,
        input.width,
        input.height,
        input.x,
        input.y,
    ) catch return error.AddPageFailed;
    // The new id is discarded — we re-fetch by name below to get the
    // canonical row (full timestamps + the persistent id). The use
    // case's `was_created` discriminator was computed from a
    // pre-addPage lookup, so the new id isn't needed here.

    // Re-fetch to get the canonical row (full timestamps + id).
    const all = design_model.listPages(allocator, db, input.item_id) catch return error.FetchFailed;
    defer design_model.freePageSummaries(allocator, all);

    for (all) |p| {
        if (!std.mem.eql(u8, p.name, input.name)) continue;

        // Duplicate all the strings so the output outlives `all`'s
        // `freePageSummaries` defer.
        var duped_id: ?[]u8 = null;
        var duped_wiid: ?[]u8 = null;
        var duped_name: ?[]u8 = null;
        var duped_ca: ?[]u8 = null;
        var duped_ua: ?[]u8 = null;
        errdefer {
            if (duped_id) |v| allocator.free(v);
            if (duped_wiid) |v| allocator.free(v);
            if (duped_name) |v| allocator.free(v);
            if (duped_ca) |v| allocator.free(v);
            if (duped_ua) |v| allocator.free(v);
        }
        duped_id = try allocator.dupe(u8, p.id);
        duped_wiid = try allocator.dupe(u8, p.workspace_item_id);
        duped_name = try allocator.dupe(u8, p.name);
        duped_ca = try allocator.dupe(u8, p.created_at);
        duped_ua = try allocator.dupe(u8, p.updated_at);

        return .{
            .page = .{
                .id = duped_id.?,
                .workspace_item_id = duped_wiid.?,
                .name = duped_name.?,
                .position = p.position,
                .width = p.width,
                .height = p.height,
                .x = p.x,
                .y = p.y,
                .created_at = duped_ca.?,
                .updated_at = duped_ua.?,
            },
            .was_created = !pre_existed,
        };
    }

    return error.FetchFailed;
}

// =====================================================================
// Handler
// =====================================================================

pub fn designPagesCreateHandler(
    ctx: gserverz.HttpContext,
    req: gserverz.HttpRequest,
    res: gserverz.HttpResponse,
) !gserverz.HttpResponse {
    const allocator = ctx.allocator;

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

    if (req.body.len == 0) {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Request body required" }),
        });
    }

    const parsed = std.json.parseFromSliceLeaky(CreatePageBody, allocator, req.body, .{}) catch {
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

    // Defaults match `Migration055AddDesignPagesAndElements` defaults.
    const width = parsed.width orelse 1440;
    const height = parsed.height orelse 1024;
    const x = parsed.x orelse 0;
    const y = parsed.y orelse 0;

    const output = useCase(allocator, sqlite_db, .{
        .item_id = item_id,
        .workspace_id = ws_id,
        .name = parsed.name,
        .width = width,
        .height = height,
        .x = x,
        .y = y,
    }) catch |err| {
        const status: u16 = switch (err) {
            error.ItemIdRequired => 400,
            error.NameRequired => 400,
            error.AddPageFailed => 500,
            error.FetchFailed => 500,
            error.OutOfMemory => 500,
        };
        const message: []const u8 = switch (err) {
            error.ItemIdRequired => "item_id required",
            error.NameRequired => "name is required",
            error.AddPageFailed => "Failed to add page",
            error.FetchFailed => "Failed to fetch new page",
            error.OutOfMemory => "Out of memory",
        };
        return res.jsonResponse(.{
            .status_code = status,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = message }),
        });
    };

    defer {
        allocator.free(output.page.id);
        allocator.free(output.page.workspace_item_id);
        allocator.free(output.page.name);
        allocator.free(output.page.created_at);
        allocator.free(output.page.updated_at);
    }

    // Fire the right SSE event for the create-vs-update discriminator.
    if (output.was_created) {
        on_event_sent_design.onEventSendDesignPageUpdated(allocator, .{
            .action = "created",
            .workspace_id = ws_id,
            .item_id = item_id,
            .page = .{
                .id = output.page.id,
                .workspace_item_id = output.page.workspace_item_id,
                .name = output.page.name,
                .width = output.page.width,
                .height = output.page.height,
                .x = output.page.x,
                .y = output.page.y,
                .position = output.page.position,
                .created_at = output.page.created_at,
                .updated_at = output.page.updated_at,
            },
        }) catch |err| {
            std.log.warn("design_pages_create: SSE emit failed (non-fatal): {s}", .{@errorName(err)});
        };
    } else {
        on_event_sent_design.onEventSendDesignPageUpdated(allocator, .{
            .action = "updated",
            .workspace_id = ws_id,
            .item_id = item_id,
            .page = .{
                .id = output.page.id,
                .workspace_item_id = output.page.workspace_item_id,
                .name = output.page.name,
                .width = output.page.width,
                .height = output.page.height,
                .x = output.page.x,
                .y = output.page.y,
                .position = output.page.position,
                .created_at = output.page.created_at,
                .updated_at = output.page.updated_at,
            },
        }) catch |err| {
            std.log.warn("design_pages_create: SSE emit failed (non-fatal): {s}", .{@errorName(err)});
        };
    }

    return res.jsonResponse(.{
        .status_code = 201,
        .data = try http_response.makeDesignPageFullResponse(allocator, output.page),
    });
}
