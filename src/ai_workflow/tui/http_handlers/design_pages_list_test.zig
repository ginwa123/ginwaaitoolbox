//! Static regression checks for the `GET /design/pages` handler.
//!
//! Why this file exists
//! ────────────────────
//! The page-list endpoint returns the `design_pages` rows for a
//! workspace item in position order. The handler is a thin wrapper
//! that:
//!   1. Reads `item_id` from the path params.
//!   2. Calls `design_model.listPages(allocator, db, item_id)`.
//!   3. Returns the rows via `http_response.makeDesignPageListResponse`
//!      (typed envelope `{pages, count}`).
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

const HANDLER_PATH = "src/ai_workflow/tui/http_handlers/design_pages_list.zig";

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