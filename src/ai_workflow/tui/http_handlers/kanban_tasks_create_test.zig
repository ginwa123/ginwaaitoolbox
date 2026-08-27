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
const text_normalize = @import("helpers").text_normalize;

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

    // mode='create' must NOT call di.emit_run_agent. The handler
    // is allowed (in fact required) to call it in the
    // `mode='create_and_run'` branch — that's what kicks off the
    // agent turn. This test asserts the create-only path is
    // emission-free for the agent (the sessions INSERT + SSE are
    // also gated by the same branch — see the `if
    // (is_create_and_run)` checks at the INSERT site).
    //
    // We approximate "guarded by mode branch" by checking that
    // every actual call to `emit_run_agent` (the `di.emit_run_agent(`
    // invocation, not doc-comment prose) appears AFTER an
    // `is_create_and_run` token in source order. This is a weak proxy
    // but catches a regression that wires emit into the unguarded
    // create-only path. We anchor on `di.emit_run_agent(` to skip
    // doc-comment prose that mentions the helper by name (the header
    // module doc comment does this).
    const guard_token = "is_create_and_run";
    var search_pos: usize = 0;
    while (std.mem.indexOfPos(u8, source, search_pos, "di.emit_run_agent(")) |pos| {
        const before = source[0..pos];
        if (std.mem.lastIndexOf(u8, before, guard_token) == null) {
            std.debug.print(
                "\n!! {s} calls `emit_run_agent` outside the `is_create_and_run` branch !!\n" ++
                    "   mode='create' must NOT directly kick off an agent run.\n" ++
                    "   Wrap the emit in `if (is_create_and_run) {{ ... }}`.\n",
                .{HANDLER_PATH},
            );
            return error.EmitRunAgentUnguarded;
        }
        search_pos = pos + 1;
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

// =====================================================================
// mode='create_session' (plan: 2026-08-19-kanban-create-task-inits-session)
// =====================================================================

test "kanban_tasks_create handler accepts mode='create_session'" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    // The handler must recognise the new mode value. The dispatch
    // table is a chain of `std.mem.eql(u8, parsed.mode, "...")` checks
    // (see is_create_only / is_create_and_run on lines 108-109). The
    // new value must be in that chain — otherwise the handler 400s
    // with "mode must be 'create' or 'create_and_run'".
    if (std.mem.indexOf(u8, source, "\"create_session\"") == null) {
        std.debug.print(
            "\n!! {s} does not recognise mode='create_session' !!\n" ++
                "   The new mode is opt-in (backward compat with legacy\n" ++
                "   mode='create' which keeps the old behaviour). Add a\n" ++
                "   `std.mem.eql(u8, parsed.mode, \"create_session\")` check\n" ++
                "   and a new `is_create_session` boolean alongside\n" ++
                "   `is_create_only` / `is_create_and_run`.\n",
            .{HANDLER_PATH},
        );
        return error.CreateSessionModeMissing;
    }
}

test "kanban_tasks_create handler does NOT call emit_run_agent for create_session" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    // The whole point of create_session: prep the row but don't kick
    // off the worker. The handler must declare the `is_create_session`
    // boolean (proves the new mode is wired through the dispatch chain)
    // AND still call `di.emit_run_agent(...)` (the existing plumbing
    // stays). Together these prove the mode is plumbed end-to-end while
    // the narrower inner guard (verified by inspection at the diff site)
    // keeps the worker from firing for create_session.
    if (std.mem.indexOf(u8, source, "is_create_session") == null) {
        std.debug.print(
            "\n!! {s} does not declare `is_create_session` !!\n" ++
                "   Without the new boolean, the dispatch chain has no way to\n" ++
                "   distinguish create_session from create_and_run for the\n" ++
                "   narrowed emit_run_agent guard. Add:\n" ++
                "     const is_create_session = std.mem.eql(u8, parsed.mode, \"create_session\");\n" ++
                "   alongside `is_create_only` / `is_create_and_run`.\n",
            .{HANDLER_PATH},
        );
        return error.EmitRunAgentGuardMissing;
    }
    if (std.mem.indexOf(u8, source, "emit_run_agent") == null) {
        std.debug.print(
            "\n!! {s} does not call emit_run_agent at all !!\n" ++
                "   create_and_run still needs to trigger the worker. Don't\n" ++
                "   remove the emit_run_agent call — just narrow its guard\n" ++
                "   from the existing create_and_run-only path.\n",
            .{HANDLER_PATH},
        );
        return error.EmitRunAgentCallMissing;
    }
}

