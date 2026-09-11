//! Static regression checks for the `PATCH /design/pages/:page_id` handler.
//!
//! Why this file exists
//! ────────────────────
//! The page-update endpoint writes width/height to an existing
//! design page. The handler must:
//!   1. Parse `{width, height}` via `parseFromSliceLeaky`.
//!   2. Call `design_model.updateDesignPage(...)`.
//!   3. Return 200 with the page as a `DesignPageResponse`.
//!
//! These contracts are enforced by static substring checks, matching
//! the project's `design_pages_create_test.zig` pattern.
//!
//! Plan: docs/superpowers/plans/2026-07-19-design-canvas-resize-and-zoom.md
//!   (Chunk 1, Task 1.3)

const std = @import("std");
const testing = std.testing;
const nalarcore = @import("nalarcore");
const text_normalize = @import("helpers").text_normalize;

const HANDLER_PATH = "src/http_handlers/design_pages_update.zig";

/// Read a source file from disk, relative to the project root.
/// Normalizes CRLF → LF so multi-line literal needles match even when
/// the file was checked out on Windows with autocrlf=true. The
/// returned buffer is owned by the caller.
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

test "design_pages_update handler parses body with parseFromSliceLeaky" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    if (std.mem.indexOf(u8, source, "parseFromSliceLeaky") == null) {
        std.debug.print(
            "\n!! {s} does not use parseFromSliceLeaky !!\n" ++
                "   The update-body contract is broken. Switch from `parseFromSlice`\n" ++
                "   to `parseFromSliceLeaky`.\n",
            .{HANDLER_PATH},
        );
        return error.ParseFromSliceLeakyMissing;
    }

    if (std.mem.indexOf(u8, source, "parsed.width") == null) {
        std.debug.print(
            "\n!! {s} does not extract .width from the parsed body !!\n" ++
                "   The handler must reference `parsed.width` for the update.\n",
            .{HANDLER_PATH},
        );
        return error.WidthExtractionMissing;
    }

    if (std.mem.indexOf(u8, source, "parsed.height") == null) {
        std.debug.print(
            "\n!! {s} does not extract .height from the parsed body !!\n" ++
                "   The handler must reference `parsed.height` for the update.\n",
            .{HANDLER_PATH},
        );
        return error.HeightExtractionMissing;
    }
}

// ─── Contract 2: handler calls design_model.updateDesignPage ─────────────

test "design_pages_update handler calls design_model.updateDesignPage" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    if (std.mem.indexOf(u8, source, "design_model.updateDesignPage") == null) {
        std.debug.print(
            "\n!! {s} does not call design_model.updateDesignPage !!\n" ++
                "   The PATCH contract is broken: the handler must delegate to\n" ++
                "   `design_model.updateDesignPage(...)` (NOT raw SQL).\n",
            .{HANDLER_PATH},
        );
        return error.UpdateDesignPageCallMissing;
    }
}

// ─── Contract 3: handler returns 200 on success ──────────────────────────

test "design_pages_update handler returns 200 on success" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    if (std.mem.indexOf(u8, source, ".status_code = 200") == null) {
        std.debug.print(
            "\n!! {s} does not return a 200 status code !!\n" ++
                "   PATCH should return 200 (UPDATE is not a creation).\n",
            .{HANDLER_PATH},
        );
        return error.Status200Missing;
    }
}

// ─── Contract 4: handler maps WidthOutOfRange to 400 with right message ──

test "design_pages_update handler maps WidthOutOfRange to 400 + correct message" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    if (std.mem.indexOf(u8, source, "width must be between 320 and 4096") == null) {
        std.debug.print(
            "\n!! {s} does not contain the 'width must be between 320 and 4096' message !!\n" ++
                "   The handler must map `WidthOutOfRange` to a 400 with this\n" ++
                "   exact message so the frontend can surface it.\n",
            .{HANDLER_PATH},
        );
        return error.WidthOutOfRangeMessageMissing;
    }
}

// ─── Contract 5: handler maps HeightOutOfRange to 400 with right message ─

test "design_pages_update handler maps HeightOutOfRange to 400 + correct message" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    if (std.mem.indexOf(u8, source, "height must be between 240 and 4096") == null) {
        std.debug.print(
            "\n!! {s} does not contain the 'height must be between 240 and 4096' message !!\n" ++
                "   The handler must map `HeightOutOfRange` to a 400 with this\n" ++
                "   exact message so the frontend can surface it.\n",
            .{HANDLER_PATH},
        );
        return error.HeightOutOfRangeMessageMissing;
    }
}

// ─── Contract 6: handler uses std.json.Stringify.valueAlloc ──────────────

test "design_pages_update handler uses std.json.Stringify.valueAlloc" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    if (std.mem.indexOf(u8, source, "std.json.Stringify.valueAlloc") == null) {
        std.debug.print(
            "\n!! {s} does not use std.json.Stringify.valueAlloc !!\n" ++
                "   The response-shape contract is broken: the handler must use\n" ++
                "   `std.json.Stringify.valueAlloc` for the 200 response body.\n",
            .{HANDLER_PATH},
        );
        return error.ValueAllocMissing;
    }
}

// ─── Contract 7: handler maps PageNotFound to 404 ─────────────────────────

test "design_pages_update handler maps PageNotFound to 404" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    if (std.mem.indexOf(u8, source, "error.PageNotFound => 404") == null) {
        std.debug.print(
            "\n!! {s} does not map error.PageNotFound to 404 !!\n" ++
                "   The status switch must include `error.PageNotFound => 404`.\n",
            .{HANDLER_PATH},
        );
        return error.PageNotFoundMappingMissing;
    }
}
