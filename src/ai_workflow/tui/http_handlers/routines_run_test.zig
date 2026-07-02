//! Static regression checks for the routines_run handler.
//!
//! Why this file exists
//! ────────────────────
//! The Add Task Routines feature (plan:
//! `2026-06-13-add-task-routines-chunk-4.md`) introduces
//! `POST /api/workspaces/:w/items/:i/tasks/:tid/run` — a manual-fire
//! endpoint. The handler is a *thin wrapper*: it gets the
//! `nalarcore` singleton, derives `db` and `io` from it, and calls
//! `fire.fireRoutine(allocator, db, di, io, task_id)` directly on the
//! main process's Io group via `di.group_emit_session_create.concurrent`.
//! All actual logic (loading the routine, validating `enabled`,
//! atomic `claimForRun`, scheduling the LLM work via the event bus,
//! updating `next_run_at`) lives in `src/ai_workflow/tui/routines/fire.zig`.
//! The handler's only responsibilities are:
//!
//!   1. Pull the Io group out of the singleton.
//!   2. Call `fire.fireRoutine`.
//!   3. Map the three `FireError` variants to HTTP status codes:
//!        - `FireError.NotARoutine`     → 404
//!        - `FireError.Disabled`        → 409
//!        - `FireError.AlreadyRunning`  → 409
//!   4. Return `200 OK` with `{ "session_id": "<task_id>" }` on success.
//!
//! These contracts are enforced by static substring checks (matching
//! the project's `task_create_routines_test.zig` / `task_update_routines_test.zig`
//! pattern), not by spinning up an in-memory DB. Standing up a sqlite
//! DB + migrations + event bus + `ContextIPCTui` singleton to
//! behavioural-test the handler would duplicate the migration setup
//! and pull in `nalarcore.getSingleton()` (which depends on a live
//! server, logger, and event bus). The static checks below directly
//! test the bug — they fail if and only if the thin-wrapper plumbing
//! is removed or routed back to the pre-PR-#8 sub-process design.
//!
//! **PR #8 architectural note:** the plan's original tests (Tasks 4.6
//! in the Add Task Routines plan) referenced the old sub-process
//! design (`nalar-routine-fire` binary, `--id` flag,
//! `std.process.spawn`, `getWorkspaceItemTask`, `loadRoutineByTaskId`,
//! `.enabled`, `claimForRun`). After the PR #8 refactor the handler
//! is a thin wrapper that does NOT spawn a sub-process and does NOT
//! directly call those low-level helpers — they're all inside
//! `fire.fireRoutine`. The tests below check the *wrapper* contracts
//! (`getSingleton`, `fire.fireRoutine`, error mapping, success
//! payload), and the `fire.zig` contracts are covered by
//! `routines/fire_test.zig`.
//!
//! Plan: docs/superpowers/plans/2026-06-13-add-task-routines-chunk-4.md
//!   (Task 4.6)

const std = @import("std");
const testing = std.testing;
const nalarcore = @import("nalarcore");
const text_normalize = nalarcore.helpers.text_normalize;

const HANDLER_PATH = "src/ai_workflow/tui/http_handlers/routines_run.zig";

/// Read a source file from disk, relative to the project root
/// (which is the cwd when `zig build test:ai_workflow:tui` runs).
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

// ─── Contract 1: handler gets the Io group from the singleton ──────────────