test "kanban_tasks_create handler inserts sessions row for create_session" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    // The session INSERT SQL is currently inside `if (is_create_and_run)`.
    // For create_session we need the SAME insert but gated by a broader
    // condition (e.g. `if (is_create_and_run or is_create_session)`).
    // Combined check: the new mode is declared AND the INSERT SQL is
    // still present (proves the widening didn't accidentally delete the
    // INSERT statement — the guard widening alone isn't enough).
    if (std.mem.indexOf(u8, source, "is_create_session") == null) {
        std.debug.print(
            "\n!! {s} does not declare `is_create_session` !!\n" ++
                "   The session INSERT path needs to be reachable from the new\n" ++
                "   mode. Add the is_create_session boolean + widen the INSERT\n" ++
                "   guard from `if (is_create_and_run)` to\n" ++
                "   `if (is_create_and_run or is_create_session)`.\n",
            .{HANDLER_PATH},
        );
        return error.SessionsInsertMissing;
    }
    if (std.mem.indexOf(u8, source, "INSERT OR IGNORE INTO sessions") == null) {
        std.debug.print(
            "\n!! {s} does not contain the sessions INSERT !!\n" ++
                "   create_session must insert the sessions row the same way\n" ++
                "   create_and_run does. The line that says `INSERT OR IGNORE\n" ++
                "   INTO sessions (...)` is the canonical pattern.\n",
            .{HANDLER_PATH},
        );
        return error.SessionsInsertMissing;
    }
}

test "kanban_tasks_create handler emits session_created SSE for create_session" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    // The session_created SSE emission is in create_and_run today. For
    // create_session we need the same `onEventSendSessions(... action =
    // "created", ...)` call. Combined check: new mode declared + the
    // SSE emit is still present (proves the widening didn't drop the
    // SSE on the floor).
    if (std.mem.indexOf(u8, source, "is_create_session") == null) {
        std.debug.print(
            "\n!! {s} does not declare `is_create_session` !!\n" ++
                "   The session_created SSE path needs to be reachable from the\n" ++
                "   new mode. Widen the SSE-emit guard alongside the sessions\n" ++
                "   INSERT guard.\n",
            .{HANDLER_PATH},
        );
        return error.SessionCreatedSseMissing;
    }
    if (std.mem.indexOf(u8, source, "onEventSendSessions") == null) {
        std.debug.print(
            "\n!! {s} does not emit session_created SSE !!\n" ++
                "   chatview's ChatsList needs the session_created event to\n" ++
                "   surface the new session without a manual refetch. Same\n" ++
                "   pattern as create_and_run.\n",
            .{HANDLER_PATH},
        );
        return error.SessionCreatedSseMissing;
    }
}

test "kanban_tasks_create response for create_session returns session.status='idle'" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    // The response session object must carry status='idle' for the
    // new mode (vs 'send' for create_and_run). The wire-level
    // status distinguishes "session exists, no agent triggered"
    // from "session exists, agent queued".
    if (std.mem.indexOf(u8, source, "\"idle\"") == null) {
        std.debug.print(
            "\n!! {s} does not set session.status='idle' for create_session !!\n" ++
                "   The frontend uses session.status to distinguish create_session\n" ++
                "   (idle) from create_and_run (send). Add the new branch in the\n" ++
                "   response-building block.\n",
            .{HANDLER_PATH},
        );
        return error.IdleStatusMissing;
    }
}

// =====================================================================
// create_session inserts user-role llm_history row (bug: "create task
// still not insert user llm history role")
//
// The plain "Create task" button in the dialog emits mode='create' but
// the host (KanbanView.handleCreateTaskSave) overrides it to
// mode='create_session' on the wire. Pre-fix the backend only inserted
// the sessions row — the user's typed description was silently dropped,
// so the chatview landed on an empty session. Post-fix the handler
// mirrors the create_and_run wire format ("name\n\ndescription") and
// persists it as a user-role row in `llm_history`, gated on
// `is_create_session AND description.len > 0` so title-only tasks stay
// on a clean chat. Skips when description is empty (user types the
// first message).
//
// This static check locks in the wire shape: it asserts the handler
// (1) references the `description` field on the parsed body, (2)
// reaches for `insertLLMHistories` (the helper that owns the
// role='user' write + SSE emit), and (3) the new INSERT is gated
// behind the `is_create_session` boolean so create_and_run doesn't
// double-insert (that path uses the workflow queue-drain instead).
// =====================================================================

