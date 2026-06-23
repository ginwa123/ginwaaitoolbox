//! Static regression checks for the kanban auto-assign extension to
//! `task_create.zig` (Chunk 3, Task 3.8).
//!
//! Why this file exists
//! ────────────────────
//! The Workspace Item Kanban feature (plan:
//! `2026-06-21-workspace-item-kanban.md`) extends the existing
//! `POST /api/workspaces/:wsId/items/:itemId/tasks` handler so that
//! tasks created under a kanban parent are auto-assigned to the
//! first column (`ORDER BY position ASC LIMIT 1`) at
//! `MAX(kanban_position) + 1`.
//!
//! Without this extension, a freshly-created kanban task would have
//! `kanban_column_id = NULL` and the frontend would have to send a
//! separate `PATCH /tasks/:id/move` to place the card. The auto-assign
//! removes that round-trip for the common case (task added under a
//! kanban via the "Add Card" button).
//!
//! These contracts are enforced by static substring checks, matching
//! the project's `task_create_routines_test.zig` pattern.
//!
//! Plan: docs/superpowers/plans/2026-06-21-workspace-item-kanban.md
//!   (Chunk 3, Task 3.8)

const std = @import("std");
const testing = std.testing;

const HANDLER_PATH = "src/ai_workflow/tui/http_handlers/task_create.zig";

/// Read a source file from disk, relative to the project root.
fn readSource(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        path,
        allocator,
        .limited(256 * 1024),
    );
}

test "tasks_create sets kanban_column_id when parent is kanban" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    // The handler must UPDATE `kanban_column_id = ?` on the freshly-
    // created task row, AND it must check `item_type = 'kanban'` to
    // gate the auto-assign. Without either substring the contract is
    // broken.
    if (std.mem.indexOf(u8, source, "kanban_column_id = ?") == null) {
        std.debug.print(
            "\n!! {s} does not UPDATE kanban_column_id !!\n" ++
                "   The auto-assign contract is broken: the handler must run\n" ++
                "   an UPDATE on the freshly-created task to set\n" ++
                "   `kanban_column_id = <first-column-id>`. Add:\n" ++
                "     UPDATE workspace_item_tasks SET kanban_column_id = ?,\n" ++
                "       kanban_position = (SELECT COALESCE(MAX(kanban_position), -1) + 1 FROM ...)\n" ++
                "     WHERE id = ?\n" ++
                "   See docs/superpowers/plans/2026-06-21-workspace-item-kanban.md.\n",
            .{HANDLER_PATH},
        );
        return error.KanbanColumnAssignmentMissing;
    }
    if (std.mem.indexOf(u8, source, "item_type = 'kanban'") == null) {
        std.debug.print(
            "\n!! {s} does not check item_type = 'kanban' !!\n" ++
                "   The auto-assign must be gated on the parent item being a kanban.\n" ++
                "   Add a SELECT + eql check for `item_type = 'kanban'` before the UPDATE.\n",
            .{HANDLER_PATH},
        );
        return error.KanbanTypeCheckMissing;
    }
}