test "routines_run handler gets the singleton for the Io group" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    // The handler must call `nalarcore.getSingleton()` to obtain the
    // initialized `ContextIPCTui` (which carries the Io group via
    // `di.group_emit_session_create`). Without this, the handler has
    // no way to schedule the LLM work on the main process's runtime.
    if (std.mem.indexOf(u8, source, "getSingleton") == null) {
        std.debug.print(
            "\n!! {s} does not call getSingleton() !!\n" ++
                "   The Io-group-acquisition contract is broken: the handler\n" ++
                "   cannot reach `di.group_emit_session_create.concurrent` to\n" ++
                "   schedule the LLM fire on the main process's Io runtime.\n" ++
                "   Add a nalarcore.getSingleton() call and map the error to 500.\n" ++
                "   See docs/superpowers/plans/2026-06-13-add-task-routines-chunk-4.md.\n",
            .{HANDLER_PATH},
        );
        return error.SingletonMissing;
    }
    if (std.mem.indexOf(u8, source, "fireRoutine") == null) {
        std.debug.print(
            "\n!! {s} does not call fire.fireRoutine !!\n" ++
                "   The fire-pipeline contract is broken: the handler is not\n" ++
                "   a thin wrapper around `fire.fireRoutine`. Either the call\n" ++
                "   has been inlined (re-introducing the monolithic pre-PR-#8\n" ++
                "   design) or the call site is missing entirely.\n" ++
                "   Restore `fire.fireRoutine(allocator, sqlite_db, di, io, task_id)`.\n" ++
                "   See docs/superpowers/plans/2026-06-13-add-task-routines-chunk-4.md.\n",
            .{HANDLER_PATH},
        );
        return error.FireRoutineCallMissing;
    }
}

// ─── Contract 2: handler calls fire.fireRoutine with the 5-param signature ─

test "routines_run handler calls fire.fireRoutine with 5 params" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    // The handler must call `fire.fireRoutine` (qualified with the `fire`
    // module) — not a bare `fireRoutine` reference, which would mean
    // the file is a fire.zig duplicate or a different fire helper.
    // The call site must be present in the handler body.
    if (std.mem.indexOf(u8, source, "fire.fireRoutine") == null) {
        std.debug.print(
            "\n!! {s} does not contain a qualified `fire.fireRoutine` call !!\n" ++
                "   The wrapper-shape contract is broken: the handler must\n" ++
                "   delegate to `fire.fireRoutine` from `../routines/fire.zig`.\n" ++
                "   Add `fire.fireRoutine(allocator, sqlite_db, di, io, task_id)`\n" ++
                "   in the handler body. The 5-arg signature is\n" ++
                "   `(allocator, db, di, io, task_id)` — see fire.zig:86.\n" ++
                "   See docs/superpowers/plans/2026-06-13-add-task-routines-chunk-4.md.\n",
            .{HANDLER_PATH},
        );
        return error.FireRoutineQualifiedCallMissing;
    }
}

// ─── Contract 3: NotARoutine maps to 404 ──────────────────────────────────

test "routines_run handler maps FireError.NotARoutine to 404" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    // The handler's catch block must branch on `FireError.NotARoutine`
    // and return 404. The plan-level contract: 404 means "this task is
    // a standard task, not a routine — cannot fire it as one".
    if (std.mem.indexOf(u8, source, "NotARoutine") == null) {
        std.debug.print(
            "\n!! {s} does not reference FireError.NotARoutine !!\n" ++
                "   The 404-contract is broken: a non-routine task POSTed to\n" ++
                "   /run will fall through to the generic 500 instead of\n" ++
                "   producing a clean 404 \"task is not a routine\".\n" ++
                "   Add the NotARoutine branch in the catch-on-fireRoutine.\n" ++
                "   See docs/superpowers/plans/2026-06-13-add-task-routines-chunk-4.md.\n",
            .{HANDLER_PATH},
        );
        return error.NotARoutineMappingMissing;
    }
    if (std.mem.indexOf(u8, source, "404") == null) {
        std.debug.print(
            "\n!! {s} does not return a 404 status code !!\n" ++
                "   The NotARoutine branch must produce `status_code = 404`.\n" ++
                "   Without it, a non-routine task will return 500, which is\n" ++
                "   semantically wrong and breaks the client contract.\n" ++
                "   See docs/superpowers/plans/2026-06-13-add-task-routines-chunk-4.md.\n",
            .{HANDLER_PATH},
        );
        return error.NotARoutineStatusMissing;
    }
}

// ─── Contract 4: Disabled maps to 409 ─────────────────────────────────────

