//! `DELETE /api/workspaces/:workspace_id/items/:item_id/design/pages/:page_id`.
//!
//! Delete a design page. The on-disk `<item_path>/.nalar/design/<page>/`
//! folder is recursively unlinked AFTER the SQL DELETE succeeds
//! (defer-pattern) via `design_model.deletePage`. The DB FK
//! `ON DELETE CASCADE` on `design_page_elements.page_id` cleans up
//! the child element rows in the same transaction. UI-only — no LLM
//! tool exposes this endpoint, only the DesignView tab-strip × button.
//!
//! Response shape: `{"success": true}` on a successful delete.
//! Returns 404 if the page did not exist (so the frontend can
//! distinguish "already gone" from "deleted right now"). The frontend
//! treats both as success (idempotent — no need to surface a toast
//! for an already-deleted page).
//!
//! Errors:
//!   - 400 missing `page_id` path param
//!   - 404 page not found
//!   - 500 DB failure
//!
//! Plan: docs/superpowers/plans/2026-07-25-design-page-delete-button.md
//!   (Chunk 1)

const std = @import("std");
const nalarcore = @import("nalarcore");
const gserverz = nalarcore.gserverz;
const http_response = @import("http_response.zig");
const design_model = @import("../agentic_loop/design_model.zig");

pub const DesignPageDeleteError = error{
    /// `:page_id` path param was missing or empty.
    PageIdRequired,
    /// `design_model.deletePage` returned `false` (no such row).
    PageNotFound,
    /// `deletePage` failed for some other DB reason.
    DbError,
    /// `std.json.Stringify.valueAlloc` failed for the response
    /// envelope (effectively unreachable on the per-request arena).
    OutOfMemory,
};

// =====================================================================
// Use case
// =====================================================================

fn useCase(
    allocator: std.mem.Allocator,
    io: std.Io,
    db: *nalarcore.sqlite.SqliteBackend,
    page_id: []const u8,
) DesignPageDeleteError!void {
    if (page_id.len == 0) return error.PageIdRequired;

    const deleted = design_model.deletePage(allocator, io, db, page_id) catch return error.DbError;
    if (!deleted) return error.PageNotFound;
}

// =====================================================================
// Handler
// =====================================================================

pub fn designPagesDeleteHandler(
    ctx: gserverz.HttpContext,
    req: gserverz.HttpRequest,
    res: gserverz.HttpResponse,
) !gserverz.HttpResponse {
    const allocator = ctx.allocator;
    const io = ctx.io;

    const di = try nalarcore.getSingleton();
    const sqlite_db = di.db;

    const page_id = req.params.get("page_id") orelse "";

    useCase(allocator, io, sqlite_db, page_id) catch |err| {
        const status: u16 = switch (err) {
            error.PageIdRequired => 400,
            error.PageNotFound => 404,
            error.DbError => 500,
            error.OutOfMemory => 500,
        };
        const message: []const u8 = switch (err) {
            error.PageIdRequired => "page_id required",
            error.PageNotFound => "Page not found",
            error.DbError => "Failed to delete page",
            error.OutOfMemory => "Out of memory",
        };
        return res.jsonResponse(.{
            .status_code = status,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = message }),
        });
    };

    const SuccessResponse = struct { success: bool = true };
    return res.jsonResponse(.{
        .status_code = 200,
        .data = try std.json.Stringify.valueAlloc(
            allocator,
            SuccessResponse{},
            .{},
        ),
    });
}

// ===== Tests merged from design_pages_delete_test.zig (2026-09-11 flatten) =====
// Static regression checks for the `DELETE /design/pages/:page_id` handler.
// 
// Why this file exists
// ────────────────────
// The page-delete endpoint removes a design page's metadata row AND
// unlinks its on-disk `<item_path>/.nalar/design/<sanitized_page>/`
// folder. The handler is a thin wrapper:
//   1. Reads `page_id` from the path params.
//   2. Calls `design_model.deletePage(...)` (which does the SQL
//      DELETE + on-disk rmdir in the right order).
//   3. Returns 200 with `{success: true}` on a successful delete,
//      404 if the page did not exist.
// 
// These contracts are enforced by static substring checks, matching
// the project's `design_elements_delete_test.zig` pattern.
// 
// Plan: docs/superpowers/plans/2026-07-25-design-page-delete-button.md
//   (Chunk 1)

const testing = std.testing;
const text_normalize = @import("helpers").text_normalize;

const HANDLER_PATH = "src/http_handlers/design_pages_delete.zig";

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

// ─── Contract 1: handler calls design_model.deletePage ───────────────────

test "design_pages_delete handler calls design_model.deletePage" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    if (std.mem.indexOf(u8, source, "design_model.deletePage") == null) {
        std.debug.print(
            "\n!! {s} does not call design_model.deletePage !!\n" ++
                "   The DELETE contract is broken: the handler must delegate to\n" ++
                "   `design_model.deletePage(allocator, db, page_id)`.\n",
            .{HANDLER_PATH},
        );
        return error.DeletePageCallMissing;
    }
}

// ─── Contract 2: handler returns 200 + success envelope ───────────────────

test "design_pages_delete handler returns 200 + success envelope" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    if (std.mem.indexOf(u8, source, ".status_code = 200") == null) {
        std.debug.print(
            "\n!! {s} does not return 200 on success !!\n" ++
                "   Use `.status_code = 200` on the success branch.\n",
            .{HANDLER_PATH},
        );
        return error.Status200Missing;
    }

    if (std.mem.indexOf(u8, source, "success: bool = true") == null) {
        std.debug.print(
            "\n!! {s} does not emit a success:true envelope !!\n" ++
                "   The response-shape contract is broken: the handler must return\n" ++
                "   a success:true body via std.json.Stringify.valueAlloc.\n",
            .{HANDLER_PATH},
        );
        return error.SuccessEnvelopeMissing;
    }
}

// ─── Contract 3: handler maps PageNotFound to 404 ────────────────────────

test "design_pages_delete handler maps PageNotFound to 404" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    if (std.mem.indexOf(u8, source, "error.PageNotFound => 404") == null) {
        std.debug.print(
            "\n!! {s} does not map PageNotFound to 404 !!\n" ++
                "   The status contract is broken: missing pages must return 404.\n",
            .{HANDLER_PATH},
        );
        return error.PageNotFoundStatusMissing;
    }
}

// ─── Contract 4: handler validates the page_id path param ────────────────

test "design_pages_delete handler validates page_id path param" {
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
