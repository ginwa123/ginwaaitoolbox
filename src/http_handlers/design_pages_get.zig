//! `GET /api/workspaces/:workspace_id/items/:item_id/design/pages/:page_id`.
//!
//! Fetch a single design page plus all of its elements (without the
//! HTML bodies — those are fetched lazily via
//! `GET .../elements/:eid/html`). Thin wrapper around
//! `design_model.getPageWithElements`.
//!
//! Response shape: `{"page": DesignPageResponse, "elements":
//! []DesignElementResponse}` (built by
//! `http_response.makeDesignPageWithElementsResponse`).
//!
//! Errors:
//!   - 400 missing `page_id` path param
//!   - 404 page not found
//!   - 500 DB failure
//!
//! Plan: docs/superpowers/plans/2026-07-08-design-mode-redesign.md
//!   (Chunk 3, Task 3.2)

const std = @import("std");
const pabrikcore = @import("pabrikcore");
const gserverz = pabrikcore.gserverz;
const http_response = @import("http_response.zig");
const design_model = @import("../agentic_loop/design_model.zig");

pub const DesignPageGetError = error{
    PageIdRequired,
    /// `design_model.getPageWithElements` returned `PageNotFound`
    /// (no row with that `page_id`).
    PageNotFound,
    /// `getPageWithElements` failed for some other DB / IO reason.
    QueryFailed,
    /// `makeDesignPageWithElementsResponse` failed (effectively
    /// unreachable on the per-request arena).
    OutOfMemory,
};

pub const DesignPageGetResult = []const u8; // pre-serialized JSON

// =====================================================================
// Use case
// =====================================================================

fn useCase(
    allocator: std.mem.Allocator,
    db: *pabrikcore.sqlite.SqliteBackend,
    page_id: []const u8,
) DesignPageGetError!DesignPageGetResult {
    if (page_id.len == 0) return error.PageIdRequired;

    var bundle = design_model.getPageWithElements(allocator, db, page_id) catch |err| switch (err) {
        error.PageNotFound => return error.PageNotFound,
        else => return error.QueryFailed,
    };
    defer bundle.deinit(allocator);

    return try http_response.makeDesignPageWithElementsResponse(
        allocator,
        bundle.page,
        bundle.elements,
    );
}

// =====================================================================
// Handler
// =====================================================================

pub fn designPagesGetHandler(
    ctx: gserverz.HttpContext,
    req: gserverz.HttpRequest,
    res: gserverz.HttpResponse,
) !gserverz.HttpResponse {
    const allocator = ctx.allocator;

    const di = try pabrikcore.getSingleton();
    const sqlite_db = di.db;

    const page_id = req.params.get("page_id") orelse "";

    const data = useCase(allocator, sqlite_db, page_id) catch |err| {
        const status: u16 = switch (err) {
            error.PageIdRequired => 400,
            error.PageNotFound => 404,
            error.QueryFailed => 500,
            error.OutOfMemory => 500,
        };
        const message: []const u8 = switch (err) {
            error.PageIdRequired => "page_id required",
            error.PageNotFound => "Page not found",
            error.QueryFailed => "Failed to get page",
            error.OutOfMemory => "Out of memory",
        };
        return res.jsonResponse(.{
            .status_code = status,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = message }),
        });
    };

    return res.jsonResponse(.{ .status_code = 200, .data = data });
}

// ===== Tests merged from design_pages_get_test.zig (2026-09-11 flatten) =====
// Static regression checks for the `GET /design/pages/:page_id` handler.
// 
// Why this file exists
// ────────────────────
// The page-get endpoint returns one design page plus all its
// elements (without HTML bodies — those are fetched lazily). The
// handler is a thin wrapper that:
//   1. Reads `page_id` from the path params.
//   2. Calls `design_model.getPageWithElements(allocator, db, page_id)`.
//   3. Returns the page + elements via
//      `http_response.makeDesignPageWithElementsResponse` (typed
//      envelope `{page, elements}`).
// 
// These contracts are enforced by static substring checks, matching
// the project's `kanban_columns_list_test.zig` pattern.
// 
// Plan: docs/superpowers/plans/2026-07-08-design-mode-redesign.md
//   (Chunk 3, Task 3.2)

const testing = std.testing;
const text_normalize = @import("helpers").text_normalize;

const HANDLER_PATH = "src/http_handlers/design_pages_get.zig";

fn readSource(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const raw = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        path,
        allocator,
        .limited(256 * 1024),
    );
    const normalized = try text_normalize.normalizeLineEndings(allocator, raw);
    allocator.free(raw);
    return normalized;
}

// ─── Contract 1: handler calls design_model.getPageWithElements ──────────

test "design_pages_get handler calls design_model.getPageWithElements" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    if (std.mem.indexOf(u8, source, "design_model.getPageWithElements") == null) {
        std.debug.print(
            "\n!! {s} does not call design_model.getPageWithElements !!\n" ++
                "   The get-page contract is broken: the handler must delegate\n" ++
                "   to `design_model.getPageWithElements(allocator, db, page_id)`.\n",
            .{HANDLER_PATH},
        );
        return error.GetPageWithElementsCallMissing;
    }
}

// ─── Contract 2: handler returns 200 + typed envelope ───────────────────

test "design_pages_get handler returns 200 + typed page+elements envelope" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    if (std.mem.indexOf(u8, source, ".status_code = 200") == null) {
        std.debug.print(
            "\n!! {s} does not return 200 on success !!\n" ++
                "   The status contract is broken: clients expect 200 OK from GET.\n",
            .{HANDLER_PATH},
        );
        return error.Status200Missing;
    }

    if (std.mem.indexOf(u8, source, "makeDesignPageWithElementsResponse") == null) {
        std.debug.print(
            "\n!! {s} does not use makeDesignPageWithElementsResponse !!\n" ++
                "   The response-shape contract is broken: the handler must use\n" ++
                "   the typed `makeDesignPageWithElementsResponse` helper.\n",
            .{HANDLER_PATH},
        );
        return error.TypedEnvelopeMissing;
    }
}

// ─── Contract 3: handler maps PageNotFound to 404 ─────────────────────────

test "design_pages_get handler maps PageNotFound to 404" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    if (std.mem.indexOf(u8, source, "error.PageNotFound => 404") == null) {
        std.debug.print(
            "\n!! {s} does not map PageNotFound to 404 !!\n" ++
                "   The status contract is broken: missing pages must return 404\n" ++
                "   so the frontend can distinguish 'not found' from other errors.\n",
            .{HANDLER_PATH},
        );
        return error.PageNotFoundStatusMissing;
    }
}

// ─── Contract 4: handler validates the page_id path param ───────────────

test "design_pages_get handler validates page_id path param" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    if (std.mem.indexOf(u8, source, "req.params.get(\"page_id\")") == null) {
        std.debug.print(
            "\n!! {s} does not read the page_id path param !!\n" ++
                "   The path-param contract is broken: the handler must read\n" ++
                "   `req.params.get(\"page_id\")` and return 400 when missing.\n",
            .{HANDLER_PATH},
        );
        return error.PageIdParamMissing;
    }
}
