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

/// Request body for the kanban-item create endpoint.
const CreateKanbanBody = struct {
    name: []const u8,
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
    sqlite_db.exec(allocator,
        "INSERT INTO workspace_items (id, workspace_id, item_type, name, position, created_at, updated_at) VALUES (?, ?, 'kanban', ?, COALESCE((SELECT MAX(position) FROM workspace_items WHERE workspace_id = ?), -1) + 1, datetime('now'), datetime('now'))",
        &.{ item_id, workspace_id, name, workspace_id },
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

    return res.jsonResponse(.{
        .status_code = 201,
        .data = try std.json.Stringify.valueAlloc(
            allocator,
            CreateKanbanResponse{
                .id = item_id,
                .workspace_id = workspace_id,
                .item_type = "kanban",
                .name = name,
                .position = 0, // placeholder — see notes below
            },
            .{},
        ),
    });
}