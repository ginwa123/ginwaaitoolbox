# Kanban task ↔ linked session name must bind at create time

- **Task:** task_1787671636395_1 (kanban card "task name and session name should same")
- **Branch:** `worktree/kanban-task-session-name-bind` (commit `34cced0a`)
- **Date:** 2026-09-02
- **Status:** IMPLEMENTED, awaiting PR + human review

## User-reported symptom

The user opened a kanban board and ran:

```sql
SELECT wit.id, wit.name, s.name
FROM workspace_item_tasks wit
JOIN sessions s ON s.id = wit.id
ORDER BY wit.created_at DESC LIMIT 1;
```

Result:

| wit.id | wit.name | s.name |
|--------|----------|--------|
| `task_1787671269086_0` | "settings like on notifi when error not s…" | `task_1787671269086_0` |

The kanban card showed the user-typed title; the linked session row
held the literal task_id as the `name` placeholder. The sidebar's
ChatsList reads from `sessions.name`, so users saw the task_id in
the sidebar instead of the title they typed.

## Root cause

Three create paths already bound `sessions.name = workspace_item_tasks.name`
correctly (PR #225 / commit `e7a95577`):

1. `task_create.zig::useCase` — when `is_auto_retry_until_stop` is set
2. `kanban_tasks_create.zig` — `mode='create_session'`
3. `kanban_tasks_create.zig` — `mode='create_and_run'`

A fourth create path was missing the bind: **the LAZY-INIT path**.

When a kanban task is created WITHOUT any session-init flag (plain
`mode='create'` with no unattended toggle, OR the generic
`POST /api/workspaces/:ws/items/:item/tasks` endpoint with no
unattended flag, OR the LLM agent tool `create_kanban_task` with no
profile), no `sessions` row is written at create time. The row is
created later when the user opens the chat and sends the first
message — which goes through `POST /api/llm/session` →
`session_create.zig::useCase`.

The frontend's `api.sendChatMessage` (the path ChatView uses to
send the first chat message — see `apps/desktop/src/api/index.ts:1278-1324`)
does **NOT** carry `session_name` on the wire. The backend's
`session_create.zig:106` defaults `session_name` to the literal
`"New Session"`, and the only override at line 117 is
`if (parsed.session_name.len > 0) session_name = parsed.session_name` —
which doesn't fire because the field is empty.

So the lazy-init path inserts `sessions.name = 'New Session'` while
`workspace_item_tasks.name = <user-typed title>`. **Same bug class
as the user's screenshot, different placeholder** (their screenshot
showed task_id as the placeholder — pre-PR-#225 rows that escaped
the bind at INSERT time; our regression test catches the
'New Session' variant for rows created via the lazy-init path
post-PR-#225).

## Fix

`session_create.zig::useCase` (src/ai_workflow/tui/http_handlers/session_create.zig):

After the existing `if (parsed.session_name.len > 0)` override,
add a fallback:

```zig
if (std.mem.eql(u8, session_name, "New Session") and parsed.session_id.len > 0) {
    if (resolveNameFromTask(alloc, di, parsed.session_id)) |maybe_name| {
        if (maybe_name) |task_name| {
            session_name = task_name;
        }
    } else |err| {
        std.log.warn(
            "session_create: task-name fallback lookup failed (non-fatal, keeping 'New Session'): {s}",
            .{@errorName(err)},
        );
    }
}
```

The `resolveNameFromTask` helper is a single
`SELECT name FROM workspace_item_tasks WHERE id = ?` — same shape
as the existing `resolveCwdFromTaskOrItem` (which already
performs the same kind of fallback for `cwd_session` further down
the file). Returns null when no row matched (or the title is
empty); returns `error.QueryFailed` only on a DB blip (the caller
logs + keeps the default, so a transient outage doesn't break
session creation).

The override is gated on `session_name == "New Session"`, so:

- Brand-new sidebar "New Chat" with no `session_id` → keeps "New Session"
- Random `session_id` with no matching task → keeps "New Session"
- Caller-supplied `session_name != "New Session"` → keeps the caller's value
- Kanban task with no pre-init session + chat first message → resolves
  the task title from `workspace_item_tasks`

## Test coverage

### Functional (`tests/functional/kanban_task_session_name_test.py`, 7 tests)

One test per create path, all reading `sessions.name` straight from
the SQLite DB (`harness.temp_dir / ".config" / "pabrik" / "agent.db"`)
so we exercise the actual wire round-trip against a real binary:

