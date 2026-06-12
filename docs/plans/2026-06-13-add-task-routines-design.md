# Add Task — Standard vs Routine picker (with full routines subsystem)

**Status:** Approved (brainstorming complete 2026-06-13)
**Owner:** Full-stack (Zig backend + Vue 3 + TypeScript desktop app)
**Depends on:** Existing `workspace_item_tasks` (Migration 034), existing chat worker pipeline (`workflow.zig`), existing session/SSE infrastructure.

## Goal

The green `+` Add Task button on a workspace item currently creates a default-named task that immediately routes the user to a chat. The user wants the button to surface a small picker with two options:

1. **Standard** — current behavior. A chat session is created and bound to the task.
2. **Routine** — a cron-scheduled task that, when fired, pushes the routine's `initial_prompt` into its session and runs the LLM via the existing chat worker pipeline.

A routine is a `task_type='routine'` task (mixed into the same list as standard tasks, distinguished by a small clock icon), with a 1:1 `routines` row holding the schedule and run state. Run history is the session's message history (the same session the task already owns — `task.id == session_id` is an invariant in this codebase). A "Run now" button manually fires the routine on demand.

## Decisions locked during brainstorming

1. **Scope = full routines subsystem** (UI + scheduler + executor). One plan to ship a working feature.
2. **Data model location = routines are a TYPE of task** (option A from brainstorming). A `task_type` column on `workspace_item_tasks` and a 1:1 `routines` table.
3. **Session model = reuse the existing session** (option α). `task.id == session_id` is preserved; each fire pushes a new user-style message into the same session. Run history = scroll the session's messages.
4. **Scheduling model = presets + custom cron (A3)**. UI offers preset chips (Every 5 min / 30 min / hour / 6h / Daily at HH:MM / Weekdays at HH:MM / Weekly on Monday / Monthly on the 1st) and a "Custom (cron expression)" toggle revealing a 5-field cron text input with validation. Stored as a cron string in DB either way.
5. **Manual start = yes.** A "Run now" play-icon button on every routine task row fires the routine immediately and navigates to its session.
6. **Scheduler = in-process polling loop (Approach 1).** A `Scheduler.zig` module inside the main `nalar` process, polling `routines WHERE enabled=1 AND next_run_at <= now` every 5s and spawning a fresh sub-process per fire. Matches the project's "one binary, one process" architecture.
7. **Output destination = the routine's session.** The chat view for the routine's task shows the run history inline. No separate "runs/log" UI.

## Data model

### Migration (add to `src/ai_workflow/tui/migration.zig`)

```sql
-- Add task_type column to existing workspace_item_tasks table.
ALTER TABLE workspace_item_tasks ADD COLUMN task_type TEXT NOT NULL DEFAULT 'standard';

-- Create the routines table (1:1 with workspace_item_tasks.id).
CREATE TABLE IF NOT EXISTS routines (
    id TEXT PRIMARY KEY,
    task_id TEXT NOT NULL UNIQUE,
    schedule TEXT NOT NULL,            -- 5-field cron expression
    initial_prompt TEXT NOT NULL,     -- sent to the LLM on every fire
    enabled INTEGER NOT NULL DEFAULT 1,
    last_run_at DATETIME,             -- nullable
    next_run_at DATETIME NOT NULL,    -- computed from schedule, polled by the scheduler
    last_status TEXT,                 -- 'success' | 'failed' | 'running' | NULL
    last_error TEXT,                  -- last error message, NULL on success
    created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
    updated_at DATETIME DEFAULT CURRENT_TIMESTAMP,
    FOREIGN KEY (task_id) REFERENCES workspace_item_tasks(id) ON DELETE CASCADE
);

-- Index for the polling query.
CREATE INDEX IF NOT EXISTS idx_routines_enabled_next_run
    ON routines(enabled, next_run_at);
```

### Backwards compatibility

- `task_type` defaults to `'standard'` for every existing row. No data backfill required.
- The `routines` table starts empty. No pre-existing routines.
- All existing task endpoints and the chat view keep working unchanged for standard tasks.

### Cascade / cleanup

