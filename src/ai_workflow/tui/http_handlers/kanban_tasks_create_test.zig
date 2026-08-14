//! Static regression checks for the
//! `POST /api/workspaces/:workspace_id/items/:item_id/kanban/tasks` handler.
//!
//! Why this file exists
//! ────────────────────
//! The kanban task-create endpoint is the single wire entry-point for
//! both card creation flows in the frontend KanbanView:
//!
//!   - `mode='create'`         — Add Task dialog: create the task, auto-
//!                               assign to the first kanban column, emit
//!                               `kanban_task` SSE (action='assigned').
//!                               Response carries `session: null`.
//!
//!   - `mode='create_and_run'` — Add Task + Run dialog: same as above
//!                               PLUS insert a `sessions` row keyed by
//!                               task.id (so the sidebar's ChatsList
//!                               gets a new entry immediately), emit
//!                               `session_created` SSE, and return
//!                               `{ task, session: { id, name, status:'send' } }`.
//!
//! The handler must:
//!   1. Parse the body with `parseFromSliceLeaky` (per-request arena).
//!   2. Validate the `mode` field (400 on missing/invalid).
//!   3. Validate that the parent item is a kanban (404 otherwise).
//!   4. For `mode='create_and_run'`: require non-empty `queue_message`
//!      (400 otherwise).
//!   5. For `mode='create'`: NO sessions-row INSERT.
//!   6. For `mode='create_and_run'`: insert a sessions row + emit
//!      `session_created` SSE.
//!   7. Emit a `kanban_task` SSE event regardless of mode.
//!   8. Return 201 on success.
//!
//! These are static-contract tests (no live DB) — they grep the
//! handler's source for the API surfaces the test suite locks in.
//! The same pattern is used by `kanban_columns_create_test.zig`.
//!
//! Plan: docs/superpowers/plans/2026-08-13-kanban-task-create-endpoint.md
//!   (Task 1)

const std = @import("std");
const testing = std.testing;
const nalarcore = @import("nalarcore");
const text_normalize = nalarcore.helpers.text_normalize;

const HANDLER_PATH = "src/ai_workflow/tui/http_handlers/kanban_tasks_create.zig";

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

// =====================================================================
// Common (both modes)
// =====================================================================

test "kanban_tasks_create handler uses parseFromSliceLeaky for body" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    // The handler must use `parseFromSliceLeaky` (per-request arena
    // owns the memory — no explicit deinit needed). Same convention
    // as kanban_columns_create / task_create / etc.
    if (std.mem.indexOf(u8, source, "parseFromSliceLeaky") == null) {
        std.debug.print(
            "\n!! {s} does not use parseFromSliceLeaky !!\n" ++
                "   Switch from `parseFromSlice` to `parseFromSliceLeaky`.\n",
            .{HANDLER_PATH},
        );
        return error.ParseFromSliceLeakyMissing;
    }
}

test "kanban_tasks_create handler validates mode field" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    // The handler must extract the `mode` field from the parsed
    // body (e.g. `parsed.mode`) and dispatch on its value. The two
    // valid values are 'create' and 'create_and_run'.
    if (std.mem.indexOf(u8, source, "parsed.mode") == null) {
        std.debug.print(
            "\n!! {s} does not extract .mode from the parsed body !!\n" ++
                "   The handler must reference `parsed.mode` to dispatch between\n" ++
                "   the 'create' and 'create_and_run' flows.\n",
            .{HANDLER_PATH},
        );
        return error.ModeExtractionMissing;
    }
}

test "kanban_tasks_create handler rejects non-kanban items with 404" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    // The handler must SELECT against `workspace_items` checking
    // `item_type='kanban'` and return 404 if the row is missing.
    // Both the SELECT clause and the 404 status must be present.
    if (std.mem.indexOf(u8, source, "item_type = 'kanban'") == null) {
        std.debug.print(
            "\n!! {s} does not check parent item_type='kanban' !!\n" ++
                "   The handler must verify the parent workspace_item is a kanban\n" ++
                "   before delegating to the task-create use-case.\n",
            .{HANDLER_PATH},
        );
        return error.KanbanTypeCheckMissing;
    }
    if (std.mem.indexOf(u8, source, ".status_code = 404") == null) {
        std.debug.print(
            "\n!! {s} does not return 404 on non-kanban parent !!\n" ++
                "   Add a `.status_code = 404` branch for the parent-is-not-kanban\n" ++
                "   case (matches the 404 contract for other kanban sub-resources).\n",
            .{HANDLER_PATH},
        );
        return error.NotFoundStatusMissing;
    }
}

