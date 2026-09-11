//! `POST /api/workspaces/:workspace_id/items/kanban`.
//!
//! Creates a new workspace item of `item_type='kanban'`, seeds its
//! default 3-column flow (`todo / in progress / done`), creates the
//! `agent_kanbans` config row, and seeds default tools
//! (command, read_file, write_file) so a fresh board is immediately usable.
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
const kanban_model = @import("../agentic_loop/kanban_model.zig");
const tools_equipped = @import("../agentic_loop/tools_equipped.zig");
const on_event_sent_kanban = nalarcore.ai_mod.on_event_sent_kanban;
const helpers = @import("helpers");

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

/// Wire envelope for the create endpoint. The frontend's
/// `api.createKanban(workspaceId, name, path)` destructures
/// `{item, columns}` from the response body and pushes the item
/// straight into the workspaces store (see `addKanbanItem` in
/// `src/apps/desktop/src/stores/workspaces.ts`).
///
/// Why the wrapper:
///   - The frontend's `KanbanColumn[]` array is the 3 freshly-seeded
///     default columns (`todo / in progress / done`). Returning them
///     inline saves a follow-up `GET /items/:id/kanban/columns`
///     round-trip — the kanban board renders immediately on the
///     client without a flicker-frame of empty columns.
///   - The flat `CreateKanbanResponse` shape (the original `item`
///     payload alone) caused a UI bug: the frontend's destructure
///     `const { item, columns } = await api.createKanban(...)` got
///     `item` and `columns` as `undefined`, the local store pushed
///     an item with all fields undefined, and the sidebar rendered
///     the `{{ item.name || 'Untitled project' }}` fallback until
///     the user reloaded (the reloaded state came from
///     `getWorkspacesItems`, which has the correct shape). Tests
///     pass because the API mocks return the wrapped shape — the
///     real backend never matched it. Fix: serialize both fields
///     in one envelope so the wire shape matches the contract.
pub const CreateKanbanResponseFull = struct {
    item: CreateKanbanResponse,
    columns: []const kanban_model.KanbanColumn,
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
    // Trim leading/trailing ASCII whitespace and reject empty names.
    // Mirrors `workspace_items_create.zig`'s `EmptyName` validation
    // so both create endpoints have consistent semantics.
    // `std.mem.trim` returns a slice into the same backing
    // `parseFromSliceLeaky` arena, so no allocation needed. Plan:
    // docs/superpowers/plans/2026-07-10-empty-workspace-item-bug.md.
    const trimmed_name = std.mem.trim(u8, input.body.name, " \t\n\r");
    if (trimmed_name.len == 0) return error.NameRequired;

    // Path is optional — when omitted, NULL is stored (cwd-less
    // kanban, same as pre-fix behavior). The frontend should always
    // pass it; we don't enforce it here so existing tests / API
    // clients that don't know about the field keep working.
    const path_opt: ?[]const u8 = input.body.path;
    const path_for_insert: []const u8 = path_opt orelse "";

    // Generate item id. Same nanosecond-timestamp scheme as
    // `workspace_items_create.zig:generateItemId`. We use helpers.unixTimestampNanos
    // here (rather than `std.Io.Clock.now`) so the use-case doesn't need
    // a `std.Io` parameter — the timestamp generation is a single wall-
    // clock read with no async/IO involvement. `std.c.clock_gettime`
    // cannot compile on Windows in Zig 0.16 (clockid_t is void there),
    // which is why we route through the cross-platform helper.
    const timestamp_ns = helpers.unixTimestampNanos();
    const item_id = try std.fmt.allocPrint(allocator, "item_{d}", .{timestamp_ns});
    defer allocator.free(item_id);

    // BEGIN so workspace_item + columns + agent_kanbans + tools are atomic.
    db.exec(allocator, "BEGIN", &[_][]const u8{}) catch return error.InsertFailed;
    errdefer {
        db.exec(allocator, "ROLLBACK", &[_][]const u8{}) catch {};
    }

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
        &.{ item_id, input.workspace_id, trimmed_name, path_for_insert, input.workspace_id },
    ) catch return error.InsertFailed;

    // Seed the 3 default columns (`todo / in progress / done`).
    kanban_model.seedDefaultColumns(allocator, db, item_id) catch return error.SeedFailed;

    // Seed the agent_kanbans config row + default tools (command,
    // read_file, write_file) so a fresh board is immediately usable.
    // INSERT OR IGNORE keeps re-entry safe; tools seed uses OR IGNORE
    // per row so it never trips UNIQUE(kanban_id, tool_name).
    db.exec(allocator,
        "INSERT OR IGNORE INTO agent_kanbans (id, workspace_item_id) VALUES (?, ?)",
        &.{ item_id, item_id },
    ) catch return error.SeedFailed;
    tools_equipped.seedDefaultKanbanTools(allocator, db, item_id) catch return error.SeedFailed;

    db.exec(allocator, "COMMIT", &[_][]const u8{}) catch return error.SeedFailed;

    // Read back the freshly-seeded columns so the response can
    // include them in the `columns` field of the wire envelope.
    // Failures here are logged and swallowed: we still return the
    // created item (with `columns: []`) so the HTTP 201 succeeds —
    // the frontend falls back to a follow-up
    // `GET /items/:id/kanban/columns` via `fetchKanbanColumns` to
    // populate the board if this read fails.
    const seeded_cols = kanban_model.listColumns(allocator, db, item_id) catch {
        std.log.warn(
            \\workspace_items_create_kanban: seed-listColumns failed (non-fatal); returning empty columns array
        ,
            .{},
        );
        return try std.json.Stringify.valueAlloc(allocator, CreateKanbanResponseFull{
            .item = .{
                .id = item_id,
                .workspace_id = input.workspace_id,
                .item_type = "kanban",
                .name = trimmed_name,
                .path = path_opt,
                .position = 0,
            },
            .columns = &[_]kanban_model.KanbanColumn{},
        }, .{});
    };
    defer kanban_model.freeColumns(allocator, seeded_cols);

    // Emit SSE events for each seeded column so other connected
    // clients refresh their kanban view. action="created" for all
    // three. The emit is fire-and-forget; failures are logged and
    // swallowed so the HTTP 201 still succeeds.
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

    // Read the actual position back from the DB so the response
    // mirrors what was persisted. The INSERT computes the position
    // via `COALESCE((SELECT MAX+1), 0)` so we can't know the value
    // without re-reading — the previous code hardcoded `0` here,
    // which would have collided with item ordering had the
    // frontend ever used `position` to sort a fresh response.
    // Non-fatal on read failure: we still return the 201 with
    // `position = 0` and the next refresh from `getWorkspacesItems`
    // will reconcile the value.
    const position = readInsertedPosition(allocator, db, item_id);

    return try std.json.Stringify.valueAlloc(allocator, CreateKanbanResponseFull{
        .item = .{
            .id = item_id,
            .workspace_id = input.workspace_id,
            .item_type = "kanban",
            .name = trimmed_name,
            .path = path_opt,
            .position = position,
        },
        .columns = seeded_cols,
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
    // Trim leading/trailing ASCII whitespace. Reject whitespace-only
    // names at the handler level too (the useCase also rejects
    // them, but checking at both layers keeps the error message
    // localized to the handler-side path). Plan:
    // docs/superpowers/plans/2026-07-10-empty-workspace-item-bug.md.
    if (std.mem.trim(u8, parsed.name, " \t\n\r").len == 0) {
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

/// Re-read the `position` of a freshly-INSERTed workspace_item.
///
/// The kanban-create INSERT computes position via the correlated
/// subquery `COALESCE((SELECT MAX+1), 0)`, so we can't know the
/// persisted value without a follow-up SELECT. This helper does
/// that SELECT and returns the value, falling back to `0` on any
/// failure (the next refresh from `getWorkspacesItems` will
/// reconcile the value if the SELECT genuinely failed — non-fatal
/// because the create itself already succeeded).
///
/// Extracted from `useCase` so the useCase body stays a single
/// straight-line flow (the inline `if (db.query) |q| { defer
/// q.deinit(); if (q.next()) |row| { ... } }` form ran into a
/// "captured `row` is const" issue that's much cleaner to express
/// in a dedicated function with `var q = db.query(...) catch`).
fn readInsertedPosition(
    allocator: std.mem.Allocator,
    db: *nalarcore.sqlite.SqliteBackend,
    item_id: []const u8,
) i64 {
    var q = db.query(allocator,
        "SELECT position FROM workspace_items WHERE id = ?",
        &.{item_id},
    ) catch return 0;
    defer q.deinit();
    // `try` would propagate the error and abort the 201 — we want
    // a best-effort read, so swallow the error and fall through.
    if (q.next() catch null) |row| {
        defer row.deinit(allocator);
        return std.fmt.parseInt(i64, row.values[0], 10) catch 0;
    }
    return 0;
}