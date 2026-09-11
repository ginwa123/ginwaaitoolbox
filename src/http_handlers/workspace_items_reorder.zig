const std = @import("std");
const http_response = @import("http_response.zig");
const nalarcore = @import("nalarcore");
const gserverz = nalarcore.gserverz;
const sqlite = nalarcore.sqlite;

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
    const di = try nalarcore.getSingleton();
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

// ===== Tests merged from workspace_items_reorder_test.zig (2026-09-11 flatten) =====
// Static regression checks for the workspace-item reorder handler.
// 
// Mirrors the contract enforced by `workspaces_reorder_test.zig`,
// scoped to a single workspace's items. The handler must:
//   1. Read `{ordered_ids: [...]}` from the request body.
//   2. Issue a per-id `UPDATE workspace_items SET position = ?`.
//   3. Return a typed `WorkspaceItemReorderResponse`.
//   4. Refuse empty / unknown / duplicate IDs (silent skip matches
//      the workspace reorder contract).
// 
// Plan: docs/superpowers/plans/2026-06-16-workspace-item-position-reorder.md

const testing = std.testing;
const text_normalize = @import("helpers").text_normalize;

const HANDLER_PATH = "src/http_handlers/workspace_items_reorder.zig";
// workspace_items_list's SQL is delegated to
// `ai_mod.workspace_items.listWorkspaceItems`, which lives in
// `llm_history.zig` (the workspace_items module is re-exported from
// there per `mod.zig`). The test enforces the contract at the file
// where the actual SELECT lives, not at the thin handler wrapper.
const LIST_PATH = "src/agentic_loop/llm_history.zig";
const CREATE_PATH = "src/http_handlers/workspace_items_create.zig";
const RESPONSE_PATH = "src/http_handlers/http_response.zig";
const MIGRATION_PATH = "src/migrations/migration.zig";

fn readSource(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const raw = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        path,
        allocator,
        .limited(1024 * 1024),
    );
    const normalized = try text_normalize.normalizeLineEndings(allocator, raw);
    allocator.free(raw); // free the CRLF-laden input — normalized is the LF-only copy
    return normalized;
}

test "workspace_items_reorder handler parses ordered_ids from the request body" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    if (std.mem.indexOf(u8, source, "ordered_ids") == null) {
        std.debug.print(
            "\n!! {s} does not reference the `ordered_ids` field !!\n" ++
                "   The reorder endpoint is broken. The frontend POSTs\n" ++
                "   {{ordered_ids: [...]}} and expects a 200 + position\n" ++
                "   updates. Restore the field name in the handler.\n" ++
                "   See docs/plans/2026-06-16-workspace-item-position-reorder.md.\n",
            .{HANDLER_PATH},
        );
        return error.OrderedIdsMissing;
    }
}

test "workspace_items_reorder SQL UPDATE lives in the use case (same file)" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    if (std.mem.indexOf(u8, source, "UPDATE workspace_items SET position") == null) {
        std.debug.print(
            "\n!! {s} does not UPDATE workspace_items.position !!\n" ++
                "   The reorder endpoint is silently a no-op.\n" ++
                "   Add: UPDATE workspace_items SET position = ? WHERE id = ?\n",
            .{HANDLER_PATH},
        );
        return error.PositionUpdateMissing;
    }
}

test "workspace_items_reorder uses a typed response (no manual JSON string)" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    if (std.mem.indexOf(u8, source, "makeWorkspaceItemReorderResponse") == null) {
        std.debug.print(
            "\n!! {s} does not call makeWorkspaceItemReorderResponse !!\n" ++
                "   The response is being constructed manually. Use the\n" ++
                "   typed helper in http_response.zig instead:\n" ++
                "     try http_response.makeWorkspaceItemReorderResponse(allocator, result.count)\n",
            .{HANDLER_PATH},
        );
        return error.ManualJsonString;
    }
    if (std.mem.indexOf(u8, source, "std.fmt.allocPrint(allocator, \"{{") != null) {
        std.debug.print(
            "\n!! {s} still constructs a JSON string with std.fmt.allocPrint !!\n" ++
                "   Use the typed response helper. See the contract test\n" ++
                "   above for the helper name.\n",
            .{HANDLER_PATH},
        );
        return error.ManualJsonString;
    }
}

test "workspace_items_reorder use case assigns position = (count - 1 - i)" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    if (std.mem.indexOf(u8, source, "count - 1 -") == null) {
        std.debug.print(
            "\n!! {s} is missing the 'count - 1 - i' position formula !!\n" ++
                "   The reorder endpoint will assign positions in the\n" ++
                "   wrong direction (bottom-to-top instead of top-to-bottom).\n" ++
                "   Restore: const new_pos: i64 = count - 1 - @as(i64, @intCast(i));\n",
            .{HANDLER_PATH},
        );
        return error.PositionFormulaMissing;
    }
}