- Deleting a routine task (via existing `DELETE /api/workspaces/.../tasks/:tid`) cascades to the `routines` row via `ON DELETE CASCADE`.
- Deleting a `routines` row directly (not currently exposed via API) is a backend-admin operation; no app-level handler needed for v1.

## Backend module layout

New files under `src/ai_workflow/tui/routines/`:

| File | Responsibility |
|---|---|
| `model.zig` | `Routine` struct, `RoutineStatus` enum (`disabled`/`enabled`), `RoutineRunStatus` enum (`success`/`failed`/`running`/null), DB read/write helpers. |
| `cron.zig` | 5-field cron parser + `nextFireTime(expr, after) !i64` (unix nanos). Validates expressions at insert time; rejects invalid syntax with a clear error. |
| `fire.zig` | `fireRoutine(allocator, db, io, task_id) !void` — the per-fire work (Section 4). |
| `Scheduler.zig` | `Scheduler.start(allocator, db, io)` and `Scheduler.run(io)` — the polling loop (Section 3). Spawns `bin/nalar-routine-fire --id <id>` per fire. |

New file under `src/ai_workflow/tui/routines/bin/`:

- `nalar-routine-fire.zig` — tiny sub-process that loads the routine by id, calls `fireRoutine`, exits with code 0 on success / 1 on failure. Built as a separate binary target (`zig build routine-fire`).

Modified files:

| File | Change |
|---|---|
| `src/ai_workflow/tui/migration.zig` | Add new `MigrationNNNAddRoutines` struct. |
| `src/ai_workflow/tui/startup.zig` | After DB is ready, call `Scheduler.start(...)`. |
| `src/ai_workflow/tui/llm_history.zig` | `Task` struct gains `task_type: []const u8` and an inline `routine: ?RoutineMeta = null` field. |
| `src/ai_workflow/tui/http_handlers/tasks_list.zig` | Response includes `task_type` and (for routines) inline routine metadata. |
| `src/ai_workflow/tui/http_handlers/workspace_item_tasks_create.zig` | Body accepts `task_type` and (for routines) `schedule`, `initial_prompt`, `enabled`. Creates routine row in the same transaction. |
| `src/ai_workflow/tui/http_handlers/workspace_item_tasks_update.zig` | Body accepts routine fields; recomputes `next_run_at` if `schedule` changed. |
| `build.zig` | New `routine-fire` install target. |

New HTTP handler files:

| File | Endpoint |
|---|---|
| `src/ai_workflow/tui/http_handlers/routines_run.zig` | `POST /api/workspaces/:w/items/:i/tasks/:tid/run` — manual fire. |

## Scheduler mechanics

- `Scheduler.zig` is started once by `startup.zig` after the migration has run and the HTTP server is bound.
- Owns an `Io.sleep` loop: `try std.Io.sleep(io, .{ .seconds = 5 }, .real)`.
- Each tick:
  ```sql
  SELECT id FROM routines
   WHERE enabled = 1
     AND next_run_at <= datetime('now')
     AND (last_status IS NULL OR last_status != 'running');
  ```
- For each due id, **spawn a fresh sub-process per fire** via `std.process.spawn` to `bin/nalar-routine-fire --id <id>`. This is the key design choice: a slow LLM call in one routine cannot block the polling of others, and a fire that hangs cannot stall the scheduler.
- The parent does NOT call `child.wait(io)` for fire-and-forget — the OS reaps the child when it exits. The sub-process is responsible for updating `last_run_at`, `next_run_at`, `last_status`, `last_error` directly via DB writes before exit.
- **Single-instance safety**: the sub-process claims the row atomically with `UPDATE routines SET last_status='running' WHERE id=? AND (last_status IS NULL OR last_status != 'running')` and checks the affected-row count. If 0, the row was already in `running` state — the sub-process exits with code 0 (a no-op fire).
- **Restart safety**: on `Scheduler.start`, the first action is `UPDATE routines SET next_run_at = compute_next(schedule, datetime('now')) WHERE enabled=1 AND next_run_at < datetime('now')`. Routines that were due during downtime fire within 5s of boot, not "next scheduled time after now".
- **Stuck `running` rows**: on `Scheduler.start`, also `UPDATE routines SET last_status='failed', last_error='process killed (restart detected)' WHERE last_status='running'`. Cleanly resets the state from a crashed/killed previous instance.
- **Polling precision**: 5s. Cron is minute-granular; the drift is invisible.

