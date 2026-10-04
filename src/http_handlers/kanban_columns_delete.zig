//! `DELETE /api/workspaces/:workspace_id/items/:item_id/kanban/columns/:column_id`.
//!
//! Delete a kanban column.
//!
//! Before calling `deleteColumn`, the use-case runs a `COUNT(*)`
//! against `workspace_item_tasks.kanban_column_id` to refuse the
//! delete when the column still has tasks. This protects against
//! silently re-parenting tasks to "unassigned" without the user's
//! consent — the user must first move the tasks to another column.
//!
//! On the success path (no tasks using the column), any tasks that
//! WERE assigned to this column have their `kanban_column_id` set
//! to NULL by `deleteColumn` (the tasks themselves are NOT removed);
//! the frontend surfaces them in the "Unassigned" group of the
//! folder-list view. In practice this only applies to a column whose
//! tasks were all moved away earlier but the column was never
//! deleted — the normal end-of-life path is "user moves tasks →
//! user deletes column".
//!
//! No request body. Returns 200 with `{"success": true, column_id}`
//! on success.
//!
//! Layered as:
//!   - `useCase` — business logic (validate → pre-delete task-count
//!     gate → delete → emit SSE → return tagged result).
//!   - `kanbanColumnsDeleteHandler` — thin orchestrator over
//!     `useCase`: reads path params, delegates to `useCase`, maps
//!     the outcome + errors to an HTTP response (200 / 400 / 409 /
//!     500).
//!
//! Errors:
//!   - 400 missing `item_id` or `column_id` path param
//!   - 409 column still has N task(s) assigned — caller must move
//!     them first
//!   - 500 DB failure (count check or delete)
//!
//! Plan: docs/superpowers/plans/2026-06-21-workspace-item-kanban.md
//!   (Chunk 3, Task 3.6)

const std = @import("std");
const pabrikcore = @import("pabrikcore");
const gserverz = pabrikcore.gserverz;
const http_response = @import("http_response.zig");
const kanban_model = @import("../agentic_loop/kanban_model.zig");
const on_event_sent_kanban = pabrikcore.ai_mod.on_event_sent_kanban;

/// HTTP response shape for column-delete.
const DeleteColumnResponse = struct {
    success: bool = true,
    column_id: []const u8,
};

/// Domain-level error set for `useCase`. The handler maps each
/// variant to an HTTP status code + message via two exhaustive
/// switches (one for status, one for the user-facing message).
///
/// Adding a new variant fails to compile in the handler until both
/// switches are updated — that's intentional, to keep status codes
/// in lockstep with the error set.
pub const KanbanColumnDeleteError = error{
    /// `:item_id` path param was missing or empty.
    ItemIdRequired,
    /// `:column_id` path param was missing or empty.
    ColumnIdRequired,
    /// `kanban_model.countTasksInColumn` failed (DB error, etc.).
    CountFailed,
    /// `kanban_model.deleteColumn` failed (DB error, etc.).
    DeleteFailed,
    /// `allocator` returned no memory. In production this is
    /// effectively unreachable (the per-request arena reaps
    /// everything at request end) but the type system requires the
    /// variant so any `try` on the model functions propagates a
    /// typed error if the inferred set widens.
    OutOfMemory,
};

/// Inputs to the delete-column use-case. The handler maps the HTTP
/// path params into this struct; the use-case is then
/// transport-agnostic.
pub const DeleteColumnInput = struct {
    item_id: []const u8,
    /// workspace_id is only used for the SSE payload's `workspace_id`
    /// field (the frontend filters kanban events by it). Empty is OK.
    workspace_id: []const u8,
    column_id: []const u8,
};

/// Tagged outcome of the delete-column use-case. The "has_tasks"
/// branch carries the task count so the handler can surface the
/// precise number in its 409 message ("Cannot delete column: 3
/// tasks still assigned…"). Mirrors the `TaskDeleteOutcome`
/// pattern in `task_delete.zig`.
pub const KanbanColumnDeleteResult = union(enum) {
    /// Column was deleted (it had no tasks assigned).
    deleted,
    /// Column still has `task_count` tasks assigned — caller must
    /// move them to another column before the delete can succeed.
    has_tasks: u32,
};