test "routines_run handler maps FireError.Disabled to 409" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    // The handler must branch on `FireError.Disabled` and return 409.
    // 409 = conflict — the routine exists but is currently disabled,
    // so a manual fire is a state conflict (not a not-found, not an
    // internal error).
    if (std.mem.indexOf(u8, source, "Disabled") == null) {
        std.debug.print(
            "\n!! {s} does not reference FireError.Disabled !!\n" ++
                "   The 409-disabled contract is broken: a disabled routine\n" ++
                "   POSTed to /run will fall through to 500 instead of\n" ++
                "   producing a clean 409 \"routine is disabled\".\n" ++
                "   Add the Disabled branch in the catch-on-fireRoutine.\n" ++
                "   See docs/superpowers/plans/2026-06-13-add-task-routines-chunk-4.md.\n",
            .{HANDLER_PATH},
        );
        return error.DisabledMappingMissing;
    }
    if (std.mem.indexOf(u8, source, "409") == null) {
        std.debug.print(
            "\n!! {s} does not return a 409 status code !!\n" ++
                "   The Disabled branch must produce `status_code = 409`.\n" ++
                "   See docs/superpowers/plans/2026-06-13-add-task-routines-chunk-4.md.\n",
            .{HANDLER_PATH},
        );
        return error.DisabledStatusMissing;
    }
}

// ─── Contract 5: AlreadyRunning maps to 409 ───────────────────────────────

test "routines_run handler maps FireError.AlreadyRunning to 409" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    // The handler must branch on `FireError.AlreadyRunning` and return
    // 409. AlreadyRunning is produced by `fire.zig`'s `claimForRun` —
    // a previous fire is still in flight (`last_status = 'running'`).
    // The plan-level contract: a second concurrent manual fire on the
    // same routine is a state conflict.
    if (std.mem.indexOf(u8, source, "AlreadyRunning") == null) {
        std.debug.print(
            "\n!! {s} does not reference FireError.AlreadyRunning !!\n" ++
                "   The 409-already-running contract is broken: a second\n" ++
                "   concurrent fire on the same routine will fall through\n" ++
                "   to 500 instead of producing 409 \"routine is already running\".\n" ++
                "   Add the AlreadyRunning branch in the catch-on-fireRoutine.\n" ++
                "   See docs/superpowers/plans/2026-06-13-add-task-routines-chunk-4.md.\n",
            .{HANDLER_PATH},
        );
        return error.AlreadyRunningMappingMissing;
    }
    if (std.mem.indexOf(u8, source, "409") == null) {
        std.debug.print(
            "\n!! {s} does not return a 409 status code !!\n" ++
                "   The AlreadyRunning branch must produce `status_code = 409`.\n" ++
                "   See docs/superpowers/plans/2026-06-13-add-task-routines-chunk-4.md.\n",
            .{HANDLER_PATH},
        );
        return error.AlreadyRunningStatusMissing;
    }
}

// ─── Contract 6: success returns 200 with session_id JSON ──────────────────

test "routines_run handler returns 200 with session_id on success" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    // On success the handler returns 200 OK with a JSON body containing
    // `session_id` (which equals the task id per the project's
    // `task.id == session.id` invariant for routine tasks). The
    // `session_id` field is what the client uses to navigate to the
    // new chat session.
    if (std.mem.indexOf(u8, source, "session_id") == null) {
        std.debug.print(
            "\n!! {s} does not return a `session_id` field !!\n" ++
                "   The success-response contract is broken: the client has\n" ++
                "   no way to find the newly-created session. Return\n" ++
                "   `{{\"success\":true,\"session_id\":\"<task_id>\",\"status\":\"firing\"}}`\n" ++
                "   with status_code = 200.\n" ++
                "   See docs/superpowers/plans/2026-06-13-add-task-routines-chunk-4.md.\n",
            .{HANDLER_PATH},
        );
        return error.SessionIdResponseMissing;
    }
    if (std.mem.indexOf(u8, source, "200") == null) {
        std.debug.print(
            "\n!! {s} does not return a 200 status code !!\n" ++
                "   The success branch must produce `status_code = 200`.\n" ++
                "   See docs/superpowers/plans/2026-06-13-add-task-routines-chunk-4.md.\n",
            .{HANDLER_PATH},
        );
        return error.SuccessStatusMissing;
    }
}