## Routine firing pipeline (the per-fire work)

`fireRoutine(allocator, db, io, task_id) !void` (in `fire.zig`, called by the sub-process):

1. **Load** the routine + its task (validate: routine exists, is enabled, task exists).
2. **Claim** the row atomically: `UPDATE routines SET last_status='running', updated_at=datetime('now') WHERE id=? AND (last_status IS NULL OR last_status != 'running')`. If 0 rows affected → another fire is in progress → return.
3. **Push a user-style message** into the existing session (the routine's task.id IS the session.id, by codebase invariant):
   ```
   🔁 Routine fire — <routine.name> — <YYYY-MM-DD HH:MM:SS>

   <routine.initial_prompt>
   ```
   This is a regular `INSERT INTO llm_history (role='user', ...)` so the chat view renders it as a user message with the 🔁 prefix.
4. **Invoke the LLM worker pipeline** — the same code path `workflow.zig` uses when a user sends a chat message. The worker:
   - Builds the agent prompt (system + conversation history)
   - Calls the LLM with streaming
   - Writes the assistant response to the session
   - Streams chunks to any active SSE listeners (so the user sees the response live if they're looking at the chat view)
5. **On success**: `UPDATE routines SET last_run_at=datetime('now'), next_run_at=compute_next(schedule, datetime('now')), last_status='success', last_error=NULL`.
6. **On error**: `UPDATE routines SET last_status='failed', last_error=<msg>, next_run_at=compute_next(schedule, datetime('now'))`. Routine stays enabled.

The `compute_next` helper is `cron.nextFireTime(schedule, now_unix_nanos)`. Same function is used at insert time and on schedule-update.

## API surface

### Modified endpoints

`GET /api/workspaces/:w/items/:i/tasks` — response items gain:
```json
{
  "id": "...",
  "name": "...",
  "workspace_item_id": "...",
  "session_id": "...",
  "task_type": "routine",        // NEW — 'standard' or 'routine'
  "routine": {                    // NEW — present iff task_type === 'routine'
    "schedule": "*/5 * * * *",
    "initial_prompt": "...",
    "enabled": 1,
    "last_run_at": "2026-06-13 04:55:00" | null,
    "next_run_at": "2026-06-13 05:00:00",
    "last_status": "success" | "failed" | "running" | null,
    "last_error": null | "..."
  },
  "created_at": "...",
  "updated_at": "..."
}
```

`POST /api/workspaces/:w/items/:i/tasks` — body now accepts:
```json
{
  "name": "Daily standup",
  "description": "optional",
  "task_type": "routine",         // NEW — optional, default "standard"
  "schedule": "0 9 * * 1-5",     // REQUIRED if task_type === 'routine'
  "initial_prompt": "...",        // REQUIRED if task_type === 'routine'
  "enabled": true                 // OPTIONAL, default true
}
```
For `task_type='routine'`, the server:
- Validates the cron expression via `cron.validate(schedule)`. Returns 400 with a clear error on invalid syntax. Bad cron never enters the DB.
- Creates the `workspace_item_tasks` row (with `task_type='routine'`) and the `routines` row in a single transaction.
- Computes `next_run_at = cron.nextFireTime(schedule, now)` and stores it.
- The session is created exactly the same way as for standard tasks (current `create_task` flow). The `task.id == session.id` invariant is preserved.

`PATCH /api/workspaces/:w/items/:i/tasks/:tid` — body accepts routine fields (`schedule`, `initial_prompt`, `enabled`, `name`, `description`). When `schedule` changes, `next_run_at` is recomputed.

`DELETE /api/workspaces/:w/items/:i/tasks/:tid` — unchanged. `ON DELETE CASCADE` removes the routine row.

### New endpoint

`POST /api/workspaces/:w/items/:i/tasks/:tid/run` — manually fires the routine.
- Body: empty.
- Returns: `{ "session_id": "<task.id>" }` on success.
- 409 if the routine is disabled or another fire is in progress.
- 404 if the task is not a routine.
- The handler spawns `bin/nalar-routine-fire --id <tid>` asynchronously and returns immediately (the same sub-process path the scheduler uses). The frontend navigates to `?view=task&task=<taskId>&session=<taskId>` (the routine's session, which is the task id).

## Frontend UX

### `AddTaskPickerDialog.vue` (NEW)

Shown when the user clicks the green `+` button. Modal with two large cards:

| Card | Icon | Description |
|---|---|---|
| **Standard Chat** | 💬 | "An interactive chat with the AI. You send messages, the AI responds." |
| **Routine** | 🕒 | "A scheduled task. The AI runs your prompt on a schedule; you see the runs in the chat." |

Clicking a card emits `pick: ['standard' | 'routine']` and closes. The parent (`Sidebar.vue`) routes to the appropriate creation flow.

### `AddTaskDialog.vue` (EXISTING — rewire)

Already exists in `src/apps/desktop/src/components/AddTaskDialog.vue` but is currently imported nowhere. Wire it up for the **standard** path: emits `(name, description?)` and the parent POSTs to the modified endpoint with `task_type: 'standard'`.

### `AddRoutineDialog.vue` (NEW)

Modal with the form for creating a routine:

- **Name** (text input, required)
- **Description** (text input, optional)
- **Initial prompt** (textarea, required, 3+ rows) — what the LLM sees on every fire
- **Schedule** — preset chips + custom toggle:
  - Preset chips: Every 5 min / Every 30 min / Every hour / Every 6 hours / Daily at 9:00 AM (with a time picker) / Weekdays at 9:00 AM (with a time picker) / Weekly on Monday (with a weekday picker) / Monthly on the 1st (with a day picker)
  - Each preset maps to a known cron expression
  - "Custom (cron expression)" toggle at the bottom of the schedule section → reveals a text input for `* * * * *` with a "next 5 fire times" preview and inline validation
- **Enabled** (toggle, default on)
- **Cancel** / **Create Routine** buttons

Submits via the modified POST with `task_type='routine'`. On 400 (bad cron), shows the error inline under the schedule input.

### `EditRoutineDialog.vue` (NEW)

Same as `AddRoutineDialog.vue` prefilled with the routine's current values. Opened from the rename/edit affordance on routine task rows.

### `WorkspaceItemTask.vue` (MODIFY)

When `task.task_type === 'routine'`:
- Render a small **clock icon** instead of the bullet (different visual to distinguish from standard tasks)
- Add a **"Run now"** play-icon button on hover, between rename and delete. Clicking calls `workspacesStore.runRoutine(workspaceId, itemId, taskId)` which POSTs to `/run` and routes to the chat view for the session.
- **Status dot** next to the name:
  - Green when `last_status === 'success'`
  - Red when `last_status === 'failed'`
  - Spinning yellow when `last_status === 'running'`
  - Gray when `last_status` is `null` (never fired)
- **Tooltip on the clock icon** showing the next scheduled fire time, e.g. "Next: in 23 min (15:00)"

When `task.task_type === 'standard'`: unchanged.

### `WorkspaceItem.vue` (MODIFY)

No changes. Click on a routine task still emits `selectTask` → Sidebar routes to the chat view for the session. The chat view is the same `ChatView.vue` for both task types — the run history is just messages in the session.

### `Sidebar.vue` (MODIFY)

- New `addTaskPickerOpen` ref and `addTaskPickerItem` ref for the picker dialog
- New `addRoutineDialogOpen` ref
- `handleAddTask` becomes:
  ```ts
  const handleAddTask = (workspaceId: string, item: WorkspaceItem) => {
    addTaskPickerItem.value = { workspaceId, item }
    addTaskPickerOpen.value = true
  }
  ```
- New `handleAddTaskPick` opens `AddTaskDialog` (standard) or `AddRoutineDialog` (routine)
- New `handleRunRoutine` calls `workspacesStore.runRoutine(...)` and navigates
- The existing fast-path (default name + immediate create) is removed

## Frontend state management

### `Task` interface (in `stores/workspaces.ts`)

```ts
export interface RoutineMeta {
  schedule: string
  initial_prompt: string
  enabled: boolean
  last_run_at: string | null
  next_run_at: string
  last_status: 'success' | 'failed' | 'running' | null
  last_error: string | null
}

export interface Task {
  id: string
  name: string
  description?: string
  task_type: 'standard' | 'routine'  // NEW — default 'standard' for old data
  routine?: RoutineMeta               // NEW — present iff task_type === 'routine'
  completed?: boolean                  // existing — still unused by UI
  createdAt?: Date
  updatedAt?: Date
}
```

### `workspacesStore` actions (MODIFY)

- `addTask(workspaceId, itemId, { name, description, taskType, routine? })` — modified signature; passes through to the API
- New `runRoutine(workspaceId, itemId, taskId)` — POSTs to `/run`, calls `setActiveTask(taskId)`, router replace
- New `updateRoutine(workspaceId, itemId, taskId, fields)` — PATCH wrapper
- `deleteTask`, `renameTask`, `toggleTask`, `loadMoreTasks` — unchanged (task-type-agnostic)

### `api/index.ts` (MODIFY)

- `createTask(workspaceId, itemId, { name, description, taskType, routine? })` — modified signature
- New `runRoutine(workspaceId, itemId, taskId)` — POSTs to `/api/.../tasks/:tid/run`
- `updateTaskSimple(taskId, fields)` — accept routine fields in `fields`
- `getTasks`, `deleteTask` — unchanged signatures; `getTasks` response now includes `task_type` and `routine`

## Error handling & observability

| Failure mode | Behavior |
|---|---|
| Routine fire fails (LLM error, network drop, etc.) | `last_status='failed'`, `last_error=<msg>`, `next_run_at` advances. Routine stays enabled. |
| Long-running fire | `last_status='running'` is set when the sub-process is spawned. A second fire-while-running is **skipped** (one-at-a-time per routine, enforced by the atomic UPDATE in step 2 of the firing pipeline). |
| Scheduler crash / restart | On boot, recompute all `next_run_at` and reset stuck `running` rows to `failed`. Due routines fire within 5s. |
| Bad cron expression at create time | 400 with a clear error. Bad cron never enters the DB. |
| Bad cron expression recomputed at update time | Same — PATCH returns 400. |
| Sub-process crashes (SIGKILL) | The `last_status='running'` row is reset on next scheduler boot (the stuck-running check). |
| User disables a routine | `enabled=0`. The scheduler skips it. Existing `next_run_at` is preserved; flipping back to `enabled=1` resumes the schedule without a re-fire. |

**User visibility**:
- The chat view for the routine's session shows the run messages inline (user message with 🔁 prefix, then assistant response). Standard chat UX.
- The task row's status dot reflects the last run.
- The clock-icon tooltip shows the next scheduled fire time.
- No new "logs" view, no notification system, no toasts.

## Testing strategy

### Backend unit tests

- `cron.zig` `nextFireTime` for 20+ expressions: every minute, hourly, daily, weekdays, weekends, month boundaries, Feb 29, invalid input. Property: result is always in the future.
- `cron.zig` `validate`: rejects malformed expressions with parseable error messages.
- `fire.zig` with a mocked LLM worker: verify a user-role message is inserted with the right 🔁 prefix + initial_prompt; verify `last_status` and `next_run_at` are updated; verify failure path sets `last_error` and `last_status='failed'`.
- `fire.zig`: verify the atomic claim rejects a second concurrent fire.
- The new migration is idempotent and the `task_type` default is `'standard'` for all existing rows.
- `routines_run.zig` HTTP handler: 404 for non-routine, 409 for disabled, 200 + session_id for success.

### Backend integration tests

- Start the scheduler in a test process, insert a routine with `next_run_at` in the past, assert that within 6s the sub-process has been spawned and the session has a new user message.
- Restart-safety: start a scheduler, kill it (don't let it update `next_run_at`), start a new scheduler, assert the due routine fires within 5s of boot.
- Stuck-running reset: insert a routine with `last_status='running'`, start the scheduler, assert the row is reset to `failed` with `last_error='process killed (restart detected)'`.

### Frontend unit tests

- `AddTaskPickerDialog.spec.ts` — both buttons visible, both clickable, click emits the right `pick` event.
- `AddRoutineDialog.spec.ts` — preset selection populates the hidden cron field, custom toggle reveals the cron input, validation rejects bad cron, submit fires the right API call with the expected body.
- `EditRoutineDialog.spec.ts` — opens prefilled, submit PATCHes the right fields.
- `WorkspaceItemTask.spec.ts` (extend existing) — when `task.task_type='routine'`, renders the clock icon, the Run Now button, the status dot, and the next-run tooltip. Run Now click fires `runRoutine` and navigates.

### E2E

- Open the app, click the green `+` on a workspace item, pick "Routine", fill the form with "Every 5 min" preset, save. The routine appears in the task list with a clock icon and a "Next: 5 min" tooltip. Click "Run now". Within ~5s, a new user message with 🔁 prefix appears in the chat view, followed by the assistant response. The status dot turns green.

## Migration & rollout

- The new migration runs on `nalar` startup before the HTTP server binds (same as every other migration).
- Schema is additive: no destructive changes to existing tables.
- The scheduler starts automatically on boot; no flag to enable.
- The sub-process binary `bin/nalar-routine-fire` is installed alongside `nalar` by `zig build install:linux`.
- If the new migration fails, the process refuses to start (same as any migration failure today).
- Rollback path: drop the `routines` table, drop the `task_type` column. Routines created during the rollout would lose their schedule and become standard tasks (recoverable from the session's history, since the run messages are still in the session).

## File changes summary

### New files (frontend)

- `src/apps/desktop/src/components/AddTaskPickerDialog.vue`
- `src/apps/desktop/src/components/AddRoutineDialog.vue`
- `src/apps/desktop/src/components/EditRoutineDialog.vue`
- `src/apps/desktop/src/__tests__/AddTaskPickerDialog.spec.ts`
- `src/apps/desktop/src/__tests__/AddRoutineDialog.spec.ts`
- `src/apps/desktop/src/__tests__/EditRoutineDialog.spec.ts`

### Modified files (frontend)

- `src/apps/desktop/src/components/WorkspaceItemTask.vue` — clock icon, Run Now, status dot, tooltip
- `src/apps/desktop/src/components/Sidebar.vue` — picker open state, route to AddTask/AddRoutine, runRoutine handler
- `src/apps/desktop/src/stores/workspaces.ts` — `Task` interface, `addTask` signature, `runRoutine`, `updateRoutine`
- `src/apps/desktop/src/api/index.ts` — `createTask` signature, `runRoutine` new

### New files (backend)

- `src/ai_workflow/tui/routines/model.zig`
- `src/ai_workflow/tui/routines/cron.zig`
- `src/ai_workflow/tui/routines/fire.zig`
- `src/ai_workflow/tui/routines/Scheduler.zig`
- `src/ai_workflow/tui/routines/bin/nalar-routine-fire.zig`
- `src/ai_workflow/tui/http_handlers/routines_run.zig`
- `src/ai_workflow/tui/routines/cron_test.zig`
- `src/ai_workflow/tui/routines/fire_test.zig`
- `src/ai_workflow/tui/routines/scheduler_test.zig`
- `src/ai_workflow/tui/http_handlers/routines_run_test.zig`

### Modified files (backend)

- `src/ai_workflow/tui/migration.zig` — new migration struct
- `src/ai_workflow/tui/startup.zig` — start the scheduler
- `src/ai_workflow/tui/llm_history.zig` — `Task` struct gains `task_type` and `routine`
- `src/ai_workflow/tui/http_handlers/tasks_list.zig` — response includes routine metadata
- `src/ai_workflow/tui/http_handlers/workspace_item_tasks_create.zig` — accept `task_type` + routine fields
- `src/ai_workflow/tui/http_handlers/workspace_item_tasks_update.zig` — accept routine fields, recompute `next_run_at`
- `build.zig` — `routine-fire` install target

## Open questions

None. All architectural decisions locked during brainstorming (Sections 1-10 of the brainstorming transcript). Implementation plan (bite-sized tasks) will follow in `docs/superpowers/plans/2026-06-13-add-task-routines.md`.
