//! `POST /api/workspaces/:workspace_id/items/design`.
//!
//! Creates a new workspace item of `item_type='design'` (HTML canvas).
//! No schema migration needed — `item_type` is a free-form TEXT column,
//! so we just write the literal `'design'` at INSERT time.
//!
//! Body: `{name}` — `name` is required. Returns `{id, workspace_id,
//! item_type:"design", name, position, pages:[]}` (201).
//!
//! No SSE events are emitted on creation (the design item starts with
//! zero pages; the frontend re-fetches the page list as soon as the
//! user opens the item). Subsequent `set_design_page` /
//! `delete_design_page` tool calls emit `design_page_updated` /
//! `design_page_deleted` events instead.
//!
//! Layered as `useCase` (validate + id gen + INSERT + return JSON)
//! and a thin handler that maps the outcome + errors to status codes.
//!
//! Plan: docs/superpowers/plans/2026-07-05-design-mode.md (Chunk 2,
//! Task 2.1).

const std = @import("std");
const nalarcore = @import("nalarcore");
const gserverz = nalarcore.gserverz;
const helpers = nalarcore.helpers;

/// Request body for the design-item create endpoint.
const CreateDesignBody = struct {
    name: []const u8,
};

/// Response body for the design-item create endpoint.
///
/// `position` is the new item's position within the workspace (computed
/// by the INSERT's correlated subquery as `COALESCE(MAX(position), -1) +
/// 1`); the useCase returns 0 here because `valueAlloc` produces the
/// JSON and the frontend re-fetches positions on its next list call.
/// `pages` is always `[]` on creation (zero pages seeded).
pub const DesignItemsCreateResponse = struct {
    id: []const u8,
    workspace_id: []const u8,
    item_type: []const u8,
    name: []const u8,
    /// Always `0` on the create response — the INSERT's computed
    /// position isn't returned by `db.exec` and the frontend refreshes
    /// the list when it needs accurate positions.
    position: i64 = 0,
    /// Empty on creation. Frontend calls `GET .../design/pages` to
    /// populate the tab strip.
    pages: []const []const u8 = &[_][]const u8{},
};

pub const DesignItemsCreateError = error{
    WorkspaceIdRequired,
    MissingBody,
    InvalidJson,
    NameRequired,
    CreateFailed,
    /// `valueAlloc` for the JSON response can fail with OOM on the
    /// per-request arena. The arena reaps the failure memory, but
    /// the type system requires the variant in the error set.
    OutOfMemory,
};

pub const DesignItemsCreateInput = struct {
    workspace_id: []const u8,
    body: CreateDesignBody,
};

pub const DesignItemsCreateResult = []const u8; // pre-serialized JSON

// =====================================================================
// Use case
// =====================================================================

fn useCase(
    allocator: std.mem.Allocator,
    db: *nalarcore.sqlite.SqliteBackend,
    input: DesignItemsCreateInput,
) DesignItemsCreateError!DesignItemsCreateResult {
    if (input.workspace_id.len == 0) return error.WorkspaceIdRequired;
    if (input.body.name.len == 0) return error.NameRequired;

    // Generate the item id. Same nanosecond-timestamp scheme as
    // `workspace_items_create_kanban.zig` and `workspace_items_create.zig`.
    const ts = helpers.unixTimestampNanos();
    const item_id = try std.fmt.allocPrint(allocator, "item_{d}", .{ts});
    defer allocator.free(item_id);

    // INSERT the row. `item_type='design'` is hard-coded (the column
    // is a free-form TEXT — the design item type is implicit in this
    // endpoint's path). `position` is `COALESCE(MAX(position), -1) + 1`
    // within this workspace, computed by the correlated subquery
    // (mirrors the kanban pattern in `workspace_items_create_kanban.zig`).
    db.exec(allocator,
        "INSERT INTO workspace_items (id, workspace_id, item_type, name, path, position, created_at, updated_at) " ++
        "VALUES (?, ?, 'design', ?, NULL, COALESCE((SELECT MAX(position) FROM workspace_items WHERE workspace_id = ?), -1) + 1, datetime('now'), datetime('now'))",
        &.{ item_id, input.workspace_id, input.body.name, input.workspace_id },
    ) catch return error.CreateFailed;

    return std.json.Stringify.valueAlloc(
        allocator,
        DesignItemsCreateResponse{
            .id = item_id,
            .workspace_id = input.workspace_id,
            .item_type = "design",
            .name = input.body.name,
            // .position and .pages use their default values from the
            // struct definition (0 and empty slice).
        },
        .{},
    ) catch return error.OutOfMemory;
}

// =====================================================================
// Handler
// =====================================================================

pub fn designItemsCreateHandler(
    ctx: gserverz.HttpContext,
    req: gserverz.HttpRequest,
    res: gserverz.HttpResponse,
) !gserverz.HttpResponse {
    const allocator = ctx.allocator;

    const workspace_id = req.params.get("workspace_id") orelse "";

    // HTTP-layer checks: body presence + JSON parse. The semantic
    // checks (workspace_id non-empty, name non-empty) live in the
    // useCase so the useCase is callable from non-HTTP contexts.
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
    const parsed = std.json.parseFromSliceLeaky(CreateDesignBody, allocator, req.body, .{}) catch {
        const http_response = @import("http_response.zig");
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Invalid JSON body" }),
        });
    };

    const di = try nalarcore.getSingleton();
    const data = useCase(allocator, di.db, .{
        .workspace_id = workspace_id,
        .body = parsed,
    }) catch |err| {
        const status: u16 = switch (err) {
            error.WorkspaceIdRequired => 400,
            error.MissingBody => 400,
            error.InvalidJson => 400,
            error.NameRequired => 400,
            error.CreateFailed => 500,
            error.OutOfMemory => 500,
        };
        const message: []const u8 = switch (err) {
            error.WorkspaceIdRequired => "workspace_id required",
            error.MissingBody => "Request body required",
            error.InvalidJson => "Invalid JSON body",
            error.NameRequired => "name is required",
            error.CreateFailed => "Failed to create design item",
            error.OutOfMemory => "Out of memory",
        };
        const http_response = @import("http_response.zig");
        return res.jsonResponse(.{
            .status_code = status,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = message }),
        });
    };

    return res.jsonResponse(.{
        .status_code = 201,
        .data = data,
    });
}
