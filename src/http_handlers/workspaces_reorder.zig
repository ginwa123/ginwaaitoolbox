const std = @import("std");
const http_response = @import("http_response.zig");
const pabrikcore = @import("pabrikcore");
const auth_common = @import("auth_common.zig");
const gserverz = pabrikcore.gserverz;
const sqlite = pabrikcore.sqlite;

// ─── Pattern: thin handler + use case in one file ─────────────────────────
//
// This file is structured as a teaching example for new HTTP
// features. The convention is:
//
//   1. The handler (the `pub fn` below) is the *only* export. It
//      does HTTP concerns only: parse the body, extract typed
//      inputs, dispatch to the use case, map errors to status
//      codes, render the typed response.
//
//   2. The use case (the private `fn reorderWorkspaces` below)
//      holds the business logic. It takes plain Zig types (no
//      `gserverz.HttpRequest`, no JSON), validates, performs the
//      DB writes, and returns a typed `ReorderResult`.
//
//   3. The response is a typed struct in `http_response.zig`
//      rendered via `std.json.Stringify.valueAlloc` — never a
//      manually-formatted JSON string (which breaks on field
//      names with special characters and drifts from the struct
//      definition on every refactor).
//
//   4. The static-check tests in `workspaces_reorder_test.zig`
//      assert this structural contract: the handler does not
//      contain SQL, the use case does, and the response is
//      typed.
// ──────────────────────────────────────────────────────────────────────────

/// HTTP handler: POST /api/workspaces/reorder
///
/// Body: { "ordered_ids": ["id1", "id2", ..., "idN"] } (top-to-bottom
/// display order).
///
/// Behavior: assigns position N-1 to ordered_ids[0] (top of the
/// sidebar), N-2 to the next, ..., 0 to ordered_ids[N-1] (bottom).
/// With `workspaces_list.zig` ordering by `position DESC`, the
/// first id in the array appears at the top.
///
/// Idempotent: a second call with the same array leaves the data
/// unchanged. Unknown IDs in the payload are silently skipped
/// (a deleted workspace shouldn't fail the whole reorder).
pub fn workspacesReorderHandler(
    ctx: gserverz.HttpContext,
    req: gserverz.HttpRequest,
    res: gserverz.HttpResponse,
) !gserverz.HttpResponse {
    const allocator = ctx.allocator;

    // Step 1: parse the body. Handler is responsible for ALL HTTP
    // parsing — the use case below trusts its inputs.
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

    // Step 2: extract string IDs from the JSON array. The use case
    // trusts its input, so any non-string entries are silently
    // dropped here (they shouldn't happen with a well-behaved
    // client, and silently skipping them is the contract
    // documented in the file header).
    var ids = std.ArrayList([]const u8).empty;
    defer ids.deinit(allocator);
    for (ordered_ids_val.array.items) |item| {
        if (item == .string) try ids.append(allocator, item.string);
    }

    // Step 3: call the use case.
    const di = try pabrikcore.getSingleton();
    // Used to be `catch ""`. An unresolved owner is `isSharedOwner("")`, which
    // the visibility clause treats as "see everything" — so a single
    // allocation failure here silently widened the caller to every workspace
    // on the instance. Fail closed instead.
    const owner = auth_common.resolveRequestUserId(allocator, di.db, di.auth_enabled, req.headers) catch {
        return res.jsonResponse(.{ .status_code = 500, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Out of memory" }) });
    };
    defer allocator.free(owner);

    const result = reorderWorkspaces(allocator, di.db, ids.items, owner) catch |err| switch (err) {
        error.TooManyIds => return res.jsonResponse(.{ .status_code = 400, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "ordered_ids too long (max 100)" }) }),
        error.DatabaseUpdateFailed => return res.jsonResponse(.{ .status_code = 500, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Failed to update workspace position" }) }),
        error.IntegerTooLarge => return res.jsonResponse(.{ .status_code = 500, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Internal error: position value too large" }) }),
    };

    // Step 4: render the typed response.
    return res.jsonResponse(.{ .status_code = 200, .data = try http_response.makeWorkspacesReorderResponse(allocator, result.count) });
}

// ─── Use case ──────────────────────────────────────────────────────────────
//
// Pure business logic: validate, compute positions, write to DB.
// Returns a typed `ReorderResult`. Errors are plain Zig errors —
// the handler above maps them to HTTP status codes.
//
// `MAX_REORDER_IDS` is a sanity cap that prevents a 100k-item
// payload from hammering the DB with that many single-row
// UPDATEs. The sidebar has a handful of workspaces in practice;
// 100 is a generous upper bound that also catches accidental
// client bugs.
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
// Atomicity: each UPDATE is atomic + mutex-protected by
// `SqliteBackend.exec`. We don't wrap the loop in a
// `BEGIN TRANSACTION` / `COMMIT` because `SqliteBackend.exec`
// releases the mutex at the end of each call — a transaction
// across calls wouldn't actually be atomic. For drag-and-drop
// UX this is acceptable: concurrent reorders from different
// clients are last-write-wins, and the final state is always a
// valid permutation of the existing rows.
fn reorderWorkspaces(allocator: std.mem.Allocator, db: *pabrikcore.sqlite.SqliteBackend, ordered_ids: []const []const u8, owner: []const u8) ReorderError!ReorderResult {
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
        db.exec(allocator, "UPDATE workspaces SET position = ?, updated_at = datetime('now') WHERE id = ? AND " ++ comptime auth_common.workspaceVisibilityClause("workspaces"), &.{ pos_str, id_str, owner, owner }) catch {
            return error.DatabaseUpdateFailed;
        };
        updated_count += 1;
    }

    return ReorderResult{ .count = updated_count };
}
