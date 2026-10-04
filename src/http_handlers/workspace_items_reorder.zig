const std = @import("std");
const http_response = @import("http_response.zig");
const pabrikcore = @import("pabrikcore");
const gserverz = pabrikcore.gserverz;
const sqlite = pabrikcore.sqlite;

// ─── Pattern: thin handler + use case in one file ─────────────────────────
//
// Mirrors `workspaces_reorder.zig` exactly, scoped to a single
// workspace's items. The convention is:
//
//   1. The handler (the `pub fn` below) is the *only* export. It
//      does HTTP concerns only: parse the body, extract the URL
//      param (workspace_id) and the body field (ordered_ids),
//      dispatch to the use case, map errors to status codes,
//      render the typed response.
//
//   2. The use case (the private `fn reorderWorkspaceItems` below)
//      holds the business logic. It takes plain Zig types (no
//      `gserverz.HttpRequest`, no JSON), validates, performs the
//      DB writes, and returns a typed `ReorderResult`.
//
//   3. The response is a typed struct in `http_response.zig`
//      rendered via `std.json.Stringify.valueAlloc` — never a
//      manually-formatted JSON string.
//
//   4. The static-check tests in `workspace_items_reorder_test.zig`
//      assert this structural contract.
// ──────────────────────────────────────────────────────────────────────────