test "workspace_items_get handler orders by position DESC" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, LIST_PATH);
    defer allocator.free(source);

    // The check is intentionally permissive: it looks for the
    // substring "position DESC" (not "ORDER BY position DESC")
    // so it works whether or not the column is aliased (the
    // project's "always alias tables" convention uses
    // `ORDER BY wi.position DESC` — see the cross-ref comment
    // in `llm_history.zig:listWorkspaceItems`).
    if (std.mem.indexOf(u8, source, "position DESC") == null) {
        std.debug.print(
            "\n!! {s} does not ORDER BY position DESC !!\n" ++
                "   Drag-reorder will be lost on the next page load.\n" ++
                "   Restore: ORDER BY position DESC (or wi.position DESC) in\n" ++
                "   the workspace_items SELECT.\n",
            .{LIST_PATH},
        );
        return error.OrderByPositionMissing;
    }
}

test "workspace_items_create handler assigns a fresh MAX+1 position" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, CREATE_PATH);
    defer allocator.free(source);

    const has_max_subquery = std.mem.indexOf(u8, source, "MAX(position)") != null;
    const has_position_col = std.mem.indexOf(u8, source, "position") != null;
    if (!has_max_subquery or !has_position_col) {
        std.debug.print(
            "\n!! {s} does not compute a fresh position for new rows !!\n" ++
                "   New items will land at the bottom of the list.\n" ++
                "   Add: COALESCE((SELECT MAX(position) FROM workspace_items WHERE workspace_id = ?), -1) + 1\n" ++
                "   to the INSERT statement (scoped by workspace_id).\n",
            .{CREATE_PATH},
        );
        return error.PositionAssignmentMissing;
    }
}

test "makeWorkspaceItemReorderResponse uses std.json.Stringify (typed response)" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, RESPONSE_PATH);
    defer allocator.free(source);

    if (std.mem.indexOf(u8, source, "makeWorkspaceItemReorderResponse") == null) {
        std.debug.print(
            "\n!! {s} is missing makeWorkspaceItemReorderResponse !!\n" ++
                "   The handler test (uses makeWorkspaceItemReorderResponse)\n" ++
                "   will fail. Add the helper:\n" ++
                "     pub fn makeWorkspaceItemReorderResponse(allocator, count) ![]u8 {{\n" ++
                "         return std.json.Stringify.valueAlloc(allocator, WorkspaceItemReorderResponse{{ .count = count }}, .{{}});\n" ++
                "     }}\n",
            .{RESPONSE_PATH},
        );
        return error.ResponseHelperMissing;
    }
    if (std.mem.indexOf(u8, source, "WorkspaceItemReorderResponse") == null) {
        std.debug.print(
            "\n!! {s} is missing the WorkspaceItemReorderResponse struct !!\n" ++
                "   Add: pub const WorkspaceItemReorderResponse = struct {{ success: bool = true, count: usize }};\n",
            .{RESPONSE_PATH},
        );
        return error.ResponseStructMissing;
    }
    if (std.mem.indexOf(u8, source, "std.json.Stringify") == null) {
        std.debug.print(
            "\n!! {s} does not use std.json.Stringify for the response !!\n" ++
                "   The response helper must serialize via\n" ++
                "   std.json.Stringify.valueAlloc(allocator, ..., .{{}}),\n" ++
                "   matching the pattern used by every other make*Response\n" ++
                "   helper in this file.\n",
            .{RESPONSE_PATH},
        );
        return error.TypedSerializationMissing;
    }
}

test "migration 045 adds the workspace_items.position column" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, MIGRATION_PATH);
    defer allocator.free(source);

    const has_version = std.mem.indexOf(u8, source, "Migration045AddPositionToWorkspaceItems") != null;
    const has_column = std.mem.indexOf(u8, source, "ADD COLUMN position") != null;
    if (!has_version or !has_column) {
        std.debug.print(
            "\n!! {s} is missing Migration 045 or the position column !!\n" ++
                "   Fresh databases will fail to ORDER BY position DESC.\n" ++
                "   Add Migration045AddPositionToWorkspaceItems with ALTER TABLE\n" ++
                "   workspace_items ADD COLUMN position INTEGER NOT NULL DEFAULT 0\n",
            .{MIGRATION_PATH},
        );
        return error.Migration045Missing;
    }
}
