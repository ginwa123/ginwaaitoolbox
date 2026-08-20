//! Static regression checks for the `PATCH .../elements/:eid/geometry` handler.
//!
//! Why this file exists
//! ────────────────────
//! The element-geometry-update endpoint modifies an element&apos;s
//! x/y/width/height/rotation (used by the canvas drag/resize
//! handlers). The handler must:
//!   1. Parse `{x?, y?, width?, height?, rotation?}` via
//!      `parseFromSliceLeaky`.
//!   2. Call `design_model.updateElement(allocator, db, .{element_id,
//!      x, y, width, height, rotation})`.
//!   3. Return 200 with the post-update element as a
//!      `DesignElementResponse`.
//!
//! These contracts are enforced by static substring checks.
//!
//! Plan: docs/superpowers/plans/2026-07-08-design-mode-redesign.md
//!   (Chunk 3, Task 3.4)

const std = @import("std");
const testing = std.testing;
const nalarcore = @import("nalarcore");
const text_normalize = @import("helpers").text_normalize;

const HANDLER_PATH = "src/ai_workflow/tui/http_handlers/design_elements_geometry_update.zig";

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

test "design_elements_geometry_update handler parses body with parseFromSliceLeaky" {
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

// ─── Contract 2: handler calls design_model.updateElement ────────────────

test "design_elements_geometry_update handler calls design_model.updateElement" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    if (std.mem.indexOf(u8, source, "design_model.updateElement") == null) {
        std.debug.print(
            "\n!! {s} does not call design_model.updateElement !!\n" ++
                "   The PATCH-geometry contract is broken: the handler must\n" ++
                "   delegate to `design_model.updateElement` with the geometry fields.\n",
            .{HANDLER_PATH},
        );
        return error.UpdateElementCallMissing;
    }
}

// ─── Contract 3: handler returns 200 on success ──────────────────────────

test "design_elements_geometry_update handler returns 200 on success" {
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

test "design_elements_geometry_update handler maps ElementNotFound to 404" {
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

// ─── Contract 5: handler extracts geometry fields from parsed body ───────

test "design_elements_geometry_update handler extracts geometry fields" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    if (std.mem.indexOf(u8, source, "parsed.x") == null or
        std.mem.indexOf(u8, source, "parsed.y") == null)
    {
        std.debug.print(
            "\n!! {s} does not extract parsed.x and parsed.y !!\n" ++
                "   The patch contract is broken: the handler must reference\n" ++
                "   `parsed.x` and `parsed.y` for the new geometry values.\n",
            .{HANDLER_PATH},
        );
        return error.GeometryFieldsMissing;
    }
}

// ─── Contract 6: handler validates the element_id path param ───────────

test "design_elements_geometry_update handler validates element_id path param" {
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