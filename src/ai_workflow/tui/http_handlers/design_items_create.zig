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
///
/// `path` is the on-disk project root for any chat session the user
/// later opens from this design's tasks. Mirrors the kanban create
/// contract: the AddDesignDialog requires a path (the user picks a
/// folder before submitting). Optional in the wire format for
/// forward-compat with a "scratch canvas" mode (a future enhancement
/// that would make path-less designs valid); the useCase currently
/// rejects `""` to match the kanban behavior (every chat session
/// needs a cwd for git/file tools).
const CreateDesignBody = struct {
    name: []const u8,
    path: []const u8 = "",
};

/// Response body for the design-item create endpoint.
///
/// `position` is the new item's position within the workspace (computed
/// by the INSERT's correlated subquery as `COALESCE(MAX(position), -1) +
/// 1`); the useCase returns 0 here because `valueAlloc` produces the
/// JSON and the frontend re-fetches positions on its next list call.
/// `path` echoes the input path (or `""` when the row was created
/// path-less via the empty-string → NULL convention). `pages` is
/// always `[]` on creation (zero pages seeded).
pub const DesignItemsCreateResponse = struct {
    id: []const u8,
    workspace_id: []const u8,
    item_type: []const u8,
    name: []const u8,
    /// On-disk project root (the cwd for any chat session opened
    /// from this design's tasks). Mirrors the kanban create
    /// contract. Echoes the input value; `""` when the body omitted
    /// `path` (or sent `""`).
    path: []const u8 = "",
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
    /// Mirrors `kanban_model.AddKanbanError.PathRequired`. The
    /// AddDesignDialog requires a path (the user picks a folder
    /// before submitting); the useCase maps an empty `path` to
    /// this 400 variant for symmetry with kanban.
    PathRequired,
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
    // Mirrors `workspace_items_create_kanban.zig` — the path is
    // required because every chat session opened from this design's
    // tasks needs a cwd for git/file tools. AddDesignDialog enforces
    // this in the UI (the Add button is disabled until a folder is
    // picked); the useCase enforces it again for non-HTTP callers.
    if (input.body.path.len == 0) return error.PathRequired;

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
    //
    // `path` is bound positionally — `SqliteBackend.exec` accepts
    // a `[]const u8` and the `workspace_items.path` column is
    // `TEXT NOT NULL` (i.e. NOT NULL with no default per the
    // original migration; the kanban create handler uses the same
    // positional bind). The empty path was already rejected above
    // (`PathRequired`), so we always have a non-empty slice here.
    db.exec(allocator,
        "INSERT INTO workspace_items (id, workspace_id, item_type, name, path, position, created_at, updated_at) " ++
        "VALUES (?, ?, 'design', ?, ?, COALESCE((SELECT MAX(position) FROM workspace_items WHERE workspace_id = ?), -1) + 1, datetime('now'), datetime('now'))",
        &.{ item_id, input.workspace_id, input.body.name, input.body.path, input.workspace_id },
    ) catch return error.CreateFailed;

    return std.json.Stringify.valueAlloc(
        allocator,
        DesignItemsCreateResponse{
            .id = item_id,
            .workspace_id = input.workspace_id,
            .item_type = "design",
            .name = input.body.name,
            .path = input.body.path,
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
            error.PathRequired => 400,
            error.CreateFailed => 500,
            error.OutOfMemory => 500,
        };
        const message: []const u8 = switch (err) {
            error.WorkspaceIdRequired => "workspace_id required",
            error.MissingBody => "Request body required",
            error.InvalidJson => "Invalid JSON body",
            error.NameRequired => "name is required",
            error.PathRequired => "path is required (project root for chat sessions)",
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