/// HTTP handler: POST /api/workspaces/:workspace_id/items/reorder
///
/// URL param: `workspace_id` (the workspace whose items are being
/// reordered).
///
/// Body: { "ordered_ids": ["id1", "id2", ..., "idN"] } (top-to-bottom
/// display order).
///
/// Behavior: assigns position N-1 to ordered_ids[0] (top of the
/// expanded workspace), N-2 to the next, ..., 0 to ordered_ids[N-1]
/// (bottom). With `workspace_items_get.zig` ordering by
/// `position DESC`, the first id in the array appears at the top.
///
/// Idempotent: a second call with the same array leaves the data
/// unchanged. Unknown IDs in the payload are silently skipped
/// (a deleted item shouldn't fail the whole reorder).
pub fn workspaceItemsReorderHandler(
    ctx: gserverz.HttpContext,
    req: gserverz.HttpRequest,
    res: gserverz.HttpResponse,
) !gserverz.HttpResponse {
    const allocator = ctx.allocator;

    // Step 1: extract the workspace_id URL param. The use case
    // trusts its inputs, so we validate up front.
    const workspace_id = req.params.get("workspace_id") orelse "";
    if (workspace_id.len == 0) {
        return res.jsonResponse(.{ .status_code = 400, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "workspace_id required" }) });
    }

    // Step 2: parse the body. Handler is responsible for ALL HTTP
    // parsing.
    const body = req.body;
    if (body.len == 0) {
        return res.jsonResponse(.{ .status_code = 400, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "body required" }) });
    }

    const parsed = std.json.parseFromSliceLeaky(std.json.Value, allocator, body, .{}) catch {
        return res.jsonResponse(.{ .status_code = 400, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Invalid JSON" }) });
    };

    const root = parsed.object;
    const ordered_ids_val = root.get("ordered_ids") orelse {
        return res.jsonResponse(.{ .status_code = 400, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "ordered_ids required" }) });
    };
    if (ordered_ids_val != .array) {
        return res.jsonResponse(.{ .status_code = 400, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "ordered_ids must be an array" }) });
    }

    // Step 3: extract string IDs from the JSON array. The use case
    // trusts its input, so any non-string entries are silently
    // dropped here.
    var ids = std.ArrayList([]const u8).empty;
    defer ids.deinit(allocator);
    for (ordered_ids_val.array.items) |item| {
        if (item == .string) try ids.append(allocator, item.string);
    }

    // Step 4: call the use case.
    const di = try pabrikcore.getSingleton();
    const result = reorderWorkspaceItems(allocator, di.db, workspace_id, ids.items) catch |err| switch (err) {
        error.TooManyIds => return res.jsonResponse(.{ .status_code = 400, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "ordered_ids too long (max 100)" }) }),
        error.DatabaseUpdateFailed => return res.jsonResponse(.{ .status_code = 500, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Failed to update workspace item position" }) }),
        error.IntegerTooLarge => return res.jsonResponse(.{ .status_code = 500, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Internal error: position value too large" }) }),
    };

    // Step 5: render the typed response.
    return res.jsonResponse(.{ .status_code = 200, .data = try http_response.makeWorkspaceItemReorderResponse(allocator, result.count) });
}

// ─── Use case ──────────────────────────────────────────────────────────────
//
// Pure business logic: validate, compute positions, write to DB.
// Returns a typed `ReorderResult`. Errors are plain Zig errors —
// the handler above maps them to HTTP status codes.
//
// `MAX_REORDER_IDS` is a sanity cap that prevents a 100k-item
// payload from hammering the DB with that many single-row
// UPDATEs. The sidebar typically has a few items per workspace;
// 100 is a generous upper bound.
const MAX_REORDER_IDS: usize = 100;

const ReorderResult = struct {
    count: usize,
};

const ReorderError = error{
    TooManyIds,
    DatabaseUpdateFailed,
    IntegerTooLarge,
};

// Position formula: the i-th id in the array gets
// `position = (count - 1 - i)`. The first id (index 0) gets the
// highest position, so it sorts to the top with
// `ORDER BY position DESC`. The last id gets position 0, so it
// sorts to the bottom.
//
// `workspace_id` is taken as a parameter (not joined into the SQL)
// so the use case stays pure — easy to test, easy to reuse from
// other endpoints (e.g. a future bulk-import).
//
// Atomicity: each UPDATE is atomic + mutex-protected by
// `SqliteBackend.exec`. We don't wrap the loop in a
// `BEGIN TRANSACTION` / `COMMIT` because `SqliteBackend.exec`
// releases the mutex at the end of each call. For drag-and-drop
// UX this is acceptable: concurrent reorders from different
// clients are last-write-wins, and the final state is always a
// valid permutation of the existing rows.
fn reorderWorkspaceItems(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    workspace_id: []const u8,
    ordered_ids: []const []const u8,
) ReorderError!ReorderResult {
    if (ordered_ids.len > MAX_REORDER_IDS) return error.TooManyIds;

    const count: i64 = @intCast(ordered_ids.len);
    var updated_count: usize = 0;

    // Stack-allocated int→string buffer. Reused across iterations.
    // 32 bytes is enough for any i64 (max 20 chars including sign).
    // Avoids per-iteration heap allocation that `std.fmt.allocPrint`
    // would incur — the right idiom for "format a primitive for a
    // string-only API" (the SqliteBackend.exec API only takes
    // string args).
    var buf: [32]u8 = undefined;

    for (ordered_ids, 0..) |id_str, i| {
        const new_pos: i64 = count - 1 - @as(i64, @intCast(i));
        // `bufPrint` into a fixed buffer — no heap allocation.
        // Only fails on actual buffer overflow, which a 32-byte
        // buffer for an i64 cannot hit. Treat as a programmer
        // error.
        const pos_str = std.fmt.bufPrint(&buf, "{d}", .{new_pos}) catch {
            return error.IntegerTooLarge;
        };
        // Scope the UPDATE by workspace_id so a payload containing
        // an item from a different workspace silently no-ops
        // (defense-in-depth: the URL param is the source of truth
        // for which workspace's items are being reordered). A
        // matching item gets the new position; an id that doesn't
        // belong to this workspace is silently skipped (consistent
        // with the "unknown IDs are silently skipped" contract).
        db.exec(allocator, "UPDATE workspace_items SET position = ?, updated_at = datetime('now') WHERE id = ? AND workspace_id = ?", &.{ pos_str, id_str, workspace_id }) catch {
            return error.DatabaseUpdateFailed;
        };
        updated_count += 1;
    }

    return ReorderResult{ .count = updated_count };
}
