//! `DELETE /api/workspaces/:workspace_id/items/:item_id/design/pages/:page_id/elements/:element_id`.
//!
//! Delete a design element. The on-disk HTML file is unlinked
//! AFTER the SQL DELETE succeeds (defer-pattern) via
//! `design_model.deleteElement`. UI-only — no LLM tool exposes this
//! endpoint, only the DesignView.vue "delete" button.
//!
//! Response shape: `{"success": true}` on a successful delete.
//! Returns 404 if the element did not exist (so the frontend can
//! distinguish "already gone" from "deleted right now").
//!
//! Errors:
//!   - 400 missing `element_id` path param
//!   - 404 element not found
//!   - 500 DB failure
//!
//! Plan: docs/superpowers/plans/2026-07-08-design-mode-redesign.md
//!   (Chunk 3, Task 3.3)

const std = @import("std");
const pabrikcore = @import("pabrikcore");
const gserverz = pabrikcore.gserverz;
const http_response = @import("http_response.zig");
const design_model = @import("../agentic_loop/design_model.zig");

pub const DesignElementDeleteError = error{
    /// `:element_id` path param was missing or empty.
    ElementIdRequired,
    /// `design_model.deleteElement` returned `false` (no such row).
    ElementNotFound,
    /// `deleteElement` failed for some other DB reason.
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
    db: *pabrikcore.sqlite.SqliteBackend,
    element_id: []const u8,
) DesignElementDeleteError!void {
    if (element_id.len == 0) return error.ElementIdRequired;

    const deleted = design_model.deleteElement(allocator, db, element_id) catch return error.DbError;
    if (!deleted) return error.ElementNotFound;
}

// =====================================================================
// Handler
// =====================================================================

pub fn designElementsDeleteHandler(
    ctx: gserverz.HttpContext,
    req: gserverz.HttpRequest,
    res: gserverz.HttpResponse,
) !gserverz.HttpResponse {
    const allocator = ctx.allocator;

    const di = try pabrikcore.getSingleton();
    const sqlite_db = di.db;

    const element_id = req.params.get("element_id") orelse "";

    useCase(allocator, sqlite_db, element_id) catch |err| {
        const status: u16 = switch (err) {
            error.ElementIdRequired => 400,
            error.ElementNotFound => 404,
            error.DbError => 500,
            error.OutOfMemory => 500,
        };
        const message: []const u8 = switch (err) {
            error.ElementIdRequired => "element_id required",
            error.ElementNotFound => "Element not found",
            error.DbError => "Failed to delete element",
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

// ===== Tests merged from design_elements_delete_test.zig (2026-09-11 flatten) =====
// Static regression checks for the `DELETE .../elements/:eid` handler.
// 
// Why this file exists
// ────────────────────
// The element-delete endpoint removes an element's metadata row
// AND unlinks its on-disk HTML file. The handler is a thin wrapper:
//   1. Reads `element_id` from the path params.
//   2. Calls `design_model.deleteElement(...)` (which does the SQL
//      DELETE + unlink in the right order).
//   3. Returns 200 with `{success: true}` on a successful delete,
//      404 if the element did not exist.
// 
// These contracts are enforced by static substring checks, matching
// the project's `kanban_columns_delete_test.zig` pattern.
// 
// Plan: docs/superpowers/plans/2026-07-08-design-mode-redesign.md
//   (Chunk 3, Task 3.3)

const testing = std.testing;
const text_normalize = @import("helpers").text_normalize;

const HANDLER_PATH = "src/http_handlers/design_elements_delete.zig";

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

// ─── Contract 1: handler calls design_model.deleteElement ───────────────

test "design_elements_delete handler calls design_model.deleteElement" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    if (std.mem.indexOf(u8, source, "design_model.deleteElement") == null) {
        std.debug.print(
            "\n!! {s} does not call design_model.deleteElement !!\n" ++
                "   The DELETE contract is broken: the handler must delegate to\n" ++
                "   `design_model.deleteElement(allocator, db, element_id)`.\n",
            .{HANDLER_PATH},
        );
        return error.DeleteElementCallMissing;
    }
}

// ─── Contract 2: handler returns 200 + success envelope ──────────────────

test "design_elements_delete handler returns 200 + success envelope" {
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

// ─── Contract 3: handler maps ElementNotFound to 404 ────────────────────

test "design_elements_delete handler maps ElementNotFound to 404" {
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

test "design_elements_delete handler validates element_id path param" {
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
