//! Static regression checks for the `GET /kanban/columns` handler.
//!
//! Why this file exists
//! ────────────────────
//! The Workspace Item Kanban feature (plan:
//! `2026-06-21-workspace-item-kanban.md`) introduces a column-list
//! endpoint that returns the kanban's `kanban_columns` rows in
//! position order. The handler is a thin wrapper that:
//!   1. Reads `item_id` from the path params.
//!   2. Calls `kanban_model.listColumns(allocator, db, item_id)`.
//!   3. Returns the rows via `http_response.makeKanbanColumnListResponse`
//!      (typed envelope `{columns, count}`).
//!
//! These contracts are enforced by static substring checks, matching
//! the project's `routines_run_test.zig` pattern.
//!
//! Plan: docs/superpowers/plans/2026-06-21-workspace-item-kanban.md
//!   (Chunk 3, Task 3.3)

const std = @import("std");
const testing = std.testing;
const nalarcore = @import("nalarcore");
const text_normalize = @import("helpers").text_normalize;

const HANDLER_PATH = "src/ai_workflow/tui/http_handlers/kanban_columns_list.zig";

/// Read a source file from disk, relative to the project root.
/// Normalizes CRLF → LF so multi-line literal needles match even when
/// the file was checked out on Windows with autocrlf=true (see
/// `.gitattributes` + `src/helpers/text_normalize.zig` for context).
/// The returned buffer is owned by the caller (freed with `allocator.free`).
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

// ─── Contract 1: handler calls kanban_model.listColumns ────────────────────

test "kanban_columns_list handler calls kanban_model.listColumns" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    // The handler must delegate to `kanban_model.listColumns` (NOT
    // write raw SQL). If the call is missing or routed to a different
    // helper, the GET endpoint is broken.
    if (std.mem.indexOf(u8, source, "kanban_model.listColumns") == null) {
        std.debug.print(
            "\n!! {s} does not call kanban_model.listColumns !!\n" ++
                "   The list-columns contract is broken: the handler is missing\n" ++
                "   the data-layer delegation. Restore:\n" ++
                "     const cols = kanban_model.listColumns(allocator, sqlite_db, item_id) catch ...;\n" ++
                "   See docs/superpowers/plans/2026-06-21-workspace-item-kanban.md.\n",
            .{HANDLER_PATH},
        );
        return error.ListColumnsCallMissing;
    }
}

// ─── Contract 2: handler returns 200 with typed envelope ───────────────────

test "kanban_columns_list handler returns 200 + typed column envelope" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    // The success branch must return 200 (not 201 — GET is not a creation).
    if (std.mem.indexOf(u8, source, ".status_code = 200") == null) {
        std.debug.print(
            "\n!! {s} does not return 200 on success !!\n" ++
                "   The status contract is broken: clients expect 200 OK from GET.\n" ++
                "   Use `.status_code = 200` on the success branch.\n",
            .{HANDLER_PATH},
        );
        return error.Status200Missing;
    }

    // The body must be built via `http_response.makeKanbanColumnListResponse`
    // (typed envelope `{columns, count}`) — NOT hand-rolled `allocPrint`.
    // The frontend reads `data.columns` and `data.count` directly.
    if (std.mem.indexOf(u8, source, "makeKanbanColumnListResponse") == null) {
        std.debug.print(
            "\n!! {s} does not use makeKanbanColumnListResponse !!\n" ++
                "   The response-shape contract is broken: the handler must use\n" ++
                "   the typed `makeKanbanColumnListResponse` helper (NOT hand-rolled\n" ++
                "   allocPrint) so the body shape stays in sync with `KanbanColumnResponse`.\n",
            .{HANDLER_PATH},
        );
        return error.TypedEnvelopeMissing;
    }
}

// ─── Contract 3: handler validates the item_id path param ─────────────────

test "kanban_columns_list handler validates item_id path param" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    // The handler must read `item_id` from `req.params`. If the param
    // is missing, return 400.
    if (std.mem.indexOf(u8, source, "req.params.get(\"item_id\")") == null) {
        std.debug.print(
            "\n!! {s} does not read the item_id path param !!\n" ++
                "   The path-param contract is broken: the handler must read\n" ++
                "   `req.params.get(\"item_id\")` and return 400 when missing.\n" ++
                "   See docs/superpowers/plans/2026-06-21-workspace-item-kanban.md.\n",
            .{HANDLER_PATH},
        );
        return error.ItemIdParamMissing;
    }
}