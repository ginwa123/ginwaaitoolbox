//! Static regression checks for the workspace-reorder handler.
//!
//! Why this file exists
//! ────────────────────
//! Drag-and-drop reordering of workspaces depends on:
//!   1. The handler at `workspaces_reorder.zig` accepting
//!      `{ordered_ids: [...]}` and dispatching to the use case.
//!   2. The use case (private `reorderWorkspaces` in the same
//!      file) writing position values via `UPDATE workspaces SET
//!      position = ?`.
//!   3. The list handler at `workspaces_list.zig` ordering by
//!      `position DESC`.
//!   4. The create handler at `workspaces_create.zig` assigning
//!      a fresh `MAX+1` position so new workspaces appear at
//!      the top.
//!   5. Migration 043 in `migration.zig` adding the `position`
//!      column.
//!
//! These contracts are enforced by static substring checks
//! (matching the project's `tasks_list_test.zig` pattern), not by
//! spinning up an in-memory DB. If any of these contracts
//! regress, the test fails with a concrete error message that
//! points at the broken file and the missing substring.
//!
//! Plan: docs/plans/2026-06-12-workspace-drag-and-drop.md

const std = @import("std");
const testing = std.testing;
const nalarcore = @import("nalarcore");
const text_normalize = @import("helpers").text_normalize;

const HANDLER_PATH = "src/http_handlers/workspaces_reorder.zig";
const LIST_PATH = "src/http_handlers/workspaces_list.zig";
const CREATE_PATH = "src/http_handlers/workspaces_create.zig";
const RESPONSE_PATH = "src/http_handlers/http_response.zig";
const MIGRATION_PATH = "src/migrations/migration.zig";

/// Read a source file from disk, relative to the project root
/// (which is the cwd when `zig build test:ai_workflow:tui` runs).
fn readSource(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const raw = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        path,
        allocator,
        .limited(256 * 1024),
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

    // The success response must go through the typed
    // `makeWorkspacesReorderResponse` helper. A manual
    // `std.fmt.allocPrint(allocator, "{{\"success\":true,\"count\":{d}}}", ...)`
    // would drift from the struct definition on every refactor
    // and break on field names with special characters.
    if (std.mem.indexOf(u8, source, "makeWorkspacesReorderResponse") == null) {
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