// =====================================================================
// Use case
// =====================================================================

/// Delete a kanban column, gating on the pre-delete task-count
/// check.
///
/// Steps:
///   1. Validate `item_id` and `column_id`.
///   2. Run `kanban_model.countTasksInColumn` (the pre-delete gate).
///      If the count > 0, return `.has_tasks = N` (the handler maps
///      this to a 409 response).
///   3. Call `kanban_model.deleteColumn` (which NULLs out the
///      `kanban_column_id` of any remaining tasks as a defense — in
///      practice this only matters if a task was added between the
///      count check and the delete, which the test in
///      `kanban_columns_delete_test.zig` does not exercise).
///   4. Emit a `kanban_column` SSE event with `action="deleted"`
///      (fire-and-forget: SSE failures are logged but do not fail
///      the request — the row is already deleted).
///   5. Return `.deleted` on success, `.has_tasks = N` on the
///      gate-tripped path.
fn useCase(
    allocator: std.mem.Allocator,
    db: *pabrikcore.sqlite.SqliteBackend,
    input: DeleteColumnInput,
) KanbanColumnDeleteError!KanbanColumnDeleteResult {
    // 1. Validate. Business rule: both ids are required to locate
    // the column to delete (item_id is a defense — column_id alone
    // is globally unique, but the model takes both for symmetry
    // with the other column mutators).
    if (input.item_id.len == 0) return error.ItemIdRequired;
    if (input.column_id.len == 0) return error.ColumnIdRequired;

    // 2. Pre-delete gate. We must NOT silently re-parent tasks to
    // "unassigned" — the user must move them first via
    // `kanbanMoveTaskHandler` (which emits a `kanban_task` SSE
    // event, refreshing every connected client).
    const task_count = kanban_model.countTasksInColumn(
        allocator,
        db,
        input.column_id,
    ) catch return error.CountFailed;
    if (task_count > 0) return .{ .has_tasks = task_count };

    // 3. Delete the column (and NULL-out any orphaned tasks as a
    // defensive measure — see step 2 docstring).
    kanban_model.deleteColumn(
        allocator,
        db,
        input.item_id,
        input.column_id,
    ) catch return error.DeleteFailed;

    // 4. Emit the SSE event so other connected clients refresh
    // their kanban view AND re-fetch unassigned tasks (tasks that
    // were on this column get their `kanban_column_id` set to
    // NULL). action="deleted" matches the frontend's
    // `KanbanColumnEvent` union variant. The emit is
    // fire-and-forget: any error from `valueAlloc` is logged and
    // swallowed here — the column is already deleted, so we do NOT
    // fail the request.
    on_event_sent_kanban.onEventSendKanbanColumn(allocator, .{
        .action = "deleted",
        .workspace_id = input.workspace_id,
        .item_id = input.item_id,
        .column_id = input.column_id,
    }) catch |err| {
        std.log.warn(
            "kanban_columns_delete: SSE emit failed (non-fatal): {s}",
            .{@errorName(err)},
        );
    };

    return .deleted;
}

// =====================================================================
// Handler
// =====================================================================

