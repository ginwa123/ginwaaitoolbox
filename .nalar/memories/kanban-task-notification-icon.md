# Kanban task "AI finished — awaiting review" notification icon

## What
Small affordance on each standard kanban task card that tells the
user at a glance which cards the AI is done with and which the
user has already engaged with. Three terminal states:

| State | Card UI |
|---|---|
| AI running | Yellow spinner (existing) |
| AI finished, awaiting review | 8px **orange dot** with 4-pulse ripple, then steady glow |
| AI finished, reviewed | Small **green checkmark** |
| AI never ran | No icon |

## Why
Before this feature, users had no signal that the AI finished a
turn on a kanban task. The card just sat there with no
indication. Users couldn't tell at a glance which cards needed
review vs. which the AI was still working on.

## Status (2026-07-26)
Feature landed (PR #132, branch `worktree/kanban-task-notification-icon`).
Docs in `docs/SPEC.md` §3.7.1. Plan file deleted (per project
convention — content rolled into SPEC).

## Data model
- One new column on `workspace_item_tasks` (Migration 065):
  `last_human_touched_at INTEGER` (unix ms, NULL = never).
- AI state reuses `sessions.last_finish_reason` +
  `sessions.updated_at` (both from Migration 063 — no new
  session columns).
- The kanban-list `CASE` predicate (new column 20 in
  `listWorkspaceItemTasksWithCursor`):

  ```sql
  CASE WHEN COALESCE(s.last_finish_reason, '') = 'stop'
            AND (t.last_human_touched_at IS NULL
                 OR t.last_human_touched_at
                    < CAST(strftime('%s', s.updated_at) AS INTEGER) * 1000)
       THEN 1 ELSE 0 END
  ```

  `* 1000` is the seconds→unix-ms conversion (sessions.updated_at
  is TEXT in `YYYY-MM-DD HH:MM:SS`; `last_human_touched_at` is
  INTEGER unix-ms).

## "Human touch" semantic
ANY user action counts as a review. Matches GitHub's
"conversation resolved" model. Stamp call sites:
- `task_update.zig` (rename, description edit, pin/unpin)
- `task_create.zig` (any new task; user owns the empty slot)
- `tasks_move.zig` (drag to another column)
- `session_create.zig` (POST `/api/llm/session` — sending a chat
  message; `task.id == session.id` per project convention)
- `task_mark_human_touched.zig` (PUT
  `/api/.../tasks/:id/touched` — fired by the frontend the
  moment the user opens a task's chat, even if they don't send
  a message)

All stamps are fire-and-forget. A failed stamp logs a warning
but does NOT fail the user-visible action.

## Frontend wiring
`workspacesStore.setActiveTask(taskId)` (canonical entry point
for every "user opens a task" call) fires-and-forgets
`api.markTaskHumanTouched(workspaceId, itemId, taskId)`. The
parent workspace_id + item_id are already discovered by the
existing parent-finding loop, so no extra plumbing.

## SSE wire
`KanbanTaskAction` enum gains `human_touched` variant.
`KanbanTaskEventPayload` gains `needs_human_review: ?bool` field.
The frontend `kanbanSse` store already handles `'task_id' in
event` to trigger `fetchKanbanTasks` — no consumer change needed
for the new action.

## Frontend card UI
Two new `<span>` blocks in `WorkspaceItemTaskCard.vue` standard
branch only (NOT in the routine branch — routine has its own
status dot). Memory cards share the standard branch and DO show
the icons. `<style scoped>` keyframes `needs-review-pulse` for
the orange dot's 4-pulse ripple.

## Pitfalls

### "Touched by human" = ANY user action, not just explicit review
Per design. Don't add an "explicit Mark as reviewed" button
unless explicitly requested — the implicit-touch model is
intentional. Adding it would create two ways to mark a card
reviewed and the icon behavior would be ambiguous.

### DO NOT stamp from the AI side
The AI workflow's own responses do NOT call
`updateTaskLastHumanTouchedAt`. If a future AI-side call were
added, the green checkmark would be permanently stuck on — the
opposite of the feature's intent. `workflow.zig` only writes
`sessions.last_finish_reason` (via
`updateSessionLastFinishReason`), NOT the task's human-touched
column. The two are deliberately separate concerns.

### Don't gate the mark call on `activeTaskId === taskId`
An early-return guard for re-clicking the already-active card
breaks the legitimate "user changes activeWorkspaceItem, then
re-activates the task to update the parent" flow (see
`AppLayout.kanban.spec.ts` "does NOT render KanbanView when the
active task's parent is a different workspace item"). The mark
call is fire-and-forget and cheap; let it fire on every
activation. The backend endpoint is idempotent (re-stamping is
harmless — the column is just a monotonic timestamp).

### Defensive gate: `last_finish_reason === 'stop'` in the template
The card's `v-else-if` for the orange dot checks BOTH
`needs_human_review` AND `last_finish_reason === 'stop'`. The
SQL predicate COALESCE'd `last_finish_reason` to `''` for tasks
with no session row, so the check is necessary. Without the
defensive gate, a stale React prop during a session-state
transition (e.g. `finish_reason='tool_calls'` briefly coexists
with a stale `needs_human_review=true`) would paint a phantom
orange dot. Same for the green checkmark.

### Register migration in `allMigrations` slice
Adding a `MigrationNNN` struct in `migration.zig` is NOT
enough — it must also be added to the `allMigrations` slice at
the bottom of the same file, otherwise the migration runner
silently skips it. Fresh-DB installs then have no
`last_human_touched_at` column and every task list fetch logs
`no such column: last_human_touched_at`. The `migration_NNN_test`
imports the struct directly so static tests pass with a
silent-skip bug. Always add the registration tuple when
adding a migration.

### Don't forget to release the per-row slice allocations
`WorkspaceItemTaskInfo.deinit` must free `last_finish_reason`
(a heap-allocated slice from `allocator.dupe`). Forgetting
this leaks 1 slice per kanban list call. Mirror the pattern of
the other slice fields.

### `last_finish_reason` lives in the routine/memory JOIN too
`listWorkspaceItemTasksWithCursor` LEFT JOINs both `routines` and
`sessions` onto `workspace_item_tasks`. The new `last_finish_reason`
column comes from the sessions LEFT JOIN — `COALESCE(s.last_finish_reason, '')`
in the SQL handles tasks with no session row. The
`needs_human_review` CASE references `t.last_human_touched_at`
(direct on the task table — no JOIN needed).

## Files touched
- `src/migrations/migration.zig` — Migration 065 struct + allMigrations registration
- `src/migrations/migration_065_test.zig` — 5 new tests
- `src/ai_workflow/tui/llm_history.zig` — `updateTaskLastHumanTouchedAt` writer
  + `unixMillisNow()` helper
- `src/ai_workflow/tui/llm_history_notification_test.zig` — 11 new tests
- `src/ai_workflow/tui/http_handlers/http_response.zig` —
  `WorkspaceItemTaskResponse` gains `last_finish_reason` +
  `needs_human_review` fields
- `src/ai_workflow/tui/http_handlers/tasks_list.zig` — pass new
  fields through to response
- `src/ai_workflow/tui/http_handlers/task_mark_human_touched.zig`
  — NEW handler (PUT /touched)
- `src/ai_workflow/tui/http_handlers/task_mark_human_touched_test.zig`
  — 6 new tests
- `src/ai_workflow/tui/http_handlers/task_update.zig` — stamp
  after successful useCase
- `src/ai_workflow/tui/http_handlers/task_create.zig` — stamp
  after createWorkspaceItemTask
- `src/ai_workflow/tui/http_handlers/tasks_move.zig` — stamp
  after kanban_model.moveTask + SSE emit
- `src/ai_workflow/tui/http_handlers/session_create.zig` — stamp
  after useCase
- `src/ai_workflow/tui/http_handlers/task_touch_propagation_test.zig`
  — 4 new tests
- `src/ai_workflow/tui/http_handlers/mod.zig` — re-export
  `taskMarkHumanTouchedHandler`
- `src/ai_workflow/tui/on_event_sent_kanban.zig` — add
  `human_touched` to `KanbanTaskAction` enum +
  `needs_human_review: ?bool` to `KanbanTaskEventPayload`
- `src/main.zig` — register PUT route
- `src/apps/desktop/src/stores/workspaces.ts` — `Task` interface
  gains `last_finish_reason?` + `needs_human_review?`; setActiveTask
  fires markTaskHumanTouched
- `src/apps/desktop/src/api/index.ts` — `markTaskHumanTouched()`
- `src/apps/desktop/src/components/workspace/WorkspaceItemTaskCard.vue`
  — two new icon blocks + `@keyframes needs-review-pulse` + `<style scoped>`
- `src/apps/desktop/src/__tests__/workspaceItemTaskNotification.spec.ts`
  — 9 new tests
- `src/apps/desktop/src/__tests__/workspacesStoreMarkTouched.spec.ts`
  — 4 new tests
- `docs/SPEC.md` — §3.7.1 feature description + §3.7 plan row +
  §10.2.1 PR index entry

## Test coverage
- 5 migration tests (column add, idempotency, NULL default, etc.)
- 11 llm_history tests (writer + SQL CASE predicate across 4
  scenarios)
- 6 task_mark_human_touched tests (handler + SSE wire)
- 4 task_touch_propagation tests (5 stamp call sites)
- 9 workspaceItemTaskNotification tests (icon states)
- 4 workspacesStoreMarkTouched tests (stamp hook)
- 39 new tests total. All 1876 backend + 1483 frontend tests pass
  (pre-existing 3 workflow_retry_delay_test failures unrelated).

## End-to-end smoke recipe (verified 2026-07-26 against port 8080)
```bash
# Boot on port 8080 (NEVER 8081)
rm -rf /tmp/nalar-kn-smoke
env -i HOME=/tmp/nalar-kn-smoke PATH=$PATH \
  ./zig-out/bin/nalarcore-linux-x86_64 --port 8080 &

# Create workspace + kanban + task
WS=$(curl ... POST /api/workspaces -d '{"name":"kn"}' | jq -r .id)
ITEM=$(curl ... POST /api/workspaces/$WS/items/kanban -d '{"name":"board","path":"/tmp"}' | jq -r .item.id)
TASK=$(curl ... POST /api/workspaces/$WS/items/$ITEM/tasks -d '{"name":"AI task"}' | jq -r .id)

# State 1: no icon (last_finish_reason='', needs_human_review=false)
curl ... GET /api/workspaces/$WS/items/$ITEM/tasks

# Simulate AI finishing
sqlite3 /tmp/nalar-kn-smoke/.config/nalar/agent.db \
  "INSERT INTO sessions (id, name, status, last_finish_reason, updated_at)
   VALUES ('$TASK', 'AI task', 'idle', 'stop', datetime('now'))"

# State 2: orange dot (last_finish_reason='stop', needs_human_review=true)
curl ... GET .../tasks

# User opens the task
curl ... -X PUT .../tasks/$TASK/touched

# State 3: green checkmark (last_finish_reason='stop', needs_human_review=false)
curl ... GET .../tasks
```

## Reference
- Plan (deleted): `docs/plans/2026-07-26-kanban-task-notification-icon.md`
- Spec section: `docs/SPEC.md` §3.7.1
- PR #132 (committed as 8 chunks on branch `worktree/kanban-task-notification-icon`)
- Migration reference: `last_human_touched_at` column 65
  (Migration 063 added the AI-state side: sessions.last_finish_reason)