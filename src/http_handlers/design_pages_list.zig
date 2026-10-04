//! `GET /api/workspaces/:workspace_id/items/:item_id/design/pages`.
//!
//! List the design pages belonging to a workspace item of
//! `item_type='design'`. Thin wrapper around
//! `design_model.listPages` — no body parsing, just path-param
//! validation, the DB call, and the response envelope.
//!
//! Response shape: `{"pages":[DesignPageResponse, ...], "count": N}`
//! (built by `http_response.makeDesignPageListResponse`). An empty
//! page list returns `{pages: [], count: 0}` with 200 OK — not 404,
//! because "this design has no pages yet" is a normal state.
//!
//! Errors:
//!   - 400 missing `item_id` path param
//!   - 500 DB failure
//!
//! Plan: docs/superpowers/plans/2026-07-08-design-mode-redesign.md
//!   (Chunk 3, Task 3.2)

const std = @import("std");
const pabrikcore = @import("pabrikcore");
const gserverz = pabrikcore.gserverz;
const http_response = @import("http_response.zig");
const design_model = @import("../agentic_loop/design_model.zig");

pub const DesignPagesListError = error{
    ItemIdRequired,
    QueryFailed,
    /// `makeDesignPageListResponse` returns `![]u8` (its body uses
    /// `std.json.Stringify.valueAlloc` which can fail with
    /// `OutOfMemory`). Effectively unreachable on the per-request
    /// arena, but the type system requires the variant.
    OutOfMemory,
};

pub const DesignPagesListResult = []const u8; // pre-serialized JSON

// =====================================================================
// Use case
// =====================================================================

fn useCase(
    allocator: std.mem.Allocator,
    db: *pabrikcore.sqlite.SqliteBackend,
    item_id: []const u8,
) DesignPagesListError!DesignPagesListResult {
    if (item_id.len == 0) return error.ItemIdRequired;

    const pages = design_model.listPages(allocator, db, item_id) catch return error.QueryFailed;
    defer design_model.freePages(allocator, pages);

    return try http_response.makeDesignPageListResponse(allocator, pages);
}

// =====================================================================
// Handler
// =====================================================================

pub fn designPagesListHandler(
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
            error.QueryFailed => "Failed to list design pages",
            error.OutOfMemory => "Out of memory",
        };
        return res.jsonResponse(.{
            .status_code = status,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = message }),
        });
    };

    return res.jsonResponse(.{ .status_code = 200, .data = data });
}

// ===== Tests merged from design_pages_list_test.zig (2026-09-11 flatten) =====
// Static regression checks for the `GET /design/pages` handler.
// 
// Why this file exists
// ────────────────────
// The page-list endpoint returns the `design_pages` rows for a
// workspace item in position order. The handler is a thin wrapper
// that:
//   1. Reads `item_id` from the path params.
//   2. Calls `design_model.listPages(allocator, db, item_id)`.
//   3. Returns the rows via `http_response.makeDesignPageListResponse`
//      (typed envelope `{pages, count}`).
// 
// These contracts are enforced by static substring checks, matching
// the project's `kanban_columns_list_test.zig` pattern.
// 
// Plan: docs/superpowers/plans/2026-07-08-design-mode-redesign.md
//   (Chunk 3, Task 3.2)

const testing = std.testing;
const text_normalize = @import("helpers").text_normalize;

const HANDLER_PATH = "src/http_handlers/design_pages_list.zig";

/// Read a source file from disk, relative to the project root.
/// Normalizes CRLF → LF so multi-line literal needles match even when
/// the file was checked out on Windows with autocrlf=true. The
/// returned buffer is owned by the caller (freed with `allocator.free`).
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

// ─── Contract 1: handler calls design_model.listPages ───────────────────

test "design_pages_list handler calls design_model.listPages" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    if (std.mem.indexOf(u8, source, "design_model.listPages") == null) {
        std.debug.print(
            "\n!! {s} does not call design_model.listPages !!\n" ++
                "   The list-pages contract is broken: the handler is missing\n" ++
                "   the data-layer delegation. Restore:\n" ++
                "     const pages = design_model.listPages(allocator, sqlite_db, item_id) catch ...;\n",
            .{HANDLER_PATH},
        );
        return error.ListPagesCallMissing;
    }
}

// ─── Contract 2: handler returns 200 + typed envelope ───────────────────

test "design_pages_list handler returns 200 + typed page envelope" {
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

    // The body must be built via `http_response.makeDesignPageListResponse`
    // (typed envelope `{pages, count}`) — NOT hand-rolled `allocPrint`.
    if (std.mem.indexOf(u8, source, "makeDesignPageListResponse") == null) {
        std.debug.print(
            "\n!! {s} does not use makeDesignPageListResponse !!\n" ++
                "   The response-shape contract is broken: the handler must use\n" ++
                "   the typed `makeDesignPageListResponse` helper (NOT hand-rolled\n" ++
                "   allocPrint) so the body shape stays in sync with `DesignPageResponse`.\n",
            .{HANDLER_PATH},
        );
        return error.TypedEnvelopeMissing;
    }
}

// ─── Contract 3: handler validates the item_id path param ────────────────

test "design_pages_list handler validates item_id path param" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    if (std.mem.indexOf(u8, source, "req.params.get(\"item_id\")") == null) {
        std.debug.print(
            "\n!! {s} does not read the item_id path param !!\n" ++
                "   The path-param contract is broken: the handler must read\n" ++
                "   `req.params.get(\"item_id\")` and return 400 when missing.\n",
            .{HANDLER_PATH},
        );
        return error.ItemIdParamMissing;
    }
}
