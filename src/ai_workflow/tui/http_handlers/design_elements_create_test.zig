//! Static regression checks for the `POST .../pages/:pid/elements` handler.
//!
//! Why this file exists
//! ────────────────────
//! The element-create endpoint appends a new element to a design
//! page (atomically writes the HTML to disk + INSERTs the row).
//! The handler must:
//!   1. Parse `{name, type, html, ...}` via `parseFromSliceLeaky`,
//!      translating the wire `type` string to the `ElementType` enum.
//!   2. Call `design_model.addElement(...)`.
//!   3. Return 201 with the new element as a `DesignElementResponse`.
//!
//! These contracts are enforced by static substring checks, matching
//! the project's `kanban_columns_create_test.zig` pattern.
//!
//! Plan: docs/superpowers/plans/2026-07-08-design-mode-redesign.md
//!   (Chunk 3, Task 3.3)

const std = @import("std");
const testing = std.testing;
const nalarcore = @import("nalarcore");
const text_normalize = nalarcore.helpers.text_normalize;

const HANDLER_PATH = "src/ai_workflow/tui/http_handlers/design_elements_create.zig";

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

test "design_elements_create handler parses body with parseFromSliceLeaky" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    if (std.mem.indexOf(u8, source, "parseFromSliceLeaky") == null) {
        std.debug.print(
            "\n!! {s} does not use parseFromSliceLeaky !!\n" ++
                "   The create-body contract is broken. Switch from `parseFromSlice`\n" ++
                "   to `parseFromSliceLeaky`.\n",
            .{HANDLER_PATH},
        );
        return error.ParseFromSliceLeakyMissing;
    }
}

// ─── Contract 2: handler calls design_model.addElement ───────────────────

test "design_elements_create handler calls design_model.addElement" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    if (std.mem.indexOf(u8, source, "design_model.addElement") == null) {
        std.debug.print(
            "\n!! {s} does not call design_model.addElement !!\n" ++
                "   The POST contract is broken: the handler must delegate to\n" ++
                "   `design_model.addElement(allocator, db, io, input)`.\n",
            .{HANDLER_PATH},
        );
        return error.AddElementCallMissing;
    }
}

// ─── Contract 3: handler returns 201 on success ──────────────────────────

test "design_elements_create handler returns 201 on success" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    if (std.mem.indexOf(u8, source, ".status_code = 201") == null) {
        std.debug.print(
            "\n!! {s} does not return a 201 status code !!\n" ++
                "   Use `.status_code = 201` on the success branch.\n",
            .{HANDLER_PATH},
        );
        return error.Status201Missing;
    }
}

// ─── Contract 4: handler maps PageNotFound to 404 ─────────────────────────

test "design_elements_create handler maps PageNotFound to 404" {
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

// ─── Contract 5: handler validates the page_id path param ───────────────

test "design_elements_create handler validates page_id path param" {
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

// ─── Contract 6: handler translates type string to ElementType enum ──────

test "design_elements_create handler translates type string to enum" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    if (std.mem.indexOf(u8, source, "std.meta.stringToEnum") == null) {
        std.debug.print(
            "\n!! {s} does not use std.meta.stringToEnum for the type field !!\n" ++
                "   The wire-format contract is broken: the handler must translate\n" ++
                "   the `type` string to the `ElementType` enum via `std.meta.stringToEnum`.\n",
            .{HANDLER_PATH},
        );
        return error.TypeTranslationMissing;
    }
}