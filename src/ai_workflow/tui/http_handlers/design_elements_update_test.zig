//! Static regression checks for the `PUT .../elements/:eid` handler.
//!
//! Why this file exists
//! ────────────────────
//! The element-update endpoint modifies one or more fields of an
//! existing design element. The handler must:
//!   1. Parse `{name?, type?, html?, ...}` via `parseFromSliceLeaky`.
//!   2. Call `design_model.updateElement(...)` with the non-null
//!      fields (each maps to a SET in the dynamic UPDATE).
//!   3. Return 200 with the post-update element as a
//!      `DesignElementResponse`.
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

const HANDLER_PATH = "src/ai_workflow/tui/http_handlers/design_elements_update.zig";

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

test "design_elements_update handler parses body with parseFromSliceLeaky" {
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
}

// ─── Contract 2: handler calls design_model.updateElement ────────────────

test "design_elements_update handler calls design_model.updateElement" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    if (std.mem.indexOf(u8, source, "design_model.updateElement") == null) {
        std.debug.print(
            "\n!! {s} does not call design_model.updateElement !!\n" ++
                "   The PUT contract is broken: the handler must delegate to\n" ++
                "   `design_model.updateElement(allocator, db, input)`.\n",
            .{HANDLER_PATH},
        );
        return error.UpdateElementCallMissing;
    }
}

// ─── Contract 3: handler returns 200 on success ──────────────────────────

test "design_elements_update handler returns 200 on success" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    if (std.mem.indexOf(u8, source, ".status_code = 200") == null) {
        std.debug.print(
            "\n!! {s} does not return a 200 status code !!\n" ++
                "   Use `.status_code = 200` on the success branch (PUT that\n" ++
                "   updates an existing resource, not 201 Created).\n",
            .{HANDLER_PATH},
        );
        return error.Status200Missing;
    }
}

// ─── Contract 4: handler maps ElementNotFound to 404 ────────────────────

test "design_elements_update handler maps ElementNotFound to 404" {
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

// ─── Contract 5: handler maps NoChanges to 400 ──────────────────────────

test "design_elements_update handler maps NoChanges to 400" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    if (std.mem.indexOf(u8, source, "error.NoChanges => 400") == null) {
        std.debug.print(
            "\n!! {s} does not map NoChanges to 400 !!\n" ++
                "   The status contract is broken: a PUT with no fields must return\n" ++
                "   400 so the frontend gets explicit feedback (instead of silently\n" ++
                "   succeeding).\n",
            .{HANDLER_PATH},
        );
        return error.NoChangesStatusMissing;
    }
}

// ─── Contract 6: handler validates the element_id path param ────────────

test "design_elements_update handler validates element_id path param" {
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