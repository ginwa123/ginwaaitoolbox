//! `PATCH /api/workspaces/:workspace_id/items/:item_id/design/pages/:page_id/elements/:element_id/html`.
//!
//! Update an element's HTML body atomically (rewrites the on-disk
//! file via `design_io.atomicWriteFile`). Used by both the
//! iframe's contenteditable (`onBlur` handler) and the Monaco
//! editor in the properties panel.
//!
//! Body: `{html: string}` (the full HTML body — replaces whatever
//! was there previously).
//!
//! Response shape: `DesignElementResponse` for the post-update
//! element. Built by `http_response.makeDesignElementResponse` and
//! wrapped via `std.json.Stringify.valueAlloc`.
//!
//! Errors:
//!   - 400 missing `element_id` path param, invalid JSON body,
//!     missing/empty `html` field
//!   - 404 `element_id` not found
//!   - 500 DB failure or file-write failure
//!
//! Plan: docs/superpowers/plans/2026-07-08-design-mode-redesign.md
//!   (Chunk 3, Task 3.4)

const std = @import("std");
const nalarcore = @import("nalarcore");
const gserverz = nalarcore.gserverz;
const http_response = @import("http_response.zig");
const design_model = @import("../agentic_loop/design_model.zig");

/// HTTP request body for HTML-update. The only required field is
/// `html` (the new body).
const UpdateHtmlBody = struct {
    html: []const u8,
};

/// Domain-level error set for `useCase`. The handler maps each
/// variant to an HTTP status code + message via two exhaustive
/// switches.
pub const DesignElementHtmlUpdateError = error{
    /// `:element_id` path param was missing or empty.
    ElementIdRequired,
    /// Body `html` field was missing or empty.
    HtmlRequired,
    /// `design_model.updateElement` returned `ElementNotFound`.
    ElementNotFound,
    /// `updateElement` returned `FileWriteFailed` (atomic rename
    /// of the on-disk HTML file failed).
    FileWriteFailed,
    /// `updateElement` failed for some other DB reason.
    DbError,
    /// Update succeeded but the element wasn't visible in the
    /// subsequent `getElement` (consistency violation).
    ElementNotVisible,
    /// `allocator.dupe` failed while building the output struct.
    OutOfMemory,
};

/// Output of the update-html use-case.
pub const UpdateHtmlOutput = struct {
    /// The post-update element. Heap-owned by the use-case.
    element: design_model.DesignElement,
};

// =====================================================================
// Use case
// =====================================================================

fn useCase(
    allocator: std.mem.Allocator,
    db: *nalarcore.sqlite.SqliteBackend,
    element_id: []const u8,
    html: []const u8,
) DesignElementHtmlUpdateError!UpdateHtmlOutput {
    if (element_id.len == 0) return error.ElementIdRequired;
    if (html.len == 0) return error.HtmlRequired;

    const updated_id = design_model.updateElement(allocator, db, .{
        .element_id = element_id,
        .html = html,
    }) catch |err| switch (err) {
        error.ElementNotFound => return error.ElementNotFound,
        error.FileWriteFailed => return error.FileWriteFailed,
        else => return error.DbError,
    };
    defer allocator.free(updated_id);

    const element = design_model.getElement(allocator, db, updated_id) catch return error.ElementNotVisible;
    errdefer design_model.freeElement(allocator, element);

    return .{ .element = element };
}

// =====================================================================
// Handler
// =====================================================================

