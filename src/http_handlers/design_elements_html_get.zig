//! `GET /api/workspaces/:workspace_id/items/:item_id/design/pages/:page_id/elements/:element_id/html`.
//!
//! Lazy-load an element's full HTML body. The page+elements GET
//! (`design_pages_get`) deliberately omits HTML bodies to keep the
//! payload small for designs with many elements. The iframe
//! preview fetches bodies via this endpoint as the user selects
//! each element.
//!
//! Response shape: `{"html": string}` (built via
//! `std.json.Stringify.valueAlloc` so the HTML body is properly
//! JSON-escaped — quotes, backslashes, newlines, control chars).
//!
//! Errors:
//!   - 400 missing `element_id` path param
//!   - 404 element not found (or file not found on disk)
//!   - 500 DB / IO failure
//!
//! Plan: docs/superpowers/plans/2026-07-08-design-mode-redesign.md
//!   (Chunk 3, Task 3.4)

const std = @import("std");
const nalarcore = @import("nalarcore");
const gserverz = nalarcore.gserverz;
const http_response = @import("http_response.zig");
const design_model = @import("../agentic_loop/design_model.zig");

pub const DesignElementHtmlGetError = error{
    /// `:element_id` path param was missing or empty.
    ElementIdRequired,
    /// `design_model.loadElementHtml` returned `ElementNotFound` or
    /// `FileNotFound` (no row or the file is missing on disk).
    ElementNotFound,
    /// `loadElementHtml` failed for some other DB / IO reason.
    QueryFailed,
    /// `std.json.Stringify.valueAlloc` failed (effectively
    /// unreachable on the per-request arena).
    OutOfMemory,
};

pub const DesignElementHtmlResponse = struct { html: []const u8 };

// =====================================================================
// Use case
// =====================================================================

fn useCase(
    allocator: std.mem.Allocator,
    db: *nalarcore.sqlite.SqliteBackend,
    io: std.Io,
    element_id: []const u8,
) DesignElementHtmlGetError![]u8 {
    if (element_id.len == 0) return error.ElementIdRequired;

    const html = design_model.loadElementHtml(allocator, io, db, element_id) catch |err| switch (err) {
        error.ElementNotFound, error.FileNotFound => return error.ElementNotFound,
        else => return error.QueryFailed,
    };
    defer allocator.free(html);

    const response = DesignElementHtmlResponse{ .html = html };
    return try std.json.Stringify.valueAlloc(allocator, response, .{});
}

// =====================================================================
// Handler
// =====================================================================

pub fn designElementsHtmlGetHandler(
    ctx: gserverz.HttpContext,
    req: gserverz.HttpRequest,
    res: gserverz.HttpResponse,
) !gserverz.HttpResponse {
    const allocator = ctx.allocator;

    const di = try nalarcore.getSingleton();
    const sqlite_db = di.db;

    const element_id = req.params.get("element_id") orelse "";

    const data = useCase(allocator, sqlite_db, ctx.io, element_id) catch |err| {
        const status: u16 = switch (err) {
            error.ElementIdRequired => 400,
            error.ElementNotFound => 404,
            error.QueryFailed => 500,
            error.OutOfMemory => 500,
        };
        const message: []const u8 = switch (err) {
            error.ElementIdRequired => "element_id required",
            error.ElementNotFound => "Element not found",
            error.QueryFailed => "Failed to load element HTML",
            error.OutOfMemory => "Out of memory",
        };
        return res.jsonResponse(.{
            .status_code = status,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = message }),
        });
    };

    return res.jsonResponse(.{ .status_code = 200, .data = data });
}

// ===== Tests merged from design_elements_html_get_test.zig (2026-09-11 flatten) =====
// Static regression checks for the `GET .../elements/:eid/html` handler.
// 
// Why this file exists
// ────────────────────
// The element-html-get endpoint lazy-loads an element's full HTML
// body. The handler is a thin wrapper:
//   1. Reads `element_id` from the path params.
//   2. Calls `design_model.loadElementHtml(allocator, io, db, id)`.
//   3. Returns the body via `std.json.Stringify.valueAlloc` as
//      `{html: string}` (so quotes/backslashes are JSON-escaped).
// 
// These contracts are enforced by static substring checks.
// 
// Plan: docs/superpowers/plans/2026-07-08-design-mode-redesign.md
//   (Chunk 3, Task 3.4)

const testing = std.testing;
const text_normalize = @import("helpers").text_normalize;

const HANDLER_PATH = "src/http_handlers/design_elements_html_get.zig";

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

// ─── Contract 1: handler calls design_model.loadElementHtml ────────────

test "design_elements_html_get handler calls design_model.loadElementHtml" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    if (std.mem.indexOf(u8, source, "design_model.loadElementHtml") == null) {
        std.debug.print(
            "\n!! {s} does not call design_model.loadElementHtml !!\n" ++
                "   The GET-html contract is broken: the handler must delegate\n" ++
                "   to `design_model.loadElementHtml(allocator, io, db, element_id)`.\n",
            .{HANDLER_PATH},
        );
        return error.LoadElementHtmlCallMissing;
    }
}

// ─── Contract 2: handler returns 200 + typed envelope ───────────────────

test "design_elements_html_get handler returns 200 + typed html envelope" {
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

    if (std.mem.indexOf(u8, source, "DesignElementHtmlResponse") == null) {
        std.debug.print(
            "\n!! {s} does not use DesignElementHtmlResponse struct !!\n" ++
                "   The response-shape contract is broken: the handler must\n" ++
                "   build the body as a typed html envelope via std.json.Stringify.valueAlloc.\n",
            .{HANDLER_PATH},
        );
        return error.TypedEnvelopeMissing;
    }
}

// ─── Contract 3: handler maps ElementNotFound to 404 ────────────────────

test "design_elements_html_get handler maps ElementNotFound to 404" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    if (std.mem.indexOf(u8, source, "error.ElementNotFound => 404") == null) {
        std.debug.print(
            "\n!! {s} does not map ElementNotFound to 404 !!\n" ++
                "   The status contract is broken: missing elements must return 404.\n",
            .{HANDLER_PATH},
        );
        return error.ElementNotFoundStatusMissing;
    }
}

// ─── Contract 4: handler validates the element_id path param ────────────

test "design_elements_html_get handler validates element_id path param" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    if (std.mem.indexOf(u8, source, "req.params.get(\"element_id\")") == null) {
        std.debug.print(
            "\n!! {s} does not read the element_id path param !!\n" ++
                "   The path-param contract is broken: the handler must read\n" ++
                "   `req.params.get(\"element_id\")` and return 400 when missing.\n",
            .{HANDLER_PATH},
        );
        return error.ElementIdParamMissing;
    }
}
