//! Static regression checks for the `DELETE /kanban/columns/:id` handler.
//!
//! Why this file exists
//! ────────────────────
//! The column-delete endpoint removes a column from the kanban
//! (tasks that were assigned to it have their `kanban_column_id` set
//! to NULL by `kanban_model.deleteColumn`). The handler must:
//!   1. Read `item_id` and `column_id` from path params.
//!   2. Call `kanban_model.deleteColumn(...)`.
//!   3. Return 200 with a `{success: true, column_id}` body.
//!
//! Plan: docs/superpowers/plans/2026-06-21-workspace-item-kanban.md
//!   (Chunk 3, Task 3.6)

const std = @import("std");
const testing = std.testing;

const HANDLER_PATH = "src/ai_workflow/tui/http_handlers/kanban_columns_delete.zig";

fn readSource(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        path,
        allocator,
        .limited(256 * 1024),
    );
}

test "kanban_columns_delete handler does not parse a request body" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    // DELETE has no body — `parseFromSliceLeaky` would be wrong here.
    if (std.mem.indexOf(u8, source, "parseFromSliceLeaky") != null) {
        std.debug.print(
            "\n!! {s} uses parseFromSliceLeaky but DELETE has no body !!\n" ++
                "   Remove the body-parse call.\n",
            .{HANDLER_PATH},
        );
        return error.DeleteShouldNotParseBody;
    }
}

test "kanban_columns_delete handler calls kanban_model.deleteColumn" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    if (std.mem.indexOf(u8, source, "kanban_model.deleteColumn") == null) {
        std.debug.print(
            "\n!! {s} does not call kanban_model.deleteColumn !!\n",
            .{HANDLER_PATH},
        );
        return error.DeleteColumnCallMissing;
    }
}

test "kanban_columns_delete handler validates column_id + item_id" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    if (std.mem.indexOf(u8, source, "req.params.get(\"column_id\")") == null) {
        std.debug.print(
            "\n!! {s} does not read the column_id path param !!\n",
            .{HANDLER_PATH},
        );
        return error.ColumnIdParamMissing;
    }
    if (std.mem.indexOf(u8, source, "req.params.get(\"item_id\")") == null) {
        std.debug.print(
            "\n!! {s} does not read the item_id path param !!\n",
            .{HANDLER_PATH},
        );
        return error.ItemIdParamMissing;
    }
}

test "kanban_columns_delete handler returns 200 on success" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    // 200 (with a body) instead of 204 No Content because the
    // frontend expects the deleted column_id in the response for
    // optimistic UI update.
    if (std.mem.indexOf(u8, source, ".status_code = 200") == null) {
        std.debug.print(
            "\n!! {s} does not return 200 on success !!\n" ++
                "   Use `.status_code = 200` with a `{{success, column_id}}` body.\n",
            .{HANDLER_PATH},
        );
        return error.Status200Missing;
    }
}