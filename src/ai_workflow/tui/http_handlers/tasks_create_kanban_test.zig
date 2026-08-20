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
const nalarcore = @import("nalarcore");
const text_normalize = @import("helpers").text_normalize;

const HANDLER_PATH = "src/ai_workflow/tui/http_handlers/task_create.zig";

/// Read a source file from disk, relative to the project root.
/// Normalizes CRLF → LF so multi-line literal needles match even when
/// the file was checked out on Windows with autocrlf=true (see
/// `.gitattributes` + `src/helpers/text_normalize.zig` for context).
/// The returned buffer is owned by the caller (freed with `allocator.free`).
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

// Regression for "task created in kanban doesn't appear in column" bug
// (user-reported 2026-06-24). The handler must include
// `kanban_column_id` + `kanban_position` in the 201 JSON response. Without
// them, the frontend's `workspacesStore.addTask` pushes a Task object with
// `kanban_column_id = undefined` into `item.tasks`, and
// `KanbanColumn.vue`'s `.filter((t) => t.kanban_column_id === column.id)`
// drops the card (visible on the kanban sidebar but invisible inside the
// column until a full page reload triggers `getTasks`).
//
// The fix: after the auto-assign UPDATE, re-SELECT the assigned values
// from the DB and include them in the JSON response alongside the
// existing `id`/`name`/`workspace_item_id`/`task_type`/`session_id` fields.
//
// As of 2026-07-02, the response is built via a typed struct +
// std.json.Stringify.valueAlloc (not hand-rolled std.fmt.allocPrint),
// so the substring check looks for the struct field declarations that
// valueAlloc will serialize into the JSON output.
test "tasks_create 201 response includes kanban_column_id and kanban_position" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    // The handler must declare `kanban_column_id` as a field of the
    // typed response struct (StandardResponse). valueAlloc serializes
    // that struct field as `"kanban_column_id":<value>` in the JSON
    // output. Look for the struct field declaration to distinguish
    // the response emission from the auto-assign SQL.
    if (std.mem.indexOf(u8, source, "kanban_column_id: ?[]const u8") == null) {
        std.debug.print(
            "\n!! {s} does not include kanban_column_id in the 201 response !!\n" ++
                "   The 201 JSON must carry the assigned column so the frontend's\n" ++
                "   workspacesStore.addTask pushes a Task with kanban_column_id set.\n" ++
                "   Without this, KanbanColumn.vue's filter drops the card and the\n" ++
                "   user sees the task in the sidebar but not in any column.\n" ++
                "   Add a `kanban_column_id: ?[]const u8` field to the response struct.\n",
            .{HANDLER_PATH},
        );
        return error.KanbanColumnIdInResponseMissing;
    }
    if (std.mem.indexOf(u8, source, "kanban_position: i64") == null) {
        std.debug.print(
            "\n!! {s} does not include kanban_position in the 201 response !!\n" ++
                "   The 201 JSON must carry the assigned position so the new card\n" ++
                "   sorts correctly within the column.\n",
            .{HANDLER_PATH},
        );
        return error.KanbanPositionInResponseMissing;
    }
}