test "kanban_tasks_create handler returns 201 on success" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    // POST that creates a resource → 201 Created. Same contract as
    // task_create.zig and kanban_columns_create.zig.
    if (std.mem.indexOf(u8, source, ".status_code = 201") == null) {
        std.debug.print(
            "\n!! {s} does not return a 201 status code !!\n" ++
                "   Use `.status_code = 201` on the success branch.\n",
            .{HANDLER_PATH},
        );
        return error.Status201Missing;
    }
}

// =====================================================================
// Mode='create' specific
// =====================================================================

test "kanban_tasks_create (mode=create) does NOT insert a sessions row" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    // The sessions-row INSERT must be guarded behind a mode check —
    // i.e. ONLY fire when mode='create_and_run'. mode='create' must
    // NOT touch the sessions table.

    // 1. There must be a `mode == "create_and_run"` (or equivalent
    // is_create_and_run) branch that gates the INSERT.
    const has_create_and_run_branch = std.mem.indexOf(u8, source, "create_and_run") != null;
    if (!has_create_and_run_branch) {
        std.debug.print(
            "\n!! {s} has no `create_and_run` branch !!\n" ++
                "   The sessions-row INSERT must be gated on mode='create_and_run'.\n",
            .{HANDLER_PATH},
        );
        return error.CreateAndRunBranchMissing;
    }

    // 2. The `INSERT [OR IGNORE] INTO sessions` line must be guarded
    // by an `is_create_and_run` (or `mode == "create_and_run"`)
    // predicate earlier in the function. We accept either bare
    // `INSERT INTO sessions` or `INSERT OR IGNORE INTO sessions`
    // (the OR IGNORE form is the safety pattern used by
    // session_create.zig — defense in depth against a concurrent
    // insert). We check that the INSERT appears AFTER the gate by
    // looking for the gate text before the INSERT in the source
    // order (coarse but adequate structural check).
    const insert_pos = blk: {
        if (std.mem.indexOf(u8, source, "INSERT INTO sessions")) |p| break :blk p;
        if (std.mem.indexOf(u8, source, "INSERT OR IGNORE INTO sessions")) |p| break :blk p;
        std.debug.print(
            "\n!! {s} does not have an INSERT INTO sessions at all !!\n" ++
                "   The mode='create_and_run' path needs to insert a sessions row.\n",
            .{HANDLER_PATH},
        );
        return error.SessionsInsertMissing;
    };
    const gate_pos = std.mem.indexOf(u8, source, "is_create_and_run") orelse {
        std.debug.print(
            "\n!! {s} has no `is_create_and_run` gate variable !!\n" ++
                "   Define `const is_create_and_run = std.mem.eql(...)` and guard\n" ++
                "   the INSERT/emit with `if (is_create_and_run) {{ ... }}`.\n",
            .{HANDLER_PATH},
        );
        return error.IsCreateAndRunGateMissing;
    };
    if (gate_pos > insert_pos) {
        std.debug.print(
            "\n!! {s} uses `INSERT INTO sessions` BEFORE the `is_create_and_run` gate !!\n" ++
                "   The sessions INSERT must be GUARDED by an `if (is_create_and_run)`\n" ++
                "   block — mode='create' must NOT insert a sessions row.\n",
            .{HANDLER_PATH},
        );
        return error.SessionsInsertUnguarded;
    }
}

test "kanban_tasks_create (mode=create) does NOT call emit_run_agent" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    // The handler is a thin orchestrator over task_create.zig's
    // useCase; the actual agent run is kicked off elsewhere (the
    // `session_created` SSE is consumed by the agentic_loop, which
    // picks up the new session and starts the worker). The handler
    // MUST NOT call any `emit_run_agent` helper itself — that's the
    // scheduler's job. This test asserts the symbol is absent (so a
    // future regression that wires a direct emit is caught).
    if (std.mem.indexOf(u8, source, "emit_run_agent") != null) {
        std.debug.print(
            "\n!! {s} references `emit_run_agent` — that is the scheduler's job !!\n" ++
                "   The handler must NOT directly kick off an agent run. The\n" ++
                "   `session_created` SSE event is consumed by the agentic_loop\n" ++
                "   which picks up the new session and starts the worker.\n",
            .{HANDLER_PATH},
        );
        return error.EmitRunAgentShouldNotBeCalled;
    }
}

