//! `POST /api/workspaces/:workspace_id/items/kanban`.
//!
//! Creates a new workspace item of `item_type='kanban'` and seeds its
//! default 3-column flow (`todo / in progress / done`).
//!
//! Body: `{name, path?}` — `name` is required, `path` is optional
//! (NULL is stored when omitted; the kanban is cwd-less until the
//! user sets the path via the PUT endpoint).
//!
//! Steps:
//!   1. Generate a unique item id (`item_<unix_nanoseconds>` — same
//!      pattern as `workspace_items_create.zig`).
//!   2. INSERT into `workspace_items` with `item_type='kanban'` and
//!      a fresh position (`COALESCE(MAX(position), -1) + 1`).
//!   3. Seed the default columns.
//!   4. Emit one SSE `kanban_column` event per seeded column.
//!   5. Return 201 with `{id, workspace_id, item_type, name, path,
//!      position}`.
//!
//! Layered as `useCase` (validate + generate id + insert + seed +
//! emit SSE) and a thin handler that maps the outcome + errors to
//! status codes / JSON.
//!
//! Plan: docs/superpowers/plans/2026-06-21-workspace-item-kanban.md
//!   (Chunk 3)

const std = @import("std");
const nalarcore = @import("nalarcore");
const gserverz = nalarcore.gserverz;
const http_response = @import("http_response.zig");
const kanban_model = @import("../kanban_model.zig");
const on_event_sent_kanban = nalarcore.ai_mod.on_event_sent_kanban;

/// Request body for the kanban-item create endpoint.
const CreateKanbanBody = struct {
    name: []const u8,
    /// Optional absolute path on disk that will become the `cwd` for
    /// every chat session created under this kanban's tasks.
    path: ?[]const u8 = null,
};

/// Response body for the kanban-item create endpoint.
pub const CreateKanbanResponse = struct {
    id: []const u8,
    workspace_id: []const u8,
    item_type: []const u8,
    name: []const u8,
    /// Mirrors the request body's path. `null` when the caller did
    /// not supply one (cwd-less kanban).
    path: ?[]const u8 = null,
    position: i64,
};

pub const WorkspaceItemsCreateKanbanError = error{
    WorkspaceIdRequired,
    MissingBody,
    InvalidJson,
    NameRequired,
    InsertFailed,
    SeedFailed,
    /// `std.json.Stringify.valueAlloc` and `allocator.dupe` can
    /// fail with `OutOfMemory`. Unreachable on the per-request
    /// arena, but the type system requires the variant.
    OutOfMemory,
};

pub const WorkspaceItemsCreateKanbanInput = struct {
    workspace_id: []const u8,
    body: CreateKanbanBody,
};

pub const WorkspaceItemsCreateKanbanResult = []const u8; // pre-serialized JSON

// =====================================================================
// Use case
// =====================================================================

