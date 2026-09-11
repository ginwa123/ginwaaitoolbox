//! Static regression checks for the `DELETE /design/pages/:page_id` handler.
//!
//! Why this file exists
//! ────────────────────
//! The page-delete endpoint removes a design page's metadata row AND
//! unlinks its on-disk `<item_path>/.nalar/design/<sanitized_page>/`
//! folder. The handler is a thin wrapper:
//!   1. Reads `page_id` from the path params.
//!   2. Calls `design_model.deletePage(...)` (which does the SQL
//!      DELETE + on-disk rmdir in the right order).
//!   3. Returns 200 with `{success: true}` on a successful delete,
//!      404 if the page did not exist.
//!
//! These contracts are enforced by static substring checks, matching
//! the project's `design_elements_delete_test.zig` pattern.
//!
//! Plan: docs/superpowers/plans/2026-07-25-design-page-delete-button.md
//!   (Chunk 1)

const std = @import("std");
const testing = std.testing;
const nalarcore = @import("nalarcore");
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
