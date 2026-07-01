//! Static regression checks for the `DELETE /kanban/columns/:id` handler.
//!
//! Why this file exists
//! ────────────────────
//! The column-delete endpoint removes a column from the kanban. The
//! handler must:
//!   1. Read `item_id` and `column_id` from path params.
//!   2. Refuse the delete (HTTP 409) when the column still has tasks
//!      assigned — the user must move them first. This protects against
//!      silently re-parenting tasks to "unassigned" without consent.
//!   3. Call `kanban_model.deleteColumn(...)` only after the task-count
//!      check passes.
//!   4. Return 200 with a `{success: true, column_id}` body.
//!
//! Plan: docs/superpowers/plans/2026-06-21-workspace-item-kanban.md
//!   (Chunk 3, Task 3.6)

const std = @import("std");
const testing = std.testing;
const nalarcore = @import("nalarcore");
const text_normalize = nalarcore.helpers.text_normalize;

const HANDLER_PATH = "src/ai_workflow/tui/http_handlers/kanban_columns_delete.zig";

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

// ─── Contract: handler validates the column has no tasks before deleting ──

test "kanban_columns_delete handler calls countTasksInColumn before deleteColumn" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    // The handler must call `kanban_model.countTasksInColumn` to gate
    // the delete on the column's current task count. Without this
    // check, the handler would silently re-parent tasks to NULL when
    // the user deletes a non-empty column.
    //
    // We search for the FULL call signatures (with `(` and the
    // namespace prefix) — the function name also appears in the
    // docstring as a backtick-wrapped reference, which would
    // produce a false-positive match if we only looked for the bare
    // name.
    const count_call_idx = std.mem.indexOf(u8, source, "kanban_model.countTasksInColumn(");
    const delete_call_idx = std.mem.indexOf(u8, source, "kanban_model.deleteColumn(");
    if (count_call_idx == null) {
        std.debug.print(
            "\n!! {s} does not call kanban_model.countTasksInColumn !!\n" ++
                "   The delete-validation contract is broken: the handler is missing\n" ++
                "   the pre-delete task-count check. Add a `countTasksInColumn(...)`\n" ++
                "   call before `deleteColumn(...)` and return 409 when the count\n" ++
                "   is > 0.\n",
            .{HANDLER_PATH},
        );
        return error.CountTasksCallMissing;
    }
    if (delete_call_idx == null) {
        std.debug.print(
            "\n!! {s} does not call kanban_model.deleteColumn !!\n" ++
                "   (Note: the test searches for the full call signature\n" ++
                "   `kanban_model.deleteColumn(` to avoid matching the docstring.)\n",
            .{HANDLER_PATH},
        );
        return error.DeleteColumnCallMissing;
    }
    // The count check MUST happen before the delete (the count is the
    // gate; the delete is what we are gating).
    if (count_call_idx.? > delete_call_idx.?) {
        std.debug.print(
            "\n!! {s} calls deleteColumn(...) BEFORE countTasksInColumn(...) !!\n" ++
                "   The pre-delete gate must run first — otherwise we delete and\n" ++
                "   then check, which is the bug we're trying to prevent.\n",
            .{HANDLER_PATH},
        );
        return error.CountCheckOrderWrong;
    }
}

test "kanban_columns_delete handler returns 409 when column has tasks" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    // The validation branch must produce a 409 Conflict (REST
    // convention for "request conflicts with the current resource
    // state"). 400 would be wrong (the request itself is valid — the
    // column exists); 500 would be wrong (not an internal error).
    if (std.mem.indexOf(u8, source, ".status_code = 409") == null) {
        std.debug.print(
            "\n!! {s} does not return 409 when the column has tasks !!\n" ++
                "   The conflict contract is broken: a column with assigned tasks\n" ++
                "   must be refused with HTTP 409 Conflict so the frontend can show\n" ++
                "   'move the tasks first' and re-attempt.\n",
            .{HANDLER_PATH},
        );
        return error.Status409Missing;
    }
}

test "kanban_columns_delete handler 409 message mentions task count" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    // The 409 message must surface the task count so the frontend
    // can render "this column has N tasks — move them first" instead
    // of a generic "cannot delete". The contract is satisfied by any
    // `allocPrint`-style format string that interpolates the count
    // (e.g. `{d} task`).
    if (std.mem.indexOf(u8, source, "Cannot delete column") == null) {
        std.debug.print(
            "\n!! {s} 409 message does not say 'Cannot delete column' !!\n" ++
                "   The user-facing message must start with 'Cannot delete column'\n" ++
                "   so the frontend's notification renderer can match on it.\n",
            .{HANDLER_PATH},
        );
        return error.ErrorMessageMissing;
    }
    // Must interpolate the count into the message. We accept either
    // a `{d}` (number) or `{s}` (pre-formatted) format spec on the
    // same line as the message.
    if (std.mem.indexOf(u8, source, "{d} task") == null and
        std.mem.indexOf(u8, source, "{s} task") == null)
    {
        std.debug.print(
            "\n!! {s} 409 message does not include the task count !!\n" ++
                "   The user-facing message must interpolate the count (e.g.\n" ++
                "   `\"Cannot delete column: {{d}} task{{s}} still assigned...\"`).\n",
            .{HANDLER_PATH},
        );
        return error.TaskCountNotInMessage;
    }
}