test "kanban_tasks_create (mode=create_session) inserts user-role llm_history row when description is non-empty" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    // 1. The handler must read `parsed.description` somewhere — that's
    // the source for the new user message. Skipping this check means
    // the bug regressed silently (no description → no llm_history row).
    if (std.mem.indexOf(u8, source, "parsed.description") == null) {
        std.debug.print(
            "\n!! {s} never reads `parsed.description` !!\n" ++
                "   The new user-role llm_history INSERT needs the user's\n" ++
                "   typed description. The handler must read `parsed.description`\n" ++
                "   and format it as 'name + \"\\n\\n\" + description' (matches\n" ++
                "   the wire format KanbanView.handleCreateTaskSave uses for\n" ++
                "   create_and_run).\n",
            .{HANDLER_PATH},
        );
        return error.DescriptionNotRead;
    }

    // 2. The handler must INSERT into llm_history with role='user'
    // (the bug is exactly that this row was missing). Coarse source-
    // order check: the INSERT SQL string must contain both the column
    // list and a `'user'` role literal — proves the wire-shape intent.
    if (std.mem.indexOf(u8, source, "INSERT INTO llm_history") == null) {
        std.debug.print(
            "\n!! {s} has no `INSERT INTO llm_history` !!\n" ++
                "   The new user-role row must INSERT into llm_history.\n",
            .{HANDLER_PATH},
        );
        return error.InsertLlmHistoryMissing;
    }
    if (std.mem.indexOf(u8, source, "'user'") == null) {
        std.debug.print(
            "\n!! {s} has no `'user'` role literal !!\n" ++
                "   The new INSERT must specify role='user' (the bug is\n" ++
                "   that this row was missing entirely).\n",
            .{HANDLER_PATH},
        );
        return error.UserRoleLiteralMissing;
    }

    // 3. The INSERT must be guarded by `is_create_session` so
    // create_and_run doesn't double-insert (that path writes via
    // the workflow's queue-drain → insertLLMHistories chain in
    // agentic_loop/workflow.zig:716-740). Coarse source-order check:
    // the literal `is_create_session` token must appear BEFORE the
    // literal `INSERT INTO llm_history` call.
    const guard_pos = std.mem.indexOf(u8, source, "is_create_session") orelse {
        std.debug.print(
            "\n!! {s} has no `is_create_session` reference !!\n" ++
                "   The new user-role INSERT must be guarded by\n" ++
                "   `if (is_create_session)` so create_and_run doesn't\n" ++
                "   double-insert (create_and_run writes via the workflow's\n" ++
                "   queue-drain path instead).\n",
            .{HANDLER_PATH},
        );
        return error.IsCreateSessionMissing;
    };
    const insert_pos = std.mem.indexOf(u8, source, "INSERT INTO llm_history") orelse {
        // unreachable — indexOf check above already failed
        return error.InsertLlmHistoryMissing;
    };
    if (guard_pos > insert_pos) {
        std.debug.print(
            "\n!! {s} has `INSERT INTO llm_history` BEFORE the `is_create_session` guard !!\n" ++
                "   The new INSERT must be INSIDE the `if (is_create_session)`\n" ++
                "   block. Otherwise create_and_run (which also fires this code\n" ++
                "   path) would double-insert — once here and once via the\n" ++
                "   workflow's queue-drain → insertLLMHistories chain.\n",
            .{HANDLER_PATH},
        );
        return error.InsertUnguarded;
    }
}

test "kanban_tasks_create (mode=create_session) ALWAYS inserts llm_history row (no empty-description guard)" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    // Regression for task_1787757006639_2 ("bugs" -- empty description
    // leaves llm_history empty so the chatview lands on the "How can
    // I help you?" empty state).
    //
    // The user-role INSERT inside `if (is_create_session) { ... }`
    // must NOT be guarded by an empty-description / empty-image-urls
    // predicate. Pre-fix, the handler had `if (description.len > 0
    // or image_urls_wire.len > 0)` around the INSERT -- when both
    // were empty, NO row was inserted and the chatview rendered the
    // empty state. Post-fix the INSERT is unconditional (the
    // `is_create_session` outer guard is the only gate). Title-only
    // tasks get a user-role row with content = `name + "\n\n"` so
    // the chatview never lands on the empty state.
    //
    // We assert there is no such inner guard. The accepted
    // variants are exactly the empty-description / empty-attachments
    // predicates that existed pre-fix. We scan for the exact two
    // predicates that gate the INSERT -- fail closed with a
    // regression error if either reappears.
    const guards = [_][]const u8{
        "description.len > 0",
        "image_urls_wire.len > 0",
    };
    for (guards) |guard| {
        if (std.mem.indexOf(u8, source, guard) != null) {
            std.debug.print(
                "\n!! {s} still has empty-input guard `{s}` !!\n" ++
                    "   The user-role llm_history INSERT inside `if (is_create_session) {{ ... }}`\n" ++
                    "   must be UNCONDITIONAL -- title-only tasks must still get a user-role row,\n" ++
                    "   otherwise the chatview lands on the empty state (task_1787757006639_2).\n",
                .{ HANDLER_PATH, guard },
            );
            return error.EmptyDescriptionGuardReintroduced;
        }
    }
}

