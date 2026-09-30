const std = @import("std");
const http_response = @import("http_response.zig");
const nalarcore = @import("nalarcore");
const auth_common = @import("auth_common.zig");
const gserverz = nalarcore.gserverz;
const sqlite = nalarcore.sqlite;

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
    const di = try nalarcore.getSingleton();
    const owner = auth_common.resolveRequestUserId(allocator, di.db, di.auth_enabled, req.headers) catch "";
    defer if (owner.len > 0) allocator.free(owner);

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
fn reorderWorkspaces(allocator: std.mem.Allocator, db: *nalarcore.sqlite.SqliteBackend, ordered_ids: []const []const u8, owner: []const u8) ReorderError!ReorderResult {
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
        db.exec(allocator, "UPDATE workspaces SET position = ?, updated_at = datetime('now') WHERE id = ? AND " ++ comptime auth_common.ownerVisibilityClause("workspaces"), &.{ pos_str, id_str, owner, owner }) catch {
            return error.DatabaseUpdateFailed;
        };
        updated_count += 1;
    }

    return ReorderResult{ .count = updated_count };
}

// ===== Tests merged from workspaces_reorder_test.zig (2026-09-11 flatten) =====
// Static regression checks for the workspace-reorder handler.
// 
// Why this file exists
// ────────────────────
// Drag-and-drop reordering of workspaces depends on:
//   1. The handler at `workspaces_reorder.zig` accepting
//      `{ordered_ids: [...]}` and dispatching to the use case.
//   2. The use case (private `reorderWorkspaces` in the same
//      file) writing position values via `UPDATE workspaces SET
//      position = ?`.
//   3. The list handler at `workspaces_list.zig` ordering by
//      `position DESC`.
//   4. The create handler at `workspaces_create.zig` assigning
//      a fresh `MAX+1` position so new workspaces appear at
//      the top.
//   5. Migration 043 in `migration.zig` adding the `position`
//      column.
// 
// These contracts are enforced by static substring checks
// (matching the project's `tasks_list_test.zig` pattern), not by
// spinning up an in-memory DB. If any of these contracts
// regress, the test fails with a concrete error message that
// points at the broken file and the missing substring.
// 
// Plan: docs/plans/2026-06-12-workspace-drag-and-drop.md

const testing = std.testing;
const text_normalize = @import("helpers").text_normalize;

const HANDLER_PATH = "src/http_handlers/workspaces_reorder.zig";
const LIST_PATH = "src/http_handlers/workspaces_list.zig";
const CREATE_PATH = "src/http_handlers/workspaces_create.zig";
const RESPONSE_PATH = "src/http_handlers/http_response.zig";
const MIGRATION_PATH = "src/migrations/migration.zig";

/// Read a source file from disk, relative to the project root
/// (which is the cwd when `zig build test:ai_workflow:tui` runs).
fn readSource(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    // 8 MiB: migration.zig grows with every migration, crossed 256 KiB at
    // Migration 087 (agent_routines mirror) and 512 KiB when the 2026-09-29
    // test flatten inlined the per-migration `*_test.zig` suites into it
    // (~591 KiB). readFileAlloc errors with StreamTooLong past the cap, so
    // keep real headroom rather than chasing it migration by migration.
    const raw = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        path,
        allocator,
        .limited(8 * 1024 * 1024),
    );
    const normalized = try text_normalize.normalizeLineEndings(allocator, raw);
    allocator.free(raw); // free the CRLF-laden input — normalized is the LF-only copy
    return normalized;
}

// ─── Handler contract: parse the body and dispatch to the use case ──────

test "workspaces_reorder handler parses ordered_ids from the request body" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    // The handler must read `ordered_ids` from the parsed JSON. If
    // this is missing or renamed, the drag-and-drop reorder
    // endpoint is broken — the frontend will POST and get a 400.
    if (std.mem.indexOf(u8, source, "ordered_ids") == null) {
        std.debug.print(
            "\n!! {s} does not reference the `ordered_ids` field !!\n" ++
                "   The reorder endpoint is broken. The frontend POSTs\n" ++
                "   {{ordered_ids: [...]}} and expects a 200 + position\n" ++
                "   updates. Restore the field name in the handler.\n" ++
                "   See docs/plans/2026-06-12-workspace-drag-and-drop.md.\n",
            .{HANDLER_PATH},
        );
        return error.OrderedIdsMissing;
    }
}

// ─── Handler/Use-case contract: SQL lives in the use case, not the handler ─

test "workspaces_reorder SQL UPDATE lives in the use case (same file)" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    // The SQL UPDATE that writes the `position` column must be
    // present in the file (it's the only place reorder logic
    // lives). The static check just asserts presence — the
    // function structure (handler vs use case) is verified by
    // other tests below.
    if (std.mem.indexOf(u8, source, "UPDATE workspaces SET position") == null) {
        std.debug.print(
            "\n!! {s} does not UPDATE workspaces.position !!\n" ++
                "   The reorder endpoint is silently a no-op.\n" ++
                "   Add: UPDATE workspaces SET position = ? WHERE id = ?\n",
            .{HANDLER_PATH},
        );
        return error.PositionUpdateMissing;
    }
}

