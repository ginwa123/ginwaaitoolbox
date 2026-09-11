//! Static regression checks for the `GET .../elements/:eid/html` handler.
//!
//! Why this file exists
//! ────────────────────
//! The element-html-get endpoint lazy-loads an element's full HTML
//! body. The handler is a thin wrapper:
//!   1. Reads `element_id` from the path params.
//!   2. Calls `design_model.loadElementHtml(allocator, io, db, id)`.
//!   3. Returns the body via `std.json.Stringify.valueAlloc` as
//!      `{html: string}` (so quotes/backslashes are JSON-escaped).
//!
//! These contracts are enforced by static substring checks.
//!
//! Plan: docs/superpowers/plans/2026-07-08-design-mode-redesign.md
//!   (Chunk 3, Task 3.4)

const std = @import("std");
const testing = std.testing;
const nalarcore = @import("nalarcore");
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