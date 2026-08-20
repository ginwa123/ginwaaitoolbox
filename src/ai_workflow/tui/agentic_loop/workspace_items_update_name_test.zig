//! Static regression checks for the `name` branch of the
//! `PUT /workspaces/:wsId/items/:itemId` handler
//! (`workspace_items_update.zig`).
//!
//! Why this file exists
//! ────────────────────
//! The edit-workspace-item-name feature adds a third optional
//! field (`name`) to the body the PUT handler accepts, sitting
//! alongside the existing `item_type` and `path`. Three contracts
//! are enforced via static substring checks (per the project
//! convention — see
//! `nalar-http-handler-thin-wrapper-pattern`):
//!
//!   1. The handler reads `root.get("name")` (mirroring the
//!      `root.get("path")` shape).
//!   2. The handler calls `updateWorkspaceItemName` (model layer)
//!      when the field is present and non-empty.
//!   3. The handler rejects an empty string with 400 BEFORE the
//!      DB round-trip.
//!
//! These guard against accidental routing of the rename request
//! back to the legacy `updateWorkspaceItem` path (which does NOT
//! write `name`), leaving the user's rename attempt to silently
//! fail.
//!
//! Plan: docs/superpowers/plans/2026-06-30-edit-workspace-item-name.md
//!   (Chunk 1, Task 1.3)

const std = @import("std");
const testing = std.testing;
const nalarcore = @import("nalarcore");
const text_normalize = @import("helpers").text_normalize;

const HANDLER_PATH =
    "src/ai_workflow/tui/http_handlers/workspace_items_update.zig";

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

// ─── Contract 1: handler reads name from the request body ──────────────────

test "workspace_items_update handler reads name from body via root.get(\"name\")" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    // The handler must reference `root.get("name")` so the rename
    // request reaches the `name_present` branch. Mirrors the
    // existing `path_present = root.get("path") != null` line that
    // gates the path-update branch.
    if (std.mem.indexOf(u8, source, "root.get(\"name\")") == null) {
        std.debug.print(
            "\n!! {s} does not read `name` from the request body !!\n" ++
                "   The rename branch requires `root.get(\"name\")` to be\n" ++
                "   referenced (so the rename request reaches the `name_valid`\n" ++
                "   gate). Mirror the existing `root.get(\"path\")` extraction.\n" ++
                "   See docs/superpowers/plans/2026-06-30-edit-workspace-item-name.md.\n",
            .{HANDLER_PATH},
        );
        return error.NameExtractionMissing;
    }
}

// ─── Contract 2: handler calls updateWorkspaceItemName ─────────────────────

test "workspace_items_update handler calls updateWorkspaceItemName" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    // The rename branch must call the model function
    // `updateWorkspaceItemName` to write the new name. Without
    // this, the rename request would silently route to
    // `updateWorkspaceItem` (which writes workspace_id + item_type
    // only) — no name change persisted, no error.
    if (std.mem.indexOf(u8, source, "updateWorkspaceItemName") == null) {
        std.debug.print(
            "\n!! {s} does not call updateWorkspaceItemName !!\n" ++
                "   The rename branch must call `updateWorkspaceItemName` so\n" ++
                "   the SQL UPDATE writes the new name. Add a sibling branch\n" ++
                "   to the path-only branch (see the `updateWorkspaceItemName`\n" ++
                "   call signature in llm_history.zig).\n" ++
                "   See docs/superpowers/plans/2026-06-30-edit-workspace-item-name.md.\n",
            .{HANDLER_PATH},
        );
        return error.UpdateNameCallMissing;
    }
}

// ─── Contract 3: handler rejects empty string with 400 ────────────────────

test "workspace_items_update handler returns 400 for empty name" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    // If the caller sends `{name: ""}` or `{name: null}`, the
    // handler MUST 400 before hitting the DB. Searching for the
    // canonical error message keeps the check contract-named —
    // changing the message in production code is also a contract
    // break.
    if (std.mem.indexOf(u8, source, "name must be a non-empty string when present") == null) {
        std.debug.print(
            "\n!! {s} does not return 400 for empty name !!\n" ++
                "   The rename branch must reject `{{name: \"\"}}` or `{{name: null}}`\n" ++
                "   with HTTP 400 BEFORE the DB round-trip. Add a check after the\n" ++
                "   item-existence lookup:\n" ++
                "     if (name_present and !name_valid) {{ return ... 400 ... }}\n" ++
                "   with the message 'name must be a non-empty string when present'.\n" ++
                "   See docs/superpowers/plans/2026-06-30-edit-workspace-item-name.md.\n",
            .{HANDLER_PATH},
        );
        return error.EmptyNameNotRejected;
    }
}

// ─── Contract 4: item_type is optional in the body ───────────────────────

test "workspace_items_update handler makes item_type optional (falls back to existing row)" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    // The rename flow (workspacesStore.updateKanbanItemName) sends
    // only {name: "X"} — the caller does NOT know or send the
    // current item_type. The handler MUST accept this without
    // returning 400, by falling back to the existing row's
    // item_type. The contract-named check looks for the
    // effective_item_type fallback var.
    if (std.mem.indexOf(u8, source, "effective_item_type") == null) {
        std.debug.print("\n!! " ++ HANDLER_PATH ++ " does not compute effective_item_type !!\n", .{});
        return error.ItemTypeFallbackMissing;
    }
}

// ─── Contract 5: empty body (no updatable field) returns 400 ───────────────

test "workspace_items_update handler rejects empty body with 400" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    // Without item_type, name, AND path in the body, the handler
    // would silently no-op. The 400 catches the PUT {} edge case so
    // the caller knows nothing was requested. Searching for the
    // canonical error message keeps the check contract-named.
    if (std.mem.indexOf(u8, source, "At least one of item_type, name, or path is required") == null) {
        std.debug.print("\n!! " ++ HANDLER_PATH ++ " does not return 400 for empty body !!\n", .{});
        return error.EmptyBodyNotRejected;
    }
}
