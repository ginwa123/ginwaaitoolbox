//! `GET /api/workspaces/:workspace_id/items/:item_id/kanban/columns`.
//!
//! Returns the kanban column list for a workspace item. Thin wrapper
//! around `kanban_model.listColumns` — no body parsing, just path
//! param validation, the DB call, and the response envelope.
//!
//! Response shape: `{"columns":[KanbanColumnResponse, ...], "count": N}`
//! (built by `http_response.makeKanbanColumnListResponse`).
//!
//! Errors:
//!   - 400 missing `item_id` path param
//!   - 500 DB failure
//!
//! Plan: docs/superpowers/plans/2026-06-21-workspace-item-kanban.md
//!   (Chunk 3, Task 3.3)

const std = @import("std");
const pabrikcore = @import("pabrikcore");
const gserverz = pabrikcore.gserverz;
const http_response = @import("http_response.zig");
const kanban_model = @import("../agentic_loop/kanban_model.zig");

pub const KanbanColumnsListError = error{
    ItemIdRequired,
    QueryFailed,
    /// `makeKanbanColumnListResponse` returns `![]u8` (its body uses
    /// `std.json.Stringify.valueAlloc` which can fail with
    /// `OutOfMemory`). Effectively unreachable on the per-request
    /// arena, but the type system requires the variant.
    OutOfMemory,
};

pub const KanbanColumnsListResult = []const u8; // pre-serialized JSON

// =====================================================================
// Use case
// =====================================================================

fn useCase(
    allocator: std.mem.Allocator,
    db: *pabrikcore.sqlite.SqliteBackend,
    item_id: []const u8,
) KanbanColumnsListError!KanbanColumnsListResult {
    if (item_id.len == 0) return error.ItemIdRequired;

    const cols = kanban_model.listColumns(allocator, db, item_id) catch return error.QueryFailed;
    defer kanban_model.freeColumns(allocator, cols);

    return try http_response.makeKanbanColumnListResponse(allocator, cols);
}

// =====================================================================
// Handler
// =====================================================================

pub fn kanbanColumnsListHandler(
    ctx: gserverz.HttpContext,
    req: gserverz.HttpRequest,
    res: gserverz.HttpResponse,
) !gserverz.HttpResponse {
    const allocator = ctx.allocator;

    const di = try pabrikcore.getSingleton();
    const sqlite_db = di.db;

    const item_id = req.params.get("item_id") orelse "";

    const data = useCase(allocator, sqlite_db, item_id) catch |err| {
        const status: u16 = switch (err) {
            error.ItemIdRequired => 400,
            error.QueryFailed => 500,
            error.OutOfMemory => 500,
        };
        const message: []const u8 = switch (err) {
            error.ItemIdRequired => "item_id required",
            error.QueryFailed => "Failed to list kanban columns",
            error.OutOfMemory => "Out of memory",
        };
        return res.jsonResponse(.{
            .status_code = status,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = message }),
        });
    };

    return res.jsonResponse(.{ .status_code = 200, .data = data });
}

// ===== Tests merged from kanban_columns_list_test.zig (2026-09-11 flatten) =====
// Static regression checks for the `GET /kanban/columns` handler.
// 
// Why this file exists
// ────────────────────
// The Workspace Item Kanban feature (plan:
// `2026-06-21-workspace-item-kanban.md`) introduces a column-list
// endpoint that returns the kanban's `kanban_columns` rows in
// position order. The handler is a thin wrapper that:
//   1. Reads `item_id` from the path params.
//   2. Calls `kanban_model.listColumns(allocator, db, item_id)`.
//   3. Returns the rows via `http_response.makeKanbanColumnListResponse`
//      (typed envelope `{columns, count}`).
// 
// These contracts are enforced by static substring checks, matching
// the project's `routines_run_test.zig` pattern.
// 
// Plan: docs/superpowers/plans/2026-06-21-workspace-item-kanban.md
//   (Chunk 3, Task 3.3)

const testing = std.testing;
const text_normalize = @import("helpers").text_normalize;

const HANDLER_PATH = "src/http_handlers/kanban_columns_list.zig";

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