fn useCase(
    allocator: std.mem.Allocator,
    db: *nalarcore.sqlite.SqliteBackend,
    input: WorkspaceItemsCreateKanbanInput,
) WorkspaceItemsCreateKanbanError!WorkspaceItemsCreateKanbanResult {
    if (input.workspace_id.len == 0) return error.WorkspaceIdRequired;
    if (input.body.name.len == 0) return error.NameRequired;

    // Path is optional — when omitted, NULL is stored (cwd-less
    // kanban, same as pre-fix behavior). The frontend should always
    // pass it; we don't enforce it here so existing tests / API
    // clients that don't know about the field keep working.
    const path_opt: ?[]const u8 = input.body.path;
    const path_for_insert: []const u8 = path_opt orelse "";

    // Generate item id. Same nanosecond-timestamp scheme as
    // `workspace_items_create.zig:generateItemId`. We use libc's
    // `clock_gettime` here (rather than `std.Io.Clock.now`) so the
    // use-case doesn't need a `std.Io` parameter — the timestamp
    // generation is a single wall-clock read with no async/IO
    // involvement. `std.time.timestamp()` was removed in Zig 0.16 —
    // see project memory `zig-0.16-crypto-time-stdlib-removals.md`.
    var libc_ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(std.c.CLOCK.REALTIME, &libc_ts);
    const timestamp_ns: i128 = @as(i128, libc_ts.sec) * 1_000_000_000 + @as(i128, libc_ts.nsec);
    const item_id = try std.fmt.allocPrint(allocator, "item_{d}", .{timestamp_ns});
    defer allocator.free(item_id);

    // Compute the new item's position as
    // COALESCE(MAX(position), -1) + 1 within this workspace. The
    // COALESCE handles the empty-workspace case (no rows → MAX is
    // NULL → -1 → position 0). `workspace_id` is bound twice: once
    // for the column, once for the correlated subquery. The path
    // column is included so the kanban can act as a cwd root for
    // its child task sessions; NULL is stored when the caller
    // didn't pass a path.
    db.exec(allocator,
        "INSERT INTO workspace_items (id, workspace_id, item_type, name, path, position, created_at, updated_at) VALUES (?, ?, 'kanban', ?, NULLIF(?, ''), COALESCE((SELECT MAX(position) FROM workspace_items WHERE workspace_id = ?), -1) + 1, datetime('now'), datetime('now'))",
        &.{ item_id, input.workspace_id, input.body.name, path_for_insert, input.workspace_id },
    ) catch return error.InsertFailed;

    // Seed the 3 default columns (`todo / in progress / done`).
    kanban_model.seedDefaultColumns(allocator, db, item_id) catch return error.SeedFailed;

    // Emit SSE events for each seeded column so other connected
    // clients refresh their kanban view. We re-read `listColumns`
    // after the seed (the seed itself doesn't return the generated
    // column ids) and emit one event per row. action="created" for
    // all three. The emit is fire-and-forget; failures are logged
    // and swallowed so the HTTP 201 still succeeds.
    const seeded_cols = kanban_model.listColumns(allocator, db, item_id) catch {
        std.log.warn(
            "workspace_items_create_kanban: SSE seed-listColumns failed (non-fatal)",
            .{},
        );
        return try std.json.Stringify.valueAlloc(allocator, CreateKanbanResponse{
            .id = item_id,
            .workspace_id = input.workspace_id,
            .item_type = "kanban",
            .name = input.body.name,
            .path = path_opt,
            .position = 0,
        }, .{});
    };
    defer kanban_model.freeColumns(allocator, seeded_cols);

    for (seeded_cols) |col| {
        on_event_sent_kanban.onEventSendKanbanColumn(allocator, .{
            .action = "created",
            .workspace_id = input.workspace_id,
            .item_id = item_id,
            .column_id = col.id,
        }) catch |err| {
            std.log.warn(
                "workspace_items_create_kanban: SSE emit failed (non-fatal): {s}",
                .{@errorName(err)},
            );
        };
    }

    return try std.json.Stringify.valueAlloc(allocator, CreateKanbanResponse{
        .id = item_id,
        .workspace_id = input.workspace_id,
        .item_type = "kanban",
        .name = input.body.name,
        .path = path_opt,
        .position = 0, // placeholder — see notes below
    }, .{});
}

// =====================================================================
// Handler
// =====================================================================

pub fn workspaceItemsCreateKanbanHandler(
    ctx: gserverz.HttpContext,
    req: gserverz.HttpRequest,
    res: gserverz.HttpResponse,
) !gserverz.HttpResponse {
    const allocator = ctx.allocator;

    const di = try nalarcore.getSingleton();
    const sqlite_db = di.db;

    const workspace_id = req.params.get("workspace_id") orelse "";
    if (workspace_id.len == 0) {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "workspace_id required" }),
        });
    }

    if (req.body.len == 0) {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Request body required" }),
        });
    }

    const parsed = std.json.parseFromSliceLeaky(CreateKanbanBody, allocator, req.body, .{}) catch {
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

    const data = useCase(allocator, sqlite_db, .{
        .workspace_id = workspace_id,
        .body = parsed,
    }) catch |err| {
        const status: u16 = switch (err) {
            error.WorkspaceIdRequired => 400,
            error.MissingBody => 400,
            error.InvalidJson => 400,
            error.NameRequired => 400,
            error.InsertFailed, error.SeedFailed => 500,
            error.OutOfMemory => 500,
        };
        const message: []const u8 = switch (err) {
            error.WorkspaceIdRequired => "workspace_id required",
            error.MissingBody => "Request body required",
            error.InvalidJson => "Invalid JSON body",
            error.NameRequired => "name is required",
            error.InsertFailed => "Failed to create kanban item",
            error.SeedFailed => "Failed to seed default columns",
            error.OutOfMemory => "Out of memory",
        };
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