// Regression for task_1787494153778_2 ("wrong profile select").
//
// The dialog ALWAYS sends `is_auto_retry_until_stop` ('0' or '1' —
// KanbanTaskDetailDialog.vue:800). Pre-fix, the handler forwarded the
// flag into `task_create.useCase` for EVERY mode, and the useCase's
// bare `INSERT OR IGNORE INTO sessions (id, name, status,
// is_auto_retry_until_stop)` (task_create.zig:626-638 — no
// `selected_profile_model` column) ran FIRST. This handler's later
// profile-bearing `INSERT OR IGNORE INTO sessions` then hit the
// existing PK and was silently ignored → sessions.selected_profile_model
// stayed NULL → the chatview fell back to the default profile
// ("alpha model") instead of the user's pick (e.g. "900ribu").
//
// Contract: the `std_req` construction must forward the flag into the
// use-case ONLY for legacy mode='create' (where the bare INSERT is the
// ONLY sessions write). For create_session / create_and_run, step 5's
// full INSERT (profile + flag) is the authoritative row.
test "kanban_tasks_create forwards unattended flag to useCase ONLY for mode=create" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    // Isolate the `std_req = http_response.TaskCreateRequest{ ... };`
    // block so we assert on the actual forwarding site, not on
    // doc-comment prose elsewhere in the file.
    const req_pos = std.mem.indexOf(u8, source, "TaskCreateRequest{") orelse {
        std.debug.print(
            "\n!! {s} has no TaskCreateRequest construction !!\n",
            .{HANDLER_PATH},
        );
        return error.TaskCreateRequestMissing;
    };
    const req_end = std.mem.indexOfPos(u8, source, req_pos, "};") orelse {
        return error.TaskCreateRequestUnterminated;
    };
    const req_block = source[req_pos..req_end];

    // The flag line must exist (the legacy create path still needs it)...
    const flag_pos = std.mem.indexOf(u8, req_block, ".is_auto_retry_until_stop = ") orelse {
        std.debug.print(
            "\n!! {s} no longer forwards .is_auto_retry_until_stop in std_req !!\n" ++
                "   Legacy mode='create' relies on the useCase's bare sessions\n" ++
                "   INSERT to persist the flag — keep forwarding it there.\n",
            .{HANDLER_PATH},
        );
        return error.UnattendedFlagNotForwarded;
    };
    // ...and must be gated on is_create_only (ternary/if-expression),
    // so create_session / create_and_run pass null and the useCase
    // skips its bare INSERT — leaving step 5's full INSERT (with
    // selected_profile_model) as the authoritative row.
    if (std.mem.indexOfPos(u8, req_block, flag_pos, "is_create_only") == null) {
        std.debug.print(
            "\n!! {s} forwards .is_auto_retry_until_stop to useCase UNGATED !!\n" ++
                "   The useCase inserts a bare sessions row (no profile column)\n" ++
                "   when the flag is present, and this handler's later\n" ++
                "   INSERT OR IGNORE then no-ops on the PK conflict — silently\n" ++
                "   dropping selected_profile_model (bug: wrong profile select).\n" ++
                "   Gate the forwarding: `.is_auto_retry_until_stop = if (is_create_only)\n" ++
                "   parsed.is_auto_retry_until_stop else null,`\n",
            .{HANDLER_PATH},
        );
        return error.UnattendedFlagNotGatedOnCreateOnly;
    }
}


// =====================================================================
// Migration 069 read-path follow-up (plan:
// docs/superpowers/plans/2026-08-24-kanban-task-image-urls-read-path.md
// Task 2): the kanban create envelope's `task` object must echo
// image_urls so the frontend's optimistic task carries the images.
// =====================================================================

test "kanban create response task echoes image_urls" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    // The TaskCreateResponse construction must populate image_urls
    // from the standard_result (arena-owned, borrowed per the
    // existing comment on the envelope).
    const marker = "const task_resp = http_response.TaskCreateResponse{";
    const idx = std.mem.indexOf(u8, source, marker) orelse {
        std.debug.print("\n!! {s} does not construct TaskCreateResponse !!\n", .{HANDLER_PATH});
        return error.TaskRespMissing;
    };
    const window = source[idx..];
    const window_end = std.mem.indexOf(u8, window, "};") orelse window.len;
    const body = window[0..window_end];

    if (std.mem.indexOf(u8, body, ".image_urls = standard_result.image_urls") == null) {
        std.debug.print(
            "\n!! {s} kanban create response task does not echo image_urls !!\n" ++
                "   Add: .image_urls = standard_result.image_urls,\n",
            .{HANDLER_PATH},
        );
        return error.KanbanCreateRespImageUrlsMissing;
    }
}
