//! Static regression checks for the pinned-task reorder handler.
//!
//! Mirrors the `workspace_items_reorder_test.zig` pattern. The
//! pinned-task reorder endpoint assigns a new pinned_position per
//! row in the payload, scoped to a single workspace_item. These tests
//! assert the structural contract:
//!   1. The handler reads `ordered_ids` from the body.
//!   2. The handler calls `reorderPinnedTasks`.
//!   3. The use case filters by `is_pinned = 1` so unpinned rows
//!      in the payload are silently skipped.
//!   4. The use case uses `count - 1 - i` for the position formula.
//!   5. The response uses `makeTasksReorderPinnedResponse` (typed).
//!   6. `reorderPinnedTasks` is exposed in `llm_history.zig`.
//!   7. `TasksReorderPinnedResponse` + helper exist in
//!      `http_response.zig`.
//!
//! Plan: docs/superpowers/plans/2026-06-20-pinned-workspace-item-tasks.md

const std = @import("std");
const testing = std.testing;

const HANDLER_PATH = "src/ai_workflow/tui/http_handlers/tasks_reorder_pinned.zig";
const LLM_HISTORY_PATH = "src/ai_workflow/tui/llm_history.zig";
const RESPONSE_PATH = "src/ai_workflow/tui/http_handlers/http_response.zig";

fn readSource(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        path,
        allocator,
        .limited(256 * 1024),
    );
}

test "tasks_reorder_pinned handler parses ordered_ids" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    if (std.mem.indexOf(u8, source, "ordered_ids") == null) {
        std.debug.print(
            "\n!! {s} does not reference `ordered_ids` !!\n" ++
                "   The reorder endpoint is broken. The frontend POSTs\n" ++
                "   {{ordered_ids: [...]}} and expects a 200 + position updates.\n" ++
                "   See docs/superpowers/plans/2026-06-20-pinned-workspace-item-tasks.md.\n",
            .{HANDLER_PATH},
        );
        return error.OrderedIdsMissing;
    }
}

test "tasks_reorder_pinned handler calls reorderPinnedTasks use case" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    if (std.mem.indexOf(u8, source, "reorderPinnedTasks") == null) {
        std.debug.print(
            "\n!! {s} does not call reorderPinnedTasks !!\n" ++
                "   The reorder endpoint is silently a no-op.\n",
            .{HANDLER_PATH},
        );
        return error.ReorderPinnedTasksNotCalled;
    }
}

test "tasks_reorder_pinned scopes UPDATE by is_pinned = 1" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, LLM_HISTORY_PATH);
    defer allocator.free(source);

    // The use case should filter by is_pinned = 1 so a payload
    // containing unpinned rows is a silent no-op for them.
    if (std.mem.indexOf(u8, source, "is_pinned = 1") == null) {
        std.debug.print(
            "\n!! {s} does not filter by `is_pinned = 1` !!\n" ++
                "   An unpinned row in the payload would get a new\n" ++
                "   pinned_position without being pinned. Add: WHERE ... AND is_pinned = 1\n",
            .{LLM_HISTORY_PATH},
        );
        return error.IsPinnedFilterMissing;
    }
}

test "tasks_reorder_pinned use case uses position = (count - 1 - i) formula" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, LLM_HISTORY_PATH);
    defer allocator.free(source);

    if (std.mem.indexOf(u8, source, "count - 1 -") == null) {
        std.debug.print(
            "\n!! {s} is missing the `count - 1 - i` position formula !!\n" ++
                "   The reorder endpoint will assign positions in the\n" ++
                "   wrong direction (bottom-to-top instead of top-to-bottom).\n" ++
                "   Restore: const new_pos: i64 = count - 1 - @as(i64, @intCast(i));\n",
            .{LLM_HISTORY_PATH},
        );
        return error.PositionFormulaMissing;
    }
}

test "tasks_reorder_pinned handler uses makeTasksReorderPinnedResponse" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    if (std.mem.indexOf(u8, source, "makeTasksReorderPinnedResponse") == null) {
        std.debug.print(
            "\n!! {s} does not call makeTasksReorderPinnedResponse !!\n" ++
                "   Use the typed response helper in http_response.zig:\n" ++
                "     try http_response.makeTasksReorderPinnedResponse(allocator, count)\n",
            .{HANDLER_PATH},
        );
        return error.TypedResponseMissing;
    }
}

test "llm_history exposes reorderPinnedTasks" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, LLM_HISTORY_PATH);
    defer allocator.free(source);

    const sig = "pub fn reorderPinnedTasks(";
    if (std.mem.indexOf(u8, source, sig) == null) {
        std.debug.print(
            "\n!! {s} does not define `reorderPinnedTasks` !!\n" ++
                "   The handler has no use case to call. Add it next to\n" ++
                "   `setTaskPinned` in llm_history.zig.\n",
            .{LLM_HISTORY_PATH},
        );
        return error.ReorderPinnedTasksMissing;
    }
}

test "TasksReorderPinnedResponse and helper exist in http_response.zig" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, RESPONSE_PATH);
    defer allocator.free(source);

    if (std.mem.indexOf(u8, source, "TasksReorderPinnedResponse") == null) {
        std.debug.print(
            "\n!! {s} is missing TasksReorderPinnedResponse !!\n" ++
                "   Add: pub const TasksReorderPinnedResponse = struct {{ success: bool = true, count: usize }};\n",
            .{RESPONSE_PATH},
        );
        return error.TasksReorderPinnedResponseStructMissing;
    }
    if (std.mem.indexOf(u8, source, "makeTasksReorderPinnedResponse") == null) {
        std.debug.print(
            "\n!! {s} is missing makeTasksReorderPinnedResponse !!\n" ++
                "   Add: pub fn makeTasksReorderPinnedResponse(allocator, count) ![]u8 {{ ... }}.\n",
            .{RESPONSE_PATH},
        );
        return error.MakeTasksReorderPinnedResponseMissing;
    }
}
