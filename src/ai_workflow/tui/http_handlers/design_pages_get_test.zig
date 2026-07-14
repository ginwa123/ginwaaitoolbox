//! Static regression checks for the `GET /design/pages/:page_id` handler.
//!
//! Why this file exists
//! ────────────────────
//! The page-get endpoint returns one design page plus all its
//! elements (without HTML bodies — those are fetched lazily). The
//! handler is a thin wrapper that:
//!   1. Reads `page_id` from the path params.
//!   2. Calls `design_model.getPageWithElements(allocator, db, page_id)`.
//!   3. Returns the page + elements via
//!      `http_response.makeDesignPageWithElementsResponse` (typed
//!      envelope `{page, elements}`).
//!
//! These contracts are enforced by static substring checks, matching
//! the project's `kanban_columns_list_test.zig` pattern.
//!
//! Plan: docs/superpowers/plans/2026-07-08-design-mode-redesign.md
//!   (Chunk 3, Task 3.2)

const std = @import("std");
const testing = std.testing;
const nalarcore = @import("nalarcore");
const text_normalize = nalarcore.helpers.text_normalize;

const HANDLER_PATH = "src/ai_workflow/tui/http_handlers/design_pages_get.zig";

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