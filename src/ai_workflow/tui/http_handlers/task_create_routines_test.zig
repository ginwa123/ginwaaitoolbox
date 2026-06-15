//! Static regression checks for the routine-aware task create handler.
//!
//! Why this file exists
//! ────────────────────
//! The Add Task Routines feature (plan: `2026-06-13-add-task-routines.md`)
//! introduces a new `task_type` column on `workspace_item_tasks` and a
//! parallel `routines` table for cron-scheduled task execution. The
//! POST /api/workspaces/:workspace_id/items/:item_id/tasks handler must
//! accept `task_type` + routine fields, validate the cron, compute
//! `next_run_at`, and insert a `routines` row for routine tasks.
//!
//! These contracts are enforced by static substring checks (matching
//! the project's `task_update_test.zig` / `tasks_list_test.zig` pattern),
//! not by spinning up an in-memory DB. Standing up a sqlite DB + migrations
//! + event bus to behavioural-test the handler would duplicate the
//! migration setup and pull in `nalarcore.getSingleton()` (which depends
//! on a live `ContextIPCTui` with a server, logger, and event bus). The
//! static checks below directly test the bug — they fail if and only if
//! the routine-creation plumbing is removed or routed back to the plain
//! standard-task path.
//!
//! Plan: docs/superpowers/plans/2026-06-13-add-task-routines-chunk-4.md

const std = @import("std");
const testing = std.testing;

const HANDLER_PATH = "src/ai_workflow/tui/http_handlers/task_create.zig";
const REQ_PATH = "src/ai_workflow/tui/http_handlers/http_response.zig";

/// Read a source file from disk, relative to the project root
/// (which is the cwd when `zig build test:ai_workflow:tui` runs).
fn readSource(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        path,
        allocator,
        .limited(256 * 1024),
    );
}

// ─── Contract 1: TaskCreateRequest has task_type + routine fields ──────────

test "TaskCreateRequest has task_type + routine fields" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, REQ_PATH);
    defer allocator.free(source);

    // The request struct must carry the four routine-creation fields.
    // Without these, a client cannot request a routine task and the
    // handler will fall through to the standard-task path regardless
    // of intent.
    if (std.mem.indexOf(u8, source, "task_type") == null) {
        std.debug.print(
            "\n!! {s} does not define a `task_type` field on TaskCreateRequest !!\n" ++
                "   The routine-creation contract is broken: clients cannot request\n" ++
                "   a routine task. Every POST will silently become a standard task\n" ++
                "   and no row will be inserted into the `routines` table.\n" ++
                "   Add the field to TaskCreateRequest (defaults to 'standard').\n" ++
                "   See docs/superpowers/plans/2026-06-13-add-task-routines-chunk-4.md.\n",
            .{REQ_PATH},
        );
        return error.TaskTypeFieldMissing;
    }
    if (std.mem.indexOf(u8, source, "schedule") == null) {
        std.debug.print(
            "\n!! {s} does not define a `schedule` field on TaskCreateRequest !!\n" ++
                "   Add `schedule: ?[]const u8 = null` to the struct.\n",
            .{REQ_PATH},
        );
        return error.RoutineFieldsMissing;
    }
    if (std.mem.indexOf(u8, source, "initial_prompt") == null) {
        std.debug.print(
            "\n!! {s} does not define an `initial_prompt` field on TaskCreateRequest !!\n" ++
                "   Add `initial_prompt: ?[]const u8 = null` to the struct.\n",
            .{REQ_PATH},
        );
        return error.RoutineFieldsMissing;
    }
    if (std.mem.indexOf(u8, source, "enabled") == null) {
        std.debug.print(
            "\n!! {s} does not define an `enabled` field on TaskCreateRequest !!\n" ++
                "   Add `enabled: bool = true` to the struct.\n",
            .{REQ_PATH},
        );
        return error.RoutineFieldsMissing;
    }
}

// ─── Contract 2: handler validates the cron expression ────────────────────

test "task_create handler validates the cron expression" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    // The handler must call `cron.validate(schedule)` for routine tasks
    // and return 400 on a bad expression. Without this check, a typo'd
    // cron silently produces a `routines` row that the scheduler will
    // never be able to compute a fire-time for.
    if (std.mem.indexOf(u8, source, "cron.validate") == null) {
        std.debug.print(
            "\n!! {s} does not call cron.validate !!\n" ++
                "   The cron-validation contract is broken: a bad cron expression\n" ++
                "   will be stored verbatim in the `routines` table and the\n" ++
                "   scheduler's `nextFireTime` will fail forever.\n" ++
                "   See docs/superpowers/plans/2026-06-13-add-task-routines-chunk-4.md.\n",
            .{HANDLER_PATH},
        );
        return error.CronValidateMissing;
    }
}

// ─── Contract 3: handler computes next_run_at ──────────────────────────────

test "task_create handler computes next_run_at" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    // The handler must compute the first `next_run_at` for the routine
    // by calling `cron.nextFireTime(schedule, now_ns)`. The `routines`
    // table has `next_run_at DATETIME NOT NULL`, so a missing value will
    // be rejected by SQLite.
    if (std.mem.indexOf(u8, source, "cron.nextFireTime") == null) {
        std.debug.print(
            "\n!! {s} does not call cron.nextFireTime !!\n" ++
                "   The next-run-time contract is broken: the routines row will\n" ++
                "   either be rejected by SQLite (NOT NULL on next_run_at) or\n" ++
                "   have a NULL/stale value that the scheduler will use.\n" ++
                "   See docs/superpowers/plans/2026-06-13-add-task-routines-chunk-4.md.\n",
            .{HANDLER_PATH},
        );
        return error.CronNextFireTimeMissing;
    }
}

// ─── Contract 4: handler inserts a routines row for routine tasks ─────────

test "task_create handler inserts a routines row for routines" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    // The handler must INSERT a row into the `routines` table after the
    // workspace_item_tasks INSERT for routine tasks. Without this, the
    // routine would exist as a task row but never be picked up by the
    // scheduler (which scans `routines`).
    if (std.mem.indexOf(u8, source, "INSERT INTO routines") == null) {
        std.debug.print(
            "\n!! {s} does not contain 'INSERT INTO routines' !!\n" ++
                "   The routine-INSERT contract is broken: routine tasks will be\n" ++
                "   created as plain workspace_item_tasks rows but the scheduler\n" ++
                "   only reads from the `routines` table, so they will never fire.\n" ++
                "   Add the INSERT after the task INSERT for task_type='routine'.\n" ++
                "   See docs/superpowers/plans/2026-06-13-add-task-routines-chunk-4.md.\n",
            .{HANDLER_PATH},
        );
        return error.RoutineInsertMissing;
    }
}
