//! Static regression checks for the workspace-item reorder handler.
//!
//! Mirrors the contract enforced by `workspaces_reorder_test.zig`,
//! scoped to a single workspace's items. The handler must:
//!   1. Read `{ordered_ids: [...]}` from the request body.
//!   2. Issue a per-id `UPDATE workspace_items SET position = ?`.
//!   3. Return a typed `WorkspaceItemReorderResponse`.
//!   4. Refuse empty / unknown / duplicate IDs (silent skip matches
//!      the workspace reorder contract).
//!
//! Plan: docs/superpowers/plans/2026-06-16-workspace-item-position-reorder.md

const std = @import("std");
const testing = std.testing;

const HANDLER_PATH = "src/ai_workflow/tui/http_handlers/workspace_items_reorder.zig";
// workspace_items_list's SQL is delegated to
// `ai_mod.workspace_items.listWorkspaceItems`, which lives in
// `llm_history.zig` (the workspace_items module is re-exported from
// there per `mod.zig`). The test enforces the contract at the file
// where the actual SELECT lives, not at the thin handler wrapper.
const LIST_PATH = "src/ai_workflow/tui/llm_history.zig";
const CREATE_PATH = "src/ai_workflow/tui/http_handlers/workspace_items_create.zig";
const RESPONSE_PATH = "src/ai_workflow/tui/http_handlers/http_response.zig";
const MIGRATION_PATH = "src/ai_workflow/tui/migration.zig";

fn readSource(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        path,
        allocator,
        .limited(256 * 1024),
    );
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
