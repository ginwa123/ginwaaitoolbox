//! Static regression checks for the `PATCH /tasks/:task_id/move` handler.
//!
//! Why this file exists
//! ────────────────────
//! The task-move endpoint is the backend target of the kanban board's
//! drag-and-drop interaction. The handler must:
//!   1. Read `item_id` and `task_id` from the path params.
//!   2. Parse `{column_id, position}` from the JSON body via
//!      `parseFromSliceLeaky`.
//!   3. Call `kanban_model.moveTask(...)`.
//!   4. Return 200 with a `{success, task_id, column_id, position}` body.
//!
//! Plan: docs/superpowers/plans/2026-06-21-workspace-item-kanban.md
//!   (Chunk 3, Task 3.7)

const std = @import("std");
const testing = std.testing;
const nalarcore = @import("nalarcore");
const text_normalize = @import("helpers").text_normalize;

const HANDLER_PATH = "src/ai_workflow/tui/http_handlers/tasks_move.zig";

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

test "tasks_move handler calls kanban_model.moveTask" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    if (std.mem.indexOf(u8, source, "kanban_model.moveTask") == null) {
        std.debug.print(
            "\n!! {s} does not call kanban_model.moveTask !!\n" ++
                "   The move-pipeline contract is broken. Restore:\n" ++
                "     kanban_model.moveTask(allocator, sqlite_db, item_id, task_id, parsed.column_id, parsed.position) catch ...;\n",
            .{HANDLER_PATH},
        );
        return error.MoveTaskCallMissing;
    }
}

test "tasks_move handler extracts column_id and position from body" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    if (std.mem.indexOf(u8, source, ".column_id") == null) {
        std.debug.print(
            "\n!! {s} does not extract .column_id from the parsed body !!\n",
            .{HANDLER_PATH},
        );
        return error.ColumnIdExtractionMissing;
    }
    if (std.mem.indexOf(u8, source, ".position") == null) {
        std.debug.print(
            "\n!! {s} does not extract .position from the parsed body !!\n",
            .{HANDLER_PATH},
        );
        return error.PositionExtractionMissing;
    }
}

test "tasks_move handler uses parseFromSliceLeaky for the body" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    if (std.mem.indexOf(u8, source, "parseFromSliceLeaky") == null) {
        std.debug.print(
            "\n!! {s} does not use parseFromSliceLeaky !!\n" ++
                "   The PATCH body must be parsed via `parseFromSliceLeaky`.\n",
            .{HANDLER_PATH},
        );
        return error.ParseFromSliceLeakyMissing;
    }
}

test "tasks_move handler returns 200 on success" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    if (std.mem.indexOf(u8, source, ".status_code = 200") == null) {
        std.debug.print(
            "\n!! {s} does not return 200 on success !!\n",
            .{HANDLER_PATH},
        );
        return error.Status200Missing;
    }
}