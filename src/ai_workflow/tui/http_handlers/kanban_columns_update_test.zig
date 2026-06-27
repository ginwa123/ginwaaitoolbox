//! Static regression checks for the `PATCH /kanban/columns/:id` handler.
//!
//! Why this file exists
//! ────────────────────
//! The column-update endpoint is a "rename" and/or "reorder" PATCH.
//! Both `name` and `position` are optional in the request body; the
//! handler must call `kanban_model.renameColumn` and/or
//! `kanban_model.reorderColumn` based on what's present.
//!
//! Plan: docs/superpowers/plans/2026-06-21-workspace-item-kanban.md
//!   (Chunk 3, Task 3.5)

const std = @import("std");
const testing = std.testing;

const HANDLER_PATH = "src/ai_workflow/tui/http_handlers/kanban_columns_update.zig";

fn readSource(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        path,
        allocator,
        .limited(256 * 1024),
    );
}

test "kanban_columns_update handler parses body with parseFromSliceLeaky" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    if (std.mem.indexOf(u8, source, "parseFromSliceLeaky") == null) {
        std.debug.print(
            "\n!! {s} does not use parseFromSliceLeaky !!\n" ++
                "   The PATCH body must be parsed via `parseFromSliceLeaky`.\n" ++
                "   See docs/superpowers/plans/2026-06-21-workspace-item-kanban.md.\n",
            .{HANDLER_PATH},
        );
        return error.ParseFromSliceLeakyMissing;
    }
}

test "kanban_columns_update handler extracts both name and position" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    // The PATCH body has TWO optional fields; the handler must
    // extract both. We look for `parsed.name` and `parsed.position`
    // as the standard pattern.
    if (std.mem.indexOf(u8, source, "parsed.name") == null) {
        std.debug.print(
            "\n!! {s} does not extract parsed.name !!\n" ++
                "   The handler must reference `parsed.name` for rename.\n",
            .{HANDLER_PATH},
        );
        return error.NameExtractionMissing;
    }
    if (std.mem.indexOf(u8, source, "parsed.position") == null) {
        std.debug.print(
            "\n!! {s} does not extract parsed.position !!\n" ++
                "   The handler must reference `parsed.position` for reorder.\n",
            .{HANDLER_PATH},
        );
        return error.PositionExtractionMissing;
    }
}

test "kanban_columns_update handler calls updateColumn + reorderColumn" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    // The handler must call BOTH the update and the reorder functions
    // (based on which body fields are present). If either is missing,
    // the PATCH is partially broken.
    if (std.mem.indexOf(u8, source, "kanban_model.updateColumn") == null) {
        std.debug.print(
            "\n!! {s} does not call kanban_model.updateColumn !!\n",
            .{HANDLER_PATH},
        );
        return error.UpdateColumnCallMissing;
    }
    if (std.mem.indexOf(u8, source, "kanban_model.reorderColumn") == null) {
        std.debug.print(
            "\n!! {s} does not call kanban_model.reorderColumn !!\n",
            .{HANDLER_PATH},
        );
        return error.ReorderColumnCallMissing;
    }
}

test "kanban_columns_update handler returns 200 on success" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    if (std.mem.indexOf(u8, source, ".status_code = 200") == null) {
        std.debug.print(
            "\n!! {s} does not return 200 on success !!\n" ++
                "   PATCH success should return 200 (not 204 — the handler\n" ++
                "   echoes the updated board, so there's a body).\n",
            .{HANDLER_PATH},
        );
        return error.Status200Missing;
    }
}

test "kanban_columns_update handler forwards description to kanban_model.updateColumn" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    if (std.mem.indexOf(u8, source, "parsed.description") == null) {
        std.debug.print(
            "\n!! {s} does not extract .description from the parsed body !!\n" ++
                "   The PATCH endpoint must accept `description` so the Settings UI can edit meanings.\n",
            .{HANDLER_PATH},
        );
        return error.DescriptionExtractionMissing;
    }
}