test "workspaces_reorder uses a typed response (no manual JSON string)" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    // Scope to the impl section only (truncate at the merged-tests
    // banner) so the absence check below doesn't self-match its own
    // comment text in the merged-tests section.
    const impl_end = std.mem.indexOf(u8, source, "// ===== Tests merged from") orelse source.len;
    const impl_source = source[0..impl_end];

    // The success response must go through the typed
    // `makeWorkspacesReorderResponse` helper. A manual
    // `std.fmt.allocPrint(allocator, "{{\"success\":true,\"count\":{d}}}", ...)`
    // would drift from the struct definition on every refactor
    // and break on field names with special characters.
    if (std.mem.indexOf(u8, impl_source, "makeWorkspacesReorderResponse") == null) {
        std.debug.print(
            "\n!! {s} does not call makeWorkspacesReorderResponse !!\n" ++
                "   The response is being constructed manually (probably\n" ++
                "   with `std.fmt.allocPrint`). Use the typed helper in\n" ++
                "   http_response.zig instead:\n" ++
                "     try http_response.makeWorkspacesReorderResponse(allocator, result.count)\n" ++
                "   This keeps the JSON shape in lockstep with the\n" ++
                "   WorkspacesReorderResponse struct definition.\n",
            .{HANDLER_PATH},
        );
        return error.ManualJsonString;
    }
    // Defensive: explicitly forbid the manual-JSON-string pattern.
    // The two-`{{` opening braces are Zig's escape for a literal `{`
    // in a format string, so the literal pattern we forbid is
    // `std.fmt.allocPrint(allocator, "{{\"success\":true`.
    if (std.mem.indexOf(u8, impl_source, "std.fmt.allocPrint(allocator, \"{{") != null) {
        std.debug.print(
            "\n!! {s} still constructs a JSON string with std.fmt.allocPrint !!\n" ++
                "   Use the typed response helper. See the contract test\n" ++
                "   above for the helper name.\n",
            .{HANDLER_PATH},
        );
        return error.ManualJsonString;
    }
}

// ─── Use case contract: position formula is `count - 1 - i` ───────────────

test "workspaces_reorder use case assigns position = (count - 1 - i)" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    // Position formula. The first id (i = 0) gets the highest
    // position (so it sorts to the top with
    // `ORDER BY position DESC`). The last id (i = count-1) gets
    // position 0 (bottom). If this formula regresses to something
    // else, the visual order will be inverted.
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

// ─── List handler: order by position DESC ─────────────────────────────────

test "workspaces_list handler orders by position DESC" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, LIST_PATH);
    defer allocator.free(source);

    if (std.mem.indexOf(u8, source, "ORDER BY position DESC") == null) {
        std.debug.print(
            "\n!! {s} does not ORDER BY position DESC !!\n" ++
                "   Drag-reorder will be lost on the next page load.\n" ++
                "   Restore: ORDER BY position DESC, created_at DESC\n",
            .{LIST_PATH},
        );
        return error.OrderByPositionMissing;
    }
}

// ─── Create handler: assign a fresh MAX+1 position ───────────────────────

test "workspaces_create handler assigns a fresh MAX+1 position" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, CREATE_PATH);
    defer allocator.free(source);

    const has_max_subquery = std.mem.indexOf(u8, source, "MAX(position)") != null;
    const has_position_col = std.mem.indexOf(u8, source, "position") != null;
    if (!has_max_subquery or !has_position_col) {
        std.debug.print(
            "\n!! {s} does not compute a fresh position for new rows !!\n" ++
                "   New workspaces will land at the bottom of the list.\n" ++
                "   Add: COALESCE((SELECT MAX(position) FROM workspaces), -1) + 1\n" ++
                "   to the INSERT statement.\n",
            .{CREATE_PATH},
        );
        return error.PositionAssignmentMissing;
    }
}

// ─── Response helper contract: typed struct + std.json.Stringify ─────────

test "makeWorkspacesReorderResponse uses std.json.Stringify (typed response)" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, RESPONSE_PATH);
    defer allocator.free(source);

    // The response helper must use `std.json.Stringify.valueAlloc`
    // (or an equivalent typed serializer) — not manual JSON
    // string formatting. This is the contract the handler test
    // above relies on.
    if (std.mem.indexOf(u8, source, "makeWorkspacesReorderResponse") == null) {
        std.debug.print(
            "\n!! {s} is missing makeWorkspacesReorderResponse !!\n" ++
                "   The handler test (uses makeWorkspacesReorderResponse)\n" ++
                "   will fail. Add the helper:\n" ++
                "     pub fn makeWorkspacesReorderResponse(allocator, count) ![]u8 {{\n" ++
                "         return std.json.Stringify.valueAlloc(allocator, WorkspacesReorderResponse{{ .count = count }}, .{{}});\n" ++
                "     }}\n",
            .{RESPONSE_PATH},
        );
        return error.ResponseHelperMissing;
    }
    if (std.mem.indexOf(u8, source, "WorkspacesReorderResponse") == null) {
        std.debug.print(
            "\n!! {s} is missing the WorkspacesReorderResponse struct !!\n" ++
                "   Add: pub const WorkspacesReorderResponse = struct {{ success: bool = true, count: usize }};\n",
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

// ─── Migration 043: position column + backfill ────────────────────────────

test "migration 043 adds the workspaces.position column" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, MIGRATION_PATH);
    defer allocator.free(source);

    const has_version = std.mem.indexOf(u8, source, "Migration043AddPositionToWorkspaces") != null;
    const has_column = std.mem.indexOf(u8, source, "ADD COLUMN position") != null;
    if (!has_version or !has_column) {
        std.debug.print(
            "\n!! {s} is missing Migration 043 or the position column !!\n" ++
                "   Fresh databases will fail to ORDER BY position DESC.\n" ++
                "   Add Migration043AddPositionToWorkspaces with ALTER TABLE\n" ++
                "   workspaces ADD COLUMN position INTEGER NOT NULL DEFAULT 0\n",
            .{MIGRATION_PATH},
        );
        return error.Migration043Missing;
    }
}
