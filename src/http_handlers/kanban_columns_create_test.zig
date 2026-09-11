//! Static regression checks for the `POST /kanban/columns` handler.
//!
//! Why this file exists
//! ────────────────────
//! The column-create endpoint appends a new column to a kanban
//! (default `MAX(position) + 1`, or at an explicit position if the
//! caller passes one). The handler must:
//!   1. Parse `{name, position?}` via `parseFromSliceLeaky`.
//!   2. Call `kanban_model.addColumn(...)`.
//!   3. Return 201 with the new column as a `KanbanColumnResponse`.
//!
//! Plan: docs/superpowers/plans/2026-06-21-workspace-item-kanban.md
//!   (Chunk 3, Task 3.4)

const std = @import("std");
const testing = std.testing;
const nalarcore = @import("nalarcore");
const text_normalize = @import("helpers").text_normalize;

const HANDLER_PATH = "src/http_handlers/kanban_columns_create.zig";

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

test "kanban_columns_create handler parses body with parseFromSliceLeaky" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    // The handler must use `parseFromSliceLeaky` (per-request arena
    // owns the memory — no explicit deinit needed). See project
    // memory `nalar-http-handler-thin-wrapper-pattern`.
    if (std.mem.indexOf(u8, source, "parseFromSliceLeaky") == null) {
        std.debug.print(
            "\n!! {s} does not use parseFromSliceLeaky !!\n" ++
                "   The create-body contract is broken. Switch from `parseFromSlice`\n" ++
                "   to `parseFromSliceLeaky`.\n" ++
                "   See docs/superpowers/plans/2026-06-21-workspace-item-kanban.md.\n",
            .{HANDLER_PATH},
        );
        return error.ParseFromSliceLeakyMissing;
    }
    // The handler must extract the `name` field (e.g. `parsed.name`)
    // and pass it to `kanban_model.addColumn`.
    if (std.mem.indexOf(u8, source, "parsed.name") == null) {
        std.debug.print(
            "\n!! {s} does not extract .name from the parsed body !!\n" ++
                "   The handler must reference `parsed.name` for the new column.\n",
            .{HANDLER_PATH},
        );
        return error.NameExtractionMissing;
    }
}

test "kanban_columns_create handler calls kanban_model.addColumn" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    // The handler must delegate to `kanban_model.addColumn` (NOT raw
    // SQL). If the call is missing, the POST endpoint is broken.
    if (std.mem.indexOf(u8, source, "kanban_model.addColumn") == null) {
        std.debug.print(
            "\n!! {s} does not call kanban_model.addColumn !!\n" ++
                "   Restore:\n" ++
                "     const new_id = kanban_model.addColumn(allocator, sqlite_db, item_id, parsed.name, parsed.position) catch ...;\n",
            .{HANDLER_PATH},
        );
        return error.AddColumnCallMissing;
    }
}

test "kanban_columns_create handler returns 201 on success" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    // POST that creates a resource → 201 Created.
    if (std.mem.indexOf(u8, source, ".status_code = 201") == null) {
        std.debug.print(
            "\n!! {s} does not return a 201 status code !!\n" ++
                "   Use `.status_code = 201` on the success branch.\n",
            .{HANDLER_PATH},
        );
        return error.Status201Missing;
    }
}

test "kanban_columns_create handler extracts description from parsed body" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    // The handler must extract `description` from the parsed body
    // (defaulting to empty string when null) and pass it to
    // kanban_model.addColumn.
    if (std.mem.indexOf(u8, source, "parsed.description") == null) {
        std.debug.print(
            "\n!! {s} does not extract .description from the parsed body !!\n" ++
                "   The handler must reference `parsed.description` (or default to \"\") for the new column.\n",
            .{HANDLER_PATH},
        );
        return error.DescriptionExtractionMissing;
    }
}