| Test | Path | Asserts |
|------|------|---------|
| `test_create_session_binds_session_name_to_task_name` | `POST /api/.../kanban/tasks mode=create_session` | sessions.name == task title |
| `test_create_and_run_binds_session_name_to_task_name` | `POST /api/.../kanban/tasks mode=create_and_run` | sessions.name == task title |
| `test_create_legacy_with_unattended_binds_session_name_to_task_name` | `POST /api/.../kanban/tasks mode=create is_auto_retry_until_stop=1` | sessions.name == task title |
| `test_create_legacy_without_unattended_creates_no_session_row` | `POST /api/.../kanban/tasks mode=create (no unattended)` | sessions row absent (lazy-init design) |
| `test_standard_task_via_generic_endpoint_with_unattended_binds_name` | `POST /api/.../tasks is_auto_retry_until_stop=1` | sessions.name == task title |
| `test_standard_task_via_generic_endpoint_without_unattended_creates_no_row` | `POST /api/.../tasks (no unattended)` | sessions row absent |
| `test_chat_first_message_after_lazy_create_binds_session_name_to_task_name` | Create lazy task → `POST /api/llm/session` (no session_name) | sessions.name == task title (regression for THIS bug) |

Pre-fix the last test fails with `sessions.name = 'New Session'`.
Post-fix it passes. The other 6 tests pin the existing PR-#225
contract against future regressions.

### Zig static-contract tests (3 inline tests at bottom of `session_create.zig`)

- `session_create.zig defines resolveNameFromTask helper` — grep
  the source for `fn resolveNameFromTask(`; fail closed if missing
- `session_create useCase calls resolveNameFromTask when session_name is 'New Session'` — grep for `resolveNameFromTask(` and assert it appears AFTER the `'New Session'` literal (so the gate `session_name == 'New Session'` is meaningful)
- `session_create resolveNameFromTask SELECTs from workspace_item_tasks` — grep for the exact SQL string

These lock in the structural contract so a future refactor that
deletes the helper, moves the call site before the default, or
points the SELECT at a different table all fail at `zig build test`
— even before the slower functional tests run.

## Files changed

- `src/ai_workflow/tui/http_handlers/session_create.zig` — fix + 3 inline tests (+199 lines)
- `src/ai_workflow/tui/test_runner.zig` — register inline tests (+5 lines)
- `tests/functional/kanban_task_session_name_test.py` — new test file (+523 lines)

## Verification

```
zig build test --summary all
  → 2688/2694 pass, 6 skipped, 0 failed

PABRIK_BIN=./zig-out/bin/pabrik python3 -m pytest tests/functional/kanban_task_session_name_test.py -v
  → 7/7 passed in 1.50s

PABRIK_BIN=./zig-out/bin/pabrik python3 -m pytest tests/functional/{kanban_create_session_user_message,kanban_lifecycle,kanban_task_get,kanban_advanced} -v
  → 32/32 passed (no regressions in existing kanban tests)
```

## What I deliberately didn't do

- **No backfill migration.** Old rows where `sessions.name` holds a
  literal task_id are out of scope — they were created via paths
  that were fixed in PR #225. The fix is "new rows must bind
  correctly", not "rewrite historical data". If a backfill becomes
  necessary later, it's a separate `UPDATE sessions SET name = (SELECT name FROM workspace_item_tasks WHERE id = sessions.id)` Migration.

- **No `api.sendChatMessage` frontend change.** Considered passing
  `sessionName: task.name` from ChatView / KanbanView, but the
  server-side fallback is the right place — it catches every caller
  (Vue, curl, future tools, agent tool `emit_run_agent`) not just
  the one frontend path. Frontend stays unchanged.

- **No new SSE event name.** The `session.created` SSE now carries
  the task title instead of "New Session", but the event name is
  unchanged — reuses existing `additionalEventTypes` and dispatch
  chain (avoids the 3-site event-name pairing contract per the SSE
  wire-format rule).

- **No change to `insertWorker` in session_create.zig.** It's
  defined but never called from `useCase` (verified via grep —
  the only reference is the comment at kanban_tasks_create.zig:360).
  Pre-existing dead code; out of scope.

## Cross-references

- PR #225 (commit `e7a95577`): the original bind for
  `mode='create_and_run'`
- commit `41dca4d3`: bind for the agent tool `create_kanban_task`
- commit `9e5b43fc`: bind for `task_create.zig::useCase`
- task_1786626864861: the previous kanban-task-session-name task
  (closed by the 2026-08-13 fix; the bug regressed via the lazy-init
  path the prior fix didn't touch)
- task_1787671269086_0: the user's screenshot task, showing the
  task_id-as-name variant (different symptom, same bug class)
