# Plan — Kanban worker-entry path must not overwrite `sessions.name`

## Date
2026-08-25

## Branch
`worktree/kanban-functest-race-fix`

## Task
task_1787671636395_1 (Kanban: task name and session name should match)

## Background

PR #225 / #345 (merged 2026-08-25) closed every kanban CREATE path —
`kanban_tasks_create.zig::handle` (`mode='create_session'`, `mode='create_and_run'`),
`task_create.zig::useCase` (`mode='create'` legacy), and the lazy-init fallback
in `session_create.zig::useCase` — so that `sessions.name` is correctly bound to
the user-typed task title at the moment of insert.

User reported CI run 32868582221 still showed the symptom: sidebar's ChatsList
rendered `task_<timestamp>` instead of the user-typed title.

## Root cause

The CREATE-time INSERTs in PR #225 / #345 are correct — verified by reading the
sessions row immediately after each POST returns. But the symptom still
appeared because every worker iteration calls
`update_worker.zig::updateWorker`, which contained:

```sql
INSERT INTO sessions (id, name, ...) VALUES (?, ?, ...)
ON CONFLICT(id) DO UPDATE SET
    name = excluded.name,    -- ← THIS overwrote the kanban-bound title
    status = excluded.status,
    updated_at = CURRENT_TIMESTAMP;
```

For kanban tasks, `task.id == session.id` (Migration 052). The literal
`session_id` passed as the second bind parameter was always the task_id
(`task_<timestamp>`), not the user-typed title. Whichever worker iteration
fired last won the race — and the kanban handler's bind was lost.

This is the **same bug class as PR #225** but on a code path PR #225 did not
cover. The handler binds the title at create time; the worker then un-binds it
on its first iteration. Both bugs share the root cause:

> Someone reached for `ON CONFLICT(id) DO UPDATE SET name = excluded.name`
> instead of an idempotent no-op.

The semantic mismatch is: the worker does NOT own `sessions.name`. The
session-create handler does. The worker's only legitimate columns are
`status` (it transitioned to `active` when the worker started) and
`updated_at` (so cleanup_stale_worker cron doesn't wipe a long-running
workflow — see memory `cleanup-stale-worker-cron`).

## Fix

Surgical patch to `src/ai_workflow/tui/agentic_loop/update_worker.zig` — split
the upsert into two statements:

1. **`INSERT OR IGNORE`** — only fires when the row is missing; when present
   (the kanban handler bound the title), it's a no-op. Always passes `''` as
   the `name` because the worker's caller already set it correctly.

2. **`UPDATE updated_at = CURRENT_TIMESTAMP WHERE id = ?`** — bumps the
   timestamp so the cleanup cron doesn't wipe a long-running workflow.
   **The `name` column is NEVER touched by this upsert.**

The split also handles a related concern: pre-fix, the worker's
`ON CONFLICT DO UPDATE SET status = excluded.status` would set `status='active'`
on every iteration, undoing any `status='paused'` / `'stopped'` the user might
have set. The split doesn't fix that (it doesn't touch `status` either now),
but it's a step toward a future worker-state-management cleanup.

## Files changed

| File | Change | Lines |
|---|---|---|
| `src/ai_workflow/tui/agentic_loop/update_worker.zig` | Split upsert | 24 lines |
| `src/root.zig` | Remove debug log | 1 line |
| `tests/functional/kanban_task_session_name_test.py` | Poll for sessions row in lazy-init test | 45 lines |

## Test hardening

The lazy-init test (`test_chat_first_message_after_lazy_create_binds_session_name_to_task_name`)
intermittently failed on CI runner 32868582221 with a single read returning
`None`. Root cause: `di.emit_run_agent` schedules `insert_worker` on an
async Io group, and the HTTP response returns BEFORE that task runs.
Locally the gap is microseconds (5/5 pass); on a slow CI runner, the gap
can stretch past the read deadline.

Fix: poll-with-deadline (5s, 50ms interval). Still pin the same contract
(`sessions.name == task.title` once the row lands), just on a small time
budget instead of a single point-in-time read.

## Verification

| Suite | Result |
|---|---|
| `zig build test --summary all` | 2698/2704 pass, 6 skip, 0 fail, 49 s |
| `tests/functional/` (all 226) | 226/226 pass, 70 s |
| `tests/functional/kanban_*` (52) | 52/52 pass, 24 s |
| Manual: CI flake reproduction (poll with 5ms interval) | Confirmed row materialises 1–3 ms after response |

## Commit

```
5d098d4f fix(kanban): worker-entry path must not overwrite sessions.name with task_id
```

## Memory note

`save_memory({ id: 'mem_db1fcf9439c54448', tags: 'pattern||sessions||kanban||migration-contract' })`
— pins the invariant that any future code touching `sessions` MUST NOT
overwrite `name` in an idempotent upsert. Audit checklist included.