pub fn designElementsHtmlUpdateHandler(
    ctx: gserverz.HttpContext,
    req: gserverz.HttpRequest,
    res: gserverz.HttpResponse,
) !gserverz.HttpResponse {
    const allocator = ctx.allocator;

    const di = try nalarcore.getSingleton();
    const sqlite_db = di.db;

    // 1. Validate path params + body presence + JSON shape.
    const element_id = req.params.get("element_id") orelse "";
    if (element_id.len == 0) {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "element_id required" }),
        });
    }

    if (req.body.len == 0) {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Request body required" }),
        });
    }

    const parsed = std.json.parseFromSliceLeaky(UpdateHtmlBody, allocator, req.body, .{}) catch {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Invalid JSON body" }),
        });
    };

    if (parsed.html.len == 0) {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "html is required" }),
        });
    }

    // 2. Delegate to the use-case.
    const output = useCase(allocator, sqlite_db, element_id, parsed.html) catch |err| {
        const status: u16 = switch (err) {
            error.ElementIdRequired => 400,
            error.HtmlRequired => 400,
            error.ElementNotFound => 404,
            error.FileWriteFailed => 500,
            error.DbError => 500,
            error.ElementNotVisible => 500,
            error.OutOfMemory => 500,
        };
        const message: []const u8 = switch (err) {
            error.ElementIdRequired => "element_id required",
            error.HtmlRequired => "html is required",
            error.ElementNotFound => "Element not found",
            error.FileWriteFailed => "Failed to write element HTML file",
            error.DbError => "Failed to update element HTML",
            error.ElementNotVisible => "Element was updated but not visible",
            error.OutOfMemory => "Out of memory",
        };
        return res.jsonResponse(.{
            .status_code = status,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = message }),
        });
    };

    // Free the useCase's heap-owned element slices (no-op on arena).
    defer design_model.freeElement(allocator, output.element);

    // 4. Build the success response (200 OK — PATCH that updates
    //    an existing resource).
    return res.jsonResponse(.{
        .status_code = 200,
        .data = try std.json.Stringify.valueAlloc(
            allocator,
            http_response.makeDesignElementResponse(output.element),
            .{},
        ),
    });
}

// ===== Tests merged from design_elements_html_update_test.zig (2026-09-11 flatten) =====
// Static regression checks for the `PATCH .../elements/:eid/html` handler.
// 
// Why this file exists
// ────────────────────
// The element-html-update endpoint atomically rewrites an
// element's on-disk HTML file (used by the iframe's contenteditable
// + Monaco editor). The handler must:
//   1. Parse `{html}` via `parseFromSliceLeaky`.
//   2. Call `design_model.updateElement(allocator, db, .{element_id, html})`.
//   3. Return 200 with the post-update element as a
//      `DesignElementResponse`.
// 
// These contracts are enforced by static substring checks.
// 
// Plan: docs/superpowers/plans/2026-07-08-design-mode-redesign.md
//   (Chunk 3, Task 3.4)

const testing = std.testing;
const text_normalize = @import("helpers").text_normalize;

const HANDLER_PATH = "src/http_handlers/design_elements_html_update.zig";

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

// ─── Contract 1: handler uses parseFromSliceLeaky ────────────────────────

test "design_elements_html_update handler parses body with parseFromSliceLeaky" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    if (std.mem.indexOf(u8, source, "parseFromSliceLeaky") == null) {
        std.debug.print(
            "\n!! {s} does not use parseFromSliceLeaky !!\n" ++
                "   The patch-body contract is broken. Switch from `parseFromSlice`\n" ++
                "   to `parseFromSliceLeaky`.\n",
            .{HANDLER_PATH},
        );
        return error.ParseFromSliceLeakyMissing;
    }
}

// ─── Contract 2: handler calls design_model.updateElement with html ─────

test "design_elements_html_update handler calls design_model.updateElement" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    if (std.mem.indexOf(u8, source, "design_model.updateElement") == null) {
        std.debug.print(
            "\n!! {s} does not call design_model.updateElement !!\n" ++
                "   The PATCH-html contract is broken: the handler must delegate to\n" ++
                "   `design_model.updateElement` with element_id and html fields.\n",
            .{HANDLER_PATH},
        );
        return error.UpdateElementCallMissing;
    }
}

// ─── Contract 3: handler returns 200 on success ──────────────────────────

test "design_elements_html_update handler returns 200 on success" {
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
}

// ─── Contract 4: handler maps ElementNotFound to 404 ─────────────────────

test "design_elements_html_update handler maps ElementNotFound to 404" {
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

// ─── Contract 5: handler extracts .html field from parsed body ────────────

test "design_elements_html_update handler extracts .html field" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    if (std.mem.indexOf(u8, source, "parsed.html") == null) {
        std.debug.print(
            "\n!! {s} does not extract .html from the parsed body !!\n" ++
                "   The patch contract is broken: the handler must read\n" ++
                "   `parsed.html` and pass it to `design_model.updateElement`.\n",
            .{HANDLER_PATH},
        );
        return error.HtmlFieldExtractionMissing;
    }
}

// ─── Contract 6: handler validates the element_id path param ───────────

test "design_elements_html_update handler validates element_id path param" {
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