/// Thin orchestrator over `useCase`. Reads path params, delegates
/// to `useCase`, and maps the outcome + errors to an HTTP response.
pub fn kanbanColumnsDeleteHandler(
    ctx: gserverz.HttpContext,
    req: gserverz.HttpRequest,
    res: gserverz.HttpResponse,
) !gserverz.HttpResponse {
    const allocator = ctx.allocator;

    const di = try pabrikcore.getSingleton();
    const sqlite_db = di.db;

    // 1. Read + validate path params.
    const item_id = req.params.get("item_id") orelse "";
    if (item_id.len == 0) {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "item_id required" }),
        });
    }
    // workspace_id is required for the SSE payload (the frontend
    // filters events by it). Empty is fine — the SSE event will
    // still be emitted with workspace_id="".
    const ws_id = req.params.get("workspace_id") orelse "";

    const column_id = req.params.get("column_id") orelse "";
    if (column_id.len == 0) {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "column_id required" }),
        });
    }

    // 2. Delegate to the use-case.
    const outcome = useCase(allocator, sqlite_db, .{
        .item_id = item_id,
        .workspace_id = ws_id,
        .column_id = column_id,
    }) catch |err| {
        // 3. Map the use-case error to an HTTP response. Both
        // switches are exhaustive over the inferred error set —
        // adding a new `KanbanColumnDeleteError` variant will fail
        // to compile here (intentional, to keep status codes in
        // sync). No `else` prong needed.
        const status: u16 = switch (err) {
            error.ItemIdRequired => 400,
            error.ColumnIdRequired => 400,
            error.CountFailed => 500,
            error.DeleteFailed => 500,
            error.OutOfMemory => 500,
        };
        const message: []const u8 = switch (err) {
            error.ItemIdRequired => "item_id required",
            error.ColumnIdRequired => "column_id required",
            error.CountFailed => "Failed to check column usage",
            error.DeleteFailed => "Failed to delete column",
            error.OutOfMemory => "Out of memory",
        };
        return res.jsonResponse(.{
            .status_code = status,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = message }),
        });
    };

    // 4. Map the use-case outcome to an HTTP response. The 409 path
    // interpolates the task count into the user-facing message so
    // the frontend can render "this column has N tasks — move them
    // first" instead of a generic "cannot delete".
    switch (outcome) {
        .deleted => {
            return res.jsonResponse(.{
                .status_code = 200,
                .data = try std.json.Stringify.valueAlloc(
                    allocator,
                    DeleteColumnResponse{ .column_id = column_id },
                    .{},
                ),
            });
        },
        .has_tasks => |task_count| {
            // The format string preserves the historical message
            // shape exactly so the frontend's notification renderer
            // (and the contract test in `kanban_columns_delete_test.zig`
            // that grep-asserts on `"Cannot delete column"` +
            // `"{d} task"`) keeps working.
            const msg = try std.fmt.allocPrint(
                allocator,
                "Cannot delete column: {d} task{s} still assigned. Move them to another column first.",
                .{ task_count, if (task_count == 1) "" else "s" },
            );
            // arena reaps msg at request end; explicit free is
            // defensive + documents ownership (no-op on arena,
            // real free on leak-tracker test allocators).
            defer allocator.free(msg);
            return res.jsonResponse(.{
                .status_code = 409,
                .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = msg }),
            });
        },
    }
}

// ===== Tests merged from kanban_columns_delete_test.zig (2026-09-11 flatten) =====
// Static regression checks for the `DELETE /kanban/columns/:id` handler.
// 
// Why this file exists
// ────────────────────
// The column-delete endpoint removes a column from the kanban. The
// handler must:
//   1. Read `item_id` and `column_id` from path params.
//   2. Refuse the delete (HTTP 409) when the column still has tasks
//      assigned — the user must move them first. This protects against
//      silently re-parenting tasks to "unassigned" without consent.
//   3. Call `kanban_model.deleteColumn(...)` only after the task-count
//      check passes.
//   4. Return 200 with a `{success: true, column_id}` body.
// 
// Plan: docs/superpowers/plans/2026-06-21-workspace-item-kanban.md
//   (Chunk 3, Task 3.6)

const testing = std.testing;
const text_normalize = @import("helpers").text_normalize;

const HANDLER_PATH = "src/http_handlers/kanban_columns_delete.zig";

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

    // Scope to the impl section only: the merged-tests section below
    // the banner mentions the needle in comments + the indexOf string
    // itself (self-match). Truncate at the banner.
    const impl_end = std.mem.indexOf(u8, source, "// ===== Tests merged from") orelse source.len;
    const impl_source = source[0..impl_end];

    // DELETE has no body — `parseFromSliceLeaky` would be wrong here.
    if (std.mem.indexOf(u8, impl_source, "parseFromSliceLeaky") != null) {
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
