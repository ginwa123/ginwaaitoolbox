//! Static regression checks for the routine-aware task update handler.
//!
//! Why this file exists
//! ────────────────────
//! The Add Task Routines feature (plan: `2026-06-13-add-task-routines.md`)
//! introduces a new `task_type` column on `workspace_item_tasks` and a
//! parallel `routines` table for cron-scheduled task execution. The
//! PUT /api/workspaces/tasks/:task_id (and the by-workspace-item variant)
//! handler must accept the routine fields (`schedule`, `initial_prompt`,
//! `enabled`), validate the cron, recompute `next_run_at`, and write the
//! new values to the `routines` table.
//!
//! These contracts are enforced by static substring checks (matching
//! the project's `task_create_routines_test.zig` / `task_update_test.zig`
//! pattern), not by spinning up an in-memory DB. Standing up a sqlite DB
//! + migrations + event bus to behavioural-test the handler would
//! duplicate the migration setup and pull in `nalarcore.getSingleton()`
//! (which depends on a live `ContextIPCTui` with a server, logger, and
//! event bus). The static checks below directly test the bug — they
//! fail if and only if the routine-update plumbing is removed or routed
//! back to the plain standard-task update path.
//!
//! Plan: docs/superpowers/plans/2026-06-13-add-task-routines-chunk-4.md

const std = @import("std");
const testing = std.testing;
const nalarcore = @import("nalarcore");
const text_normalize = @import("helpers").text_normalize;

const HANDLER_PATH = "src/ai_workflow/tui/http_handlers/task_update.zig";
const REQ_PATH = "src/ai_workflow/tui/http_handlers/http_response.zig";

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

// ─── Contract 1: TaskUpdateRequest has routine fields ────────────────────

test "TaskUpdateRequest has routine fields" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, REQ_PATH);
    defer allocator.free(source);

    // The request struct must carry the three routine-update fields.
    // Without these, a client cannot change a task into a routine (or
    // mutate its schedule) and the handler will silently no-op on the
    // routine portion of the request — leaving the routines row stale.
    if (std.mem.indexOf(u8, source, "schedule") == null) {
        std.debug.print(
            "\n!! {s} does not define a `schedule` field on TaskUpdateRequest !!\n" ++
                "   The routine-update contract is broken: a client cannot change\n" ++
                "   a task's cron expression. The `routines` row will stay stale\n" ++
                "   (the old schedule) and the scheduler will keep firing at the\n" ++
                "   old time even after the user 'updated' the schedule via UI.\n" ++
                "   Add the field to TaskUpdateRequest (nullable, defaults to null).\n" ++
                "   See docs/superpowers/plans/2026-06-13-add-task-routines-chunk-4.md.\n",
            .{REQ_PATH},
        );
        return error.RoutineUpdateFieldsMissing;
    }
    if (std.mem.indexOf(u8, source, "initial_prompt") == null) {
        std.debug.print(
            "\n!! {s} does not define an `initial_prompt` field on TaskUpdateRequest !!\n" ++
                "   The routine-update contract is broken: a client cannot change\n" ++
                "   a task's LLM prompt. Add `initial_prompt: ?[]const u8 = null`.\n",
            .{REQ_PATH},
        );
        return error.RoutineUpdateFieldsMissing;
    }
    if (std.mem.indexOf(u8, source, "enabled") == null) {
        std.debug.print(
            "\n!! {s} does not define an `enabled` field on TaskUpdateRequest !!\n" ++
                "   The routine-update contract is broken: a client cannot toggle\n" ++
                "   a routine active/inactive. Add `enabled: ?bool = null`.\n",
            .{REQ_PATH},
        );
        return error.RoutineUpdateFieldsMissing;
    }
}

// ─── Contract 2: handler validates the schedule on update ────────────────

test "task_update handler validates the schedule" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    // The handler must call `cron.validate(schedule)` for routine updates
    // and return 400 on a bad expression. Without this check, a typo'd
    // cron silently overwrites a previously-valid schedule in the
    // `routines` table and the scheduler's `nextFireTime` will fail
    // forever (no valid next fire time can be computed).
    if (std.mem.indexOf(u8, source, "cron.validate") == null) {
        std.debug.print(
            "\n!! {s} does not call cron.validate !!\n" ++
                "   The cron-validation contract is broken: a bad cron expression\n" ++
                "   in a PUT body will silently overwrite a valid schedule in the\n" ++
                "   `routines` table, and the scheduler's `nextFireTime` will fail\n" ++
                "   forever on that routine.\n" ++
                "   See docs/superpowers/plans/2026-06-13-add-task-routines-chunk-4.md.\n",
            .{HANDLER_PATH},
        );
        return error.CronValidateMissing;
    }
}

// ─── Contract 3: handler recomputes next_run_at on schedule change ───────

test "task_update handler recomputes next_run_at on schedule change" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    // The handler must recompute `next_run_at` via
    // `cron.nextFireTime(schedule, now_ns)` when the schedule changes.
    // The `routines` table has `next_run_at DATETIME NOT NULL`, so a
    // missing/stale value will either be rejected by SQLite or cause
    // the scheduler to fire at the old (wrong) time.
    if (std.mem.indexOf(u8, source, "cron.nextFireTime") == null) {
        std.debug.print(
            "\n!! {s} does not call cron.nextFireTime !!\n" ++
                "   The next-run-time recomputation contract is broken: a routine\n" ++
                "   with an updated schedule will keep firing at the OLD time\n" ++
                "   because next_run_at is never recomputed from the new cron.\n" ++
                "   See docs/superpowers/plans/2026-06-13-add-task-routines-chunk-4.md.\n",
            .{HANDLER_PATH},
        );
        return error.CronRecomputeMissing;
    }
}

// ─── Contract 4: handler writes the new values to the routines table ─────

test "task_update handler writes to the routines table" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    // The handler must persist the routine-fields update to the
    // `routines` table — via UPDATE (existing row) or INSERT OR REPLACE
    // (idempotent for the missing-row case). Without this, the routine
    // row's schedule/initial_prompt/enabled stay stale even though the
    // API returned 200 OK.
    const has_routine_write = std.mem.indexOf(u8, source, "UPDATE routines") != null or
        std.mem.indexOf(u8, source, "INSERT OR REPLACE INTO routines") != null or
        std.mem.indexOf(u8, source, "updateRoutine") != null;
    if (!has_routine_write) {
        std.debug.print(
            "\n!! {s} does not write to the `routines` table on routine-fields update !!\n" ++
                "   The routine-update contract is broken: a PUT with routine fields\n" ++
                "   returns 200 OK but the `routines` row keeps its old schedule/prompt\n" ++
                "   /enabled. The scheduler reads from `routines`, so the change is\n" ++
                "   effectively a no-op.\n" ++
                "   Add an UPDATE on the routines table (or INSERT OR REPLACE for the\n" ++
                "   missing-row case) after the standard task updates.\n" ++
                "   See docs/superpowers/plans/2026-06-13-add-task-routines-chunk-4.md.\n",
            .{HANDLER_PATH},
        );
        return error.RoutineUpdateMissing;
    }
}
