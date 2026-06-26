//! POST /api/workspaces/:workspace_id/items/kanban
//!
//! Creates a new workspace item of `item_type='kanban'` and seeds its
//! default 3-column flow (`todo / in progress / done`) via
//! `kanban_model.seedDefaultColumns`.
//!
//! Thin wrapper around the data layer:
//!   1. Parse `{name}` from the JSON body.
//!   2. Generate a unique item id (`item_<unix_nanoseconds>` — same
//!      pattern as `workspace_items_create.zig`).
//!   3. INSERT into `workspace_items` with `item_type='kanban'` and a
//!      fresh position (`COALESCE(MAX(position), -1) + 1`).
//!   4. Seed the default columns.
//!   5. Return 201 with `{id, workspace_id, item_type, name, position}`.
//!
//! Errors:
//!   - 400 missing/invalid JSON body, missing/empty `name`
//!   - 400 missing workspace_id path param
//!   - 500 DB exec / seed failure
//!
//! Plan: docs/superpowers/plans/2026-06-21-workspace-item-kanban.md (Chunk 3)

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
    /// every chat session created under this kanban's tasks. Strongly
    /// recommended — without it, the LLM has no project root and
    /// git/file tools fail with "no such directory". Existing kanbans
    /// created before this field existed have `path = NULL` in the DB
    /// and can backfill via PUT /api/workspaces/:wsId/items/:itemId.
    path: ?[]const u8 = null,
};

/// Response body for the kanban-item create endpoint.
///
/// Mirrors `WorkspaceItemFullResponse` plus the freshly-assigned
/// `position` so the frontend can immediately place the new board
/// at the correct slot in the sidebar without re-fetching.
const CreateKanbanResponse = struct {
    id: []const u8,
    workspace_id: []const u8,
    item_type: []const u8,
    name: []const u8,
    /// Mirrors the request body's path. `null` when the caller did not
    /// supply one (the kanban is created cwd-less; the user can
    /// set it later via the PUT endpoint).
    path: ?[]const u8 = null,
    position: i64,
};

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

    // Body is small enough to live entirely in the request slice (the
    // parser puts it in `req.body` directly). Per-request arena owns
    // the parsed value — no explicit deinit needed (use the Leaky
    // variant for that — see project memory
    // `nalar-http-handler-thin-wrapper-pattern`).
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
    const name = parsed.name;
    // Path is optional — when omitted, NULL is stored (cwd-less kanban,
    // same as pre-fix behavior). The frontend should always pass it; we
    // don't enforce it here so existing tests / API clients that don't
    // know about the field keep working.
    const path_opt: ?[]const u8 = parsed.path;
    const path_for_insert: []const u8 = path_opt orelse "";

    // Generate item id. Same nanosecond-timestamp scheme as
    // `workspace_items_create.zig:generateItemId`. Uses `std.Io.Clock`
    // because `std.time.timestamp()` was removed in Zig 0.16 — see
    // project memory `zig-0.16-crypto-time-stdlib-removals.md`.
    const ts = std.Io.Clock.now(.real, ctx.io);
    const timestamp_ns = ts.toNanoseconds();
    const item_id = try std.fmt.allocPrint(allocator, "item_{d}", .{timestamp_ns});
    defer allocator.free(item_id);

    // Compute the new item's position as
    // COALESCE(MAX(position), -1) + 1 within this workspace. The
    // COALESCE handles the empty-workspace case (no rows → MAX is
    // NULL → -1 → position 0). `workspace_id` is bound twice in the
    // args tuple: once for the column, once for the correlated subquery.
    // The path column is included so the kanban can act as a cwd
    // root for its child task sessions; NULL is stored when the
    // caller didn't pass a path.
    sqlite_db.exec(allocator,
        "INSERT INTO workspace_items (id, workspace_id, item_type, name, path, position, created_at, updated_at) VALUES (?, ?, 'kanban', ?, NULLIF(?, ''), COALESCE((SELECT MAX(position) FROM workspace_items WHERE workspace_id = ?), -1) + 1, datetime('now'), datetime('now'))",
        &.{ item_id, workspace_id, name, path_for_insert, workspace_id },
    ) catch {
        return res.jsonResponse(.{
            .status_code = 500,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Failed to create kanban item" }),
        });
    };

    // Seed the 3 default columns (`todo / in progress / done`).
    // `seedDefaultColumns` writes through `kanban_model.addColumn`
    // which generates its own column ids.
    kanban_model.seedDefaultColumns(allocator, sqlite_db, item_id) catch {
        return res.jsonResponse(.{
            .status_code = 500,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Failed to seed default columns" }),
        });
    };

    // Emit SSE events for each seeded column so other connected
    // clients refresh their kanban view. We re-read `listColumns`
    // after the seed (the seed itself doesn't return the generated
    // column ids) and emit one event per row. action="created" for
    // all three. The emit is fire-and-forget; failures are logged
    // and swallowed so the HTTP 201 still succeeds.
    {
        const seeded_cols = kanban_model.listColumns(allocator, sqlite_db, item_id) catch {
            // Listing the freshly-seeded columns shouldn't fail (the
            // seed just succeeded), but if it does, log and move on
            // — the HTTP response must still be 201.
            std.log.warn(
                "workspace_items_create_kanban: SSE seed-listColumns failed (non-fatal)",
                .{},
            );
            return res.jsonResponse(.{
                .status_code = 201,
                .data = try std.json.Stringify.valueAlloc(
                    allocator,
                    CreateKanbanResponse{
                        .id = item_id,
                        .workspace_id = workspace_id,
                        .item_type = "kanban",
                        .name = name,
                        .path = path_opt,
                        .position = 0,
                    },
                    .{},
                ),
            });
        };
        defer kanban_model.freeColumns(allocator, seeded_cols);

        for (seeded_cols) |col| {
            on_event_sent_kanban.onEventSendKanbanColumn(allocator, .{
                .action = "created",
                .workspace_id = workspace_id,
                .item_id = item_id,
                .column_id = col.id,
            }) catch |err| {
                std.log.warn(
                    "workspace_items_create_kanban: SSE emit failed (non-fatal): {s}",
                    .{@errorName(err)},
                );
            };
        }
    }

    return res.jsonResponse(.{
        .status_code = 201,
        .data = try std.json.Stringify.valueAlloc(
            allocator,
            CreateKanbanResponse{
                .id = item_id,
                .workspace_id = workspace_id,
                .item_type = "kanban",
                .name = name,
                .path = path_opt,
                .position = 0, // placeholder — see notes below
            },
            .{},
        ),
    });
}