// =====================================================================
// Mode='create_and_run' specific
// =====================================================================

test "kanban_tasks_create (mode=create_and_run) calls onEventSendSessions" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    // The create_and_run path must emit a `session_created` SSE so
    // the frontend sidebar updates without a refetch. The backend
    // helper is `onEventSendSessions` (from on_event_sent.zig).
    if (std.mem.indexOf(u8, source, "onEventSendSessions") == null) {
        std.debug.print(
            "\n!! {s} does not call onEventSendSessions !!\n" ++
                "   The create_and_run path must emit a session SSE event\n" ++
                "   (action='created') so the sidebar's ChatsList updates.\n",
            .{HANDLER_PATH},
        );
        return error.OnEventSendSessionsMissing;
    }

    // Sanity check: the call must use action='created' (matches the
    // frontend's sessionCreated handler in api/index.ts).
    if (std.mem.indexOf(u8, source, ".action = \"created\"") == null) {
        std.debug.print(
            "\n!! {s} does not pass `.action = \"created\"` to onEventSendSessions !!\n" ++
                "   The frontend pre-registers `session_created` and `session_updated`\n" ++
                "   event names — the create-and-run path must use action='created'.\n",
            .{HANDLER_PATH},
        );
        return error.SessionActionCreatedMissing;
    }
}

test "kanban_tasks_create (mode=create_and_run) rejects empty queue_message with 400" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    // The create_and_run path requires a non-empty queue_message
    // (otherwise there's nothing to send to the worker). The
    // validation must return 400 on empty/null queue_message.
    if (std.mem.indexOf(u8, source, "queue_message") == null) {
        std.debug.print(
            "\n!! {s} does not reference `queue_message` at all !!\n" ++
                "   The create_and_run path requires a queue_message field.\n",
            .{HANDLER_PATH},
        );
        return error.QueueMessageFieldMissing;
    }
    // The 400 status code must appear at least once — there are
    // several 400 paths (mode missing, mode invalid, queue_message
    // empty). We assert the count is >= 3 (the three required).
    var occurrences: usize = 0;
    var idx: usize = 0;
    while (std.mem.findPos(u8, source, idx, ".status_code = 400")) |pos| {
        occurrences += 1;
        idx = pos + 1;
    }
    if (occurrences < 3) {
        std.debug.print(
            "\n!! {s} has only {d} `.status_code = 400` branches — expected >= 3 !!\n" ++
                "   Required 400 branches: (1) item_id missing, (2) mode missing/invalid,\n" ++
                "   (3) queue_message empty when mode='create_and_run'.\n",
            .{ HANDLER_PATH, occurrences },
        );
        return error.TooFew400Branches;
    }
}

// =====================================================================
// SSE
// =====================================================================

test "kanban_tasks_create handler emits kanban_task SSE" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    // The kanban_task SSE event is what tells the frontend KanbanView
    // that a new card appeared in a column. Without it the new card
    // only shows after a manual page refresh.
    //
    // The handler delegates the task-row INSERT + auto-assign +
    // kanban_task SSE emit to `task_create.zig::useCase` (which calls
    // `onEventSendKanbanTask` from `on_event_sent_kanban.zig` inside
    // `createStandardTask`). Either pattern satisfies the contract:
    //   1. Direct emit: `onEventSendKanbanTask(...)` appears in source.
    //   2. Delegated emit: `task_create.zig`'s `useCase` is invoked,
    //      which transitively emits the SSE.
    const has_direct_emit = std.mem.indexOf(u8, source, "onEventSendKanbanTask") != null;
    const delegates_to_task_create = std.mem.indexOf(u8, source, "task_create.zig") != null and
        std.mem.indexOf(u8, source, ".useCase(") != null;
    if (!has_direct_emit and !delegates_to_task_create) {
        std.debug.print(
            "\n!! {s} does not emit kanban_task SSE !!\n" ++
                "   Either call `onEventSendKanbanTask(...)` directly OR delegate to\n" ++
                "   `task_create.zig::useCase` (which emits it transitively via\n" ++
                "   `createStandardTask`).\n",
            .{HANDLER_PATH},
        );
        return error.OnEventSendKanbanTaskMissing;
    }
}
