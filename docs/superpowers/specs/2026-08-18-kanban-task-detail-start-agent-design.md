# Kanban "Task details — Start agent" — Design

> **For agentic workers:** This is a design spec. After the user approves, the next step is to invoke the `superpowers:writing-plans` skill to create a bite-sized implementation plan.

**Goal:** Add a secondary action to the kanban **Task details** dialog (edit mode only) — **Start agent** — that kicks off an LLM worker on the task's existing session **without queueing a new user message**. The worker resumes / starts on whatever context is already in the session. The button is **disabled when a worker is already running for that session**. On success the dialog closes and the user stays on the kanban; the worker runs in the background.

**Architecture:**
- **Backend** — add a dedicated endpoint `POST /api/workspaces/:workspace_id/items/:item_id/tasks/:task_id/start_agent`. It validates the task exists and no worker is currently running, then submits a new event `RunParamsTrigger` to the worker pool with an empty `queue_message` and a `skip_initial_queue_message: true` flag. The workflow's `runAgenticMultiStepnew` checks the flag and skips the initial `insertQueueMessage` call, so the agent loop runs against the existing chat history alone.
- **Frontend** — extend `KanbanTaskDetailDialog.vue` (edit mode) with a `▶ Start agent` button that injects the existing `processingState` map (provided by `App.vue`) and disables itself when `processingState[task.id] === true`. Clicking emits a new `start-agent` event; the host (`KanbanView.vue`) calls a new store action `startAgentOnTask(...)` that delegates to a new `api.startAgentOnTask(...)` helper which POSTs to the new endpoint.
- **No backend endpoint reuse** — we deliberately do NOT reuse `POST /api/llm/session` because that endpoint always inserts a queue message and creates the session row; the new endpoint's contract is different ("trigger worker on existing session, no message").

**Tech Stack:** Vue 3 + TypeScript + Pinia + Vitest (`@vue/test-utils`) on the frontend; Zig 0.16 (existing modules) on the backend. No new dependencies.

## 1. Why now — the problem

Today, starting an agent on an existing kanban task is a multi-step detour:

1. Open the kanban. Find the task card.
2. **Click the card** → the chat view dialog opens (empty — no assistant is running yet).
3. **Re-type** the task intent into the chat box (often "what the user wrote in the title/description five minutes ago").
4. Press Enter → the agent runs.

For tasks where the title+description *is* the prompt (the dominant case for standard tasks on a kanban), step 3 is pure toil — the user is paying a re-typing tax. The Create-mode **Create task & run agent** button (plan `2026-08-06-kanban-create-task-run-agent`) already collapses this for brand-new tasks. The user's request completes the parity for existing tasks: a button that does the same primitive (kick off the worker) without leaving the kanban.

Equally important: the button must be **safe to spam**. If a worker is already running for a task's session, naively calling `/api/llm/session` would queue a *second* user message — the user would not expect "Start agent" to append another turn on top of an in-flight one. The disable-when-running rule makes the affordance safe and discoverable: the user sees the button greyed out and understands "an agent is already running on this task".

The new endpoint (vs. reusing `/api/llm/session`) is a deliberate API-shape choice. `/api/llm/session` has session-creation semantics: it inserts the session row and ALWAYS queues a message. Our new primitive is fundamentally different — "trigger worker on existing session, no new message" — and deserves a dedicated endpoint with its own contract.

## 2. Current state — what exists today

**Frontend (existing primitives we re-use)**
- `KanbanTaskDetailDialog.vue` (mode `'edit'`) — collects `name`, `description`, `tags`, `cwd` (per-task), and the `unattended` toggle. Footer has **Cancel** + **Save**. The dialog is purely presentational — emits events, no API calls.
- `KanbanView.vue` — `handleTaskDetailSave` (edit-mode save) and `handleCreateTaskSave` (create-mode handlers including `create-and-run`). Mounts the dialog at lines 1166 and 1184 with two separate instances (edit + create).
- `workspacesStore.runAgentOnNewTask(...)` (`stores/workspaces.ts:2746`) — wraps `api.sendChatMessage(taskId, queueMessage, cwdSession, imageUrls, selectedProfile, isAutoRetryUntilStop)`. Used by the create-and-run path. **We do NOT add a sibling `runAgentOnTask` for the new endpoint** — the store action is renamed/restructured to match the new wire.
- `App.vue` (`App.vue:10`) — owns the `processingState` map (`Record<sessionId, boolean>`) and `provide('processingState', ...)`. Populated by:
  - SSE worker events (`worker` channel): created/updated → add; deleted → remove.
  - Initial `GET /api/workers` fetch on every (re)connect of the SSE bus — covers server restart / network drop.

**Backend (no changes to existing endpoints; we add a new one)**
- `POST /api/llm/session` (`session_create.zig`) — existing endpoint, idempotent on `session_id == task.id`, ALWAYS inserts a queue message. Not reused here.
- `POST /api/.../tasks/:task_id/run` (`routines_run.zig`) — routine-only endpoint. Returns 404 for non-routine tasks. Not reused here.
- `di.emit_run_agent(input)` (`root.zig:105`) — the existing entry point that dupes string fields into `self.allocator` and emits `RunParamsNew` on the `ai_worker_flow` channel. The callback handler (`CallbackAiWorkerFlow.callback` in `workflow.zig:112`) picks it up and calls `runAgenticMultiStepnew`.
- `runAgenticMultiStepnew` (`workflow.zig:413`) — the agent loop. It always calls `insertQueueMessage` (lines 511-520) before the loop. For the new "trigger without message" primitive we need to **skip that initial insertQueueMessage**.
- `RunParamsNew` struct (`workflow.zig:1556`) — payload for the worker event. Currently has `message`, `cwd`, `body`, `allowed_tools`, `image_urls`, `selected_profile_model`, `is_auto_retry_until_stop`, etc. **We add a new field `skip_initial_queue_message: bool = false`** that the workflow checks.

**Project invariant:** `task.id == session_id` (Migration 052 dropped the redundant `workspace_item_tasks.session_id` column; session_create.zig uses `task.id` as the primary key for sessions).

## 3. Design — UX, wire, sequencing

### 3.1 UX — the new button

```
┌────────────────────────────────────────┐
│ Task details                       [✕] │
├────────────────────────────────────────┤
│ Task name                              │
│ [new feature AgentMode           ]     │
│ ... description / tags / cwd row ...   │
├────────────────────────────────────────┤
│ Unattended mode               [● ◯]    │
├────────────────────────────────────────┤
│          [Cancel] [▶ Start agent] [Save]│
└────────────────────────────────────────┘
```

- **Label**: `▶ Start agent` (right-aligned, between Cancel and Save). The `▶` play-icon glyph matches the existing `▶ Create task & run agent` button (line 1501 of `KanbanTaskDetailDialog.vue`) so users learn one symbol for "kick off the worker".
- **Style**: outlined (`1px var(--color-border)`, transparent background) — *visually subordinate* to the primary `Save` button (filled gradient). Mirrors the style of `Create task & run agent` (line 1493). Disabled: 0.5 opacity + cursor not-allowed.
- **Position**: actions row (`flex justify-end gap-2`), ordered:
  - `Cancel` (leftmost — destructive-leaning affordance, low-touch)
  - `▶ Start agent` (middle — secondary action)
  - `Save` (rightmost — primary, rightmost == most-likely-default per the existing pattern).
- **Visibility**: edit mode **only**. Create mode already has `▶ Create task & run agent`; rendering both would be redundant and visually noisy.
- **Disabled state**: `isWorkerRunning = inject('processingState')?.[task.id] === true`. When `true` the button is `:disabled` and a tooltip explains *"A worker is already running on this task — wait for it to finish before starting a new agent."*
- **Enabled state**: `!isWorkerRunning`. No additional gate (name length, dirty form, etc.). The button reflects the worker's worker-level running state — it does not care whether the user has edited the form.
- **Hover tooltip** (enabled): *"Trigger the agent on the existing chat context. No new message is queued — the agent resumes whatever context is already in the session."*

### 3.2 Backend — new endpoint

**Route**: `POST /api/workspaces/:workspace_id/items/:item_id/tasks/:task_id/start_agent`

**Handler file**: `src/ai_workflow/tui/http_handlers/start_agent.zig`

**Request body**: empty (the endpoint takes all inputs from the URL path).

**Response**:
- `200 OK` — `{"success":true,"session_id":"<task_id>","status":"triggered"}`
- `400 Bad Request` — missing `task_id` in path
- `404 Not Found` — task does not exist (or workspace/item doesn't contain it)
- `409 Conflict` — a worker is already running for this session (mirrors `routines_run.zig`'s `AlreadyRunning` → 409 mapping)
- `500 Internal Server Error` — singleton not initialized, DB failure, or `emit_run_agent` failure

**Backend flow**:
1. Extract `workspace_id`, `item_id`, `task_id` from path params. Validate `task_id` is non-empty (400 otherwise).
2. Look up the singleton `di` (500 if not initialized). Get the SQLite DB handle.
3. Validate the task exists in `workspace_item_tasks` for the given `(workspace_id, item_id)` pair. If not, return 404.
4. Look up the worker row for `task_id` in the `workers` table (via `isWorkerRunning` helper at `agentic_loop/is_worker_running.zig`). If a worker row exists, return 409 with `{"error":"worker already running"}`.
5. Look up the session row for `task_id` in the `sessions` table. If it doesn't exist, INSERT one (`INSERT OR IGNORE INTO sessions ... VALUES (task_id, task.name, 'active', task.cwd, CURRENT_TIMESTAMP, ...)`). This guarantees the worker can be claimed (matches `fire.fireRoutine`'s pattern).
6. Call `di.emit_run_agent(.{
     .session_id = task_id,
     .session_name = task_name,
     .queue_message = "",          // empty — no message queued
     .cwd = task.cwd ?? "",
     .body_message = "",
     .allowed_tools = "",
     .image_urls = "",
     .selected_profile_model = session.selected_profile_model ?? "",
     .is_auto_retry_until_stop = session.is_auto_retry_until_stop ?? "0",
     // NEW: route through the trigger path. The emit_run_agent
     // helper needs a way to forward this; see §3.3.
   })`. If `emit_run_agent` returns an error, map to 500.
7. Return `200 {"success":true,"session_id":task_id,"status":"triggered"}`.

### 3.3 Backend — changes to `emit_run_agent` and `RunParamsNew`

To support "trigger without message" without forking the worker pool, we thread a single new flag through:

**Step 1**: Add a field to `EmitRunAgentInput` (in `src/root.zig`):
```zig
pub const EmitRunAgentInput = struct {
    session_id: []const u8,
    session_name: []const u8,
    queue_message: []const u8,
    cwd: []const u8,
    body_message: []const u8,
    allowed_tools: []const u8,
    image_urls: []const u8,
    selected_profile_model: []const u8,
    is_auto_retry_until_stop: []const u8,
    // NEW: when true, the worker skips the initial insertQueueMessage.
    // Used by the start_agent endpoint to trigger a worker on an
    // existing session without queueing a new user message. The
    // existing create_session / kanban_create path leaves this false
    // (default) — same behaviour as today.
    skip_initial_queue_message: bool = false,
};
```

**Step 2**: Add the same field to `RunParamsNew` (in `src/ai_workflow/tui/agentic_loop/workflow.zig`):
```zig
pub const RunParamsNew = struct {
    parent_session_id: []const u8,
    session_id: []const u8,
    message: []const u8,
    cwd: []const u8,
    body: []const u8,
    allowed_tools: []const u8,
    is_sub_agent: bool = false,
    image_urls: []const u8 = "",
    selected_profile_model: []const u8 = "",
    inherited_context: []const u8 = "",
    sub_agent_overrides: ?SubAgentOverrides = null,
    is_auto_retry_until_stop: []const u8 = "",
    // NEW: when true, skip the initial insertQueueMessage call.
    // See start_agent.zig for the user-facing endpoint.
    skip_initial_queue_message: bool = false,
};
```

**Step 3**: Thread the flag through `emit_run_agent.run` (the concurrent task in `root.zig:133`) and the event-emit at line 173:
```zig
event_buss.emit(agentic_loop_mod.RunParamsNew, "ai_worker_flow", .{
    .parent_session_id = sid,
    .session_id = sid,
    .message = qmsg,
    .cwd = cwd,
    .body = bmsg,
    .allowed_tools = atools,
    .is_sub_agent = false,
    .image_urls = iurls,
    .selected_profile_model = spm,
    .is_auto_retry_until_stop = iaur,
    .skip_initial_queue_message = siqm,  // NEW
});
```
(With the corresponding dup+free for `siqm` in `emit_run_agent`'s synchronous section, mirroring the existing pattern.)

**Step 4**: In `runAgenticMultiStepnew` (workflow.zig), wrap the existing `insertQueueMessage` call (lines 510-520) in a flag check:
```zig
// Queue the initial message — unless the caller asked us to skip it
// (start_agent endpoint, which triggers a worker on an existing session
// without queueing a new user message).
if (!params.skip_initial_queue_message) {
    try insertQueueMessage(InsertQueueMessageInput{
        .allocator = parent_allocator,
        .db = db,
        .logger = logger,
        .session_id = copy_session_id,
        .message = copy_message,
        .image_url = copy_image_urls,
        .event_bus = event_bus,
        .is_emit_sse = true,
    });

    logger.infoFmt(
        "[CHECKPOINT] initial message queued session_id={s} retry_budget=10",
        .{copy_session_id},
    );
} else {
    logger.infoFmt(
        "[CHECKPOINT] trigger mode — skipping initial queue_message session_id={s}",
        .{copy_session_id},
    );
}
```

The agent loop body that follows is **unchanged** — it drains `queued_messages` each iteration. When `skip_initial_queue_message` is true, the first iteration finds no queued messages and processes the existing chat history normally. The LLM sees whatever messages are already in `messages` and responds.

**Important**: The agent's behaviour with no queued messages and no chat history (a brand-new task) is determined entirely by the system prompt + LLM. The LLM will typically produce a clarification response ("what would you like me to do?"). This is documented and acceptable for v1 — see §3.5.

### 3.4 Frontend — new emit

The dialog gains a new emit alongside the existing `save`, `update-unattended`, `update-cwd`:

```ts
'start-agent': [
  payload: {
    taskId: string  // the task whose worker should start; == session_id
  },
]
```

### 3.5 Sequencing — host (`KanbanView.vue`)

`KanbanView.vue` gains a new handler, wired to the dialog's `@start-agent`:

```ts
const handleStartAgent = async (payload: { taskId: string }) => {
  if (!activeTaskDetailId.value || activeTaskDetailId.value !== payload.taskId) return
  startAgentError.value = null
  startAgentBusy.value = true
  try {
    const result = await workspacesStore.startAgentOnTask(
      props.workspaceId,
      props.itemId || props.item.id,
      payload.taskId,
    )
    if (result && result.status === 'triggered') {
      // Background worker started successfully. Close the dialog and
      // stay on the kanban — the user can click the task card to open
      // the chat view if they want to watch the agent work.
      showTaskDetail.value = false
      activeTaskDetailId.value = null
    } else if (result) {
      startAgentError.value = `Agent didn't start — status: ${result.status}`
    } else {
      startAgentError.value = 'Agent didn\'t start — network error.'
    }
  } catch (err) {
    console.error('Failed to start agent:', err)
    startAgentError.value = err instanceof Error ? err.message : String(err)
  } finally {
    startAgentBusy.value = false
  }
}
```

A new `startAgentError` ref (replaces the silent failure — keeps the dialog open with the errorMessage banner visible). A `startAgentBusy` ref prevents double-clicks during the in-flight POST (independent of the disabled-when-running rule, which only catches the cross-session race). On success the dialog closes; the user stays on the kanban (no chat-view navigation — matches the create-and-run flow per plan `2026-08-06-no-need-go-chatview`).

### 3.6 Store — new action

`workspacesStore.startAgentOnTask(workspaceId, itemId, taskId)` calls the new endpoint directly. No payload (the endpoint takes all inputs from the URL path).

```ts
// POST /api/workspaces/:ws/items/:i/tasks/:task_id/start_agent
// Triggers a worker on the existing session — no queue_message
// inserted. Returns the backend status so the host can decide
// whether to close the dialog.
async function startAgentOnTask(
  workspaceId: string,
  itemId: string,
  taskId: string,
): Promise<{ status: string } | undefined> {
  try {
    return await api.startAgentOnTask(workspaceId, itemId, taskId)
  } catch (err) {
    console.error('Failed to start agent on task:', err)
    return undefined
  }
}
```

### 3.7 API helper — new

`api.startAgentOnTask(workspaceId, itemId, taskId)` mirrors the existing `api.runRoutine` pattern (`api/index.ts:1006`):

```ts
/**
 * Trigger an LLM worker on an existing task's session WITHOUT queueing
 * a new user message. For tasks with chat history, the agent resumes
 * the conversation. For tasks with no chat history, the agent responds
 * based on its system prompt alone (typically a clarification message).
 *
 * 200: { success: true, session_id, status: 'triggered' }
 * 404: task does not exist (or doesn't belong to this workspace/item)
 * 409: a worker is already running for this session
 * 500: server error
 */
export async function startAgentOnTask(
  workspaceId: string,
  itemId: string,
  taskId: string,
): Promise<{ success: boolean; session_id?: string; status?: string }> {
  return await apiFetch<{ success: boolean; session_id: string; status: string }>(
    `/workspaces/${workspaceId}/items/${itemId}/tasks/${taskId}/start_agent`,
    { method: 'POST' },
  )
}
```

### 3.8 No-history behaviour (pure trigger)

If the user clicks `▶ Start agent` on a task that has no chat history, the backend:
- Inserts (or upserts) the sessions row (mirrors `fireRoutine`'s pre-insert)
- Emits `RunParamsTrigger` with empty `queue_message` and `skip_initial_queue_message: true`
- The workflow's loop enters iteration 1, drains the (empty) queue, finds no new messages
- The LLM processes the existing chat history (empty) and responds based on the system prompt

The LLM's response in this case is up to the system prompt. Empirically, the project's system prompt steers the LLM toward an acknowledgement + offer-to-help response, but the exact wording is out of scope for this PR.

**UX**: the dialog closes, the worker runs in the background, and the user can click the task card to open the chat view and see what the agent produced. If the agent's no-history response isn't useful, the user can manually type the intended prompt into the chat view (the existing chatview flow).

This is the documented behaviour for v1. Follow-up: if users complain, we can add a fallback that uses `task.name + '\n\n' + task.description` as the queue_message for no-history tasks. **Out of scope here.**

### 3.9 Disabled-state race — why we don't need more

The disabled check is `processingState[task.id] === true`. Race scenarios:

| Scenario | Behaviour |
|----------|-----------|
| User A opens dialog, worker not running, clicks Start. SSE `worker` event arrives 100 ms later (created event) → `processingState[task.id] = true`. | POST is in flight; backend queues the trigger; SSE adds the worker to the map. No double-trigger — the user only clicked once. |
| Worker finishes between dialog open and click (SSE `deleted` event arrives). | Map clears, button enables, user clicks. POST triggers a new worker. Correct. |
| Worker is running (map says true). User clicks anyway via keyboard shortcut. | `:disabled` prevents the click on a focused button. Even if `disabled` is overridden by the browser, the host handler is gated by `startAgentBusy.value` (one-shot re-entrancy guard). |

A long-running POST that succeeds mid-flight (the SSE `worker created` event arrives before the POST returns) **does not** cause a double-trigger — the new endpoint validates "no worker running" atomically via a DB query BEFORE calling `emit_run_agent`. Concurrent calls would be a backend concern, not a UX concern.

### 3.10 Error handling — partial-success UX

| Outcome | UI behaviour |
|---------|---------------|
| POST returns `success: true, status: 'triggered'` | Dialog closes (matches create-and-run). Background worker runs. |
| POST returns `success: false` (any status) or the fetch throws | Dialog stays open. The dialog's existing `errorMessage` prop (already wired in create-mode — line 1192) is set via a new `startAgentError` ref. User can retry. |
| Backend 404 — task doesn't exist | Error message: "Task no longer exists." Dialog closes (user can't retry a deleted task). |
| Backend 409 — worker already running | Error message: "A worker is already running on this task. Wait for it to finish." Dialog stays open (the SSE `worker deleted` event will eventually flip the disabled state and the user can retry). |
| Backend 500 — singleton not initialized, DB failure, emit_run_agent failure | Error message surfaces the backend error. Dialog stays open. User can retry. |

### 3.11 The mousedown pattern from `commitTagsDraftOnSaveMouseDown` is NOT applied here

The Save button uses a `mousedown` handler to commit any draft tag before click logic (`commitTagsDraftOnSaveMouseDown` at line 780). The Start agent button does **not** need this — it doesn't read form state, it reads `task` from props. The drafts don't affect whether the button is enabled or what it emits.

## 4. Out of scope (deferred)

- **Sending task.name+description as a fallback for no-history tasks** — v1 uses pure trigger. Follow-up if users complain about empty-history behaviour.
- **Refreshing `processingState` from the backend on dialog open** — `App.vue` already re-syncs on every SSE (re)connect (line 109). For a session open for a long time before the dialog is opened, the map may be stale *only* if the SSE bus had been disconnected long enough for a worker to spawn+finish on a different nalar instance. Acceptable — clicking an enabled button when a remote worker is actually running would fail the backend 409 check (atomic DB lookup), which the host maps to a friendly error. **Defense in depth.**
- **Visualizing "Running…" text in the disabled button** — see §3.1; deferred until user feedback justifies.
- **Start-agent affordance on the kanban card itself (not just in the dialog)** — would require passing `processingState` to `KanbanCard` and re-organizing the card's row layout. The dialog is the existing entry point for editing a task; the card's click surface is reserved for opening the chat view. Out of scope.
- **A "Start unattended" combined button** — the unattended toggle is separate; the user can pre-toggle unattended mode and then click Start agent to combine (Order: 1) toggle unattended → 2) click Start agent). No combined action needed.
- **Confirmation modal "Are you sure?"** — the button is enabled at most once per idle worker-state window; the cost of an accidental click is triggering a worker on the existing context (cheap, recoverable via the chat view). No confirmation gate.

## 5. Files to touch

### Backend (3 NEW, 3 EDIT, 1 EDIT-route)

| Type | Path | Change |
|------|------|--------|
| NEW  | `src/ai_workflow/tui/http_handlers/start_agent.zig` | `startAgentHandler`: validate task exists (404), no worker running (409), call `di.emit_run_agent` with empty `queue_message` and `skip_initial_queue_message: true`. |
| NEW  | `src/ai_workflow/tui/http_handlers/start_agent_test.zig` | Mirror the structure of `routines_run_test.zig`: contract tests (route registration, error mapping, success path), inline tests on the handler's logic. |
| EDIT | `src/ai_workflow/tui/agentic_loop/workflow.zig` | Add `skip_initial_queue_message: bool = false` to `RunParamsNew`; wrap the `insertQueueMessage` call in `runAgenticMultiStepnew` with `if (!params.skip_initial_queue_message)`; update the `[CHECKPOINT]` log to reflect the new mode. |
| EDIT | `src/root.zig` | Add `skip_initial_queue_message: bool = false` to `EmitRunAgentInput`; dup+free it in the synchronous section of `emit_run_agent`; thread it through to the `RunParamsNew` emit in the concurrent task. |
| EDIT | `src/main.zig` | Register the new route: `try gs.router.post("/api/workspaces/:workspace_id/items/:item_id/tasks/:task_id/start_agent", ai_mod.http_handlers.startAgentHandler);`. |
| EDIT | `src/apps/cli/src/commands/*.zig` (optional) | Add a `start-agent` CLI command mirroring `messages`/`send`/`sessions` for parity. **Optional for v1; can skip if time-constrained.** |

### Frontend (3 NEW, 5 EDIT)

| Type | Path | Change |
|------|------|--------|
| EDIT | `src/apps/desktop/src/api/index.ts` | Add `startAgentOnTask(workspaceId, itemId, taskId)` helper. |
| EDIT | `src/apps/desktop/src/stores/workspaces.ts` | Add `startAgentOnTask(workspaceId, itemId, taskId)` action; export from `defineStore` (around line 3930). |
| EDIT | `src/apps/desktop/src/components/kanban/KanbanTaskDetailDialog.vue` | Add `inject('processingState')`; add `▶ Start agent` button + `start-agent` emit (edit mode only); add `isWorkerRunning` computed. |
| EDIT | `src/apps/desktop/src/components/kanban/KanbanView.vue` | Wire `@start-agent="handleStartAgent"`. Add `handleStartAgent` handler that calls `workspacesStore.startAgentOnTask(...)`. Add `startAgentError` ref bound to the dialog's `errorMessage` prop. |
| NEW  | `src/apps/desktop/src/__tests__/KanbanTaskDetailDialog.startAgent.spec.ts` | Behavioural (mount pattern mirrors `KanbanTaskDetailDialog.runAgent.spec.ts`): button hidden in create mode; visible in edit mode; disabled when `processingState[task.id] = true`; enabled when false / absent; click emits `start-agent` with `{ taskId }`; injecting a non-object processingState doesn't throw. |
| NEW  | `src/apps/desktop/src/__tests__/KanbanView.startAgent.spec.ts` | Behavioural: `@start-agent` handler calls `workspacesStore.startAgentOnTask`; closes dialog on `success: true, status: 'triggered'`; sets errorMessage and keeps dialog open on failure / undefined; doesn't double-fire on `startAgentBusy`. |
| NEW  | `src/apps/desktop/src/__tests__/workspacesStoreStartAgent.spec.ts` | Behavioural: `startAgentOnTask` calls `api.startAgentOnTask` with the right URL; returns the parsed body on success; returns `undefined` on caught error. |

### Docs (2 EDIT)

| Type | Path | Change |
|------|------|--------|
| EDIT | `docs/SPEC.md` | Add a §X entry summarising the start-agent affordance (and a pointer to this spec). |
| EDIT | `NALAR.md` | Append "### 2026-08-18: kanban task detail start agent" changelog entry. |

Total: **13 files** (4 NEW, 9 EDIT). Backend: 1 new endpoint, 1 new event field. Frontend: 1 new button + 1 new emit + 1 new store action + 1 new API helper.

## 6. Verification

### Backend
- `zig build test --summary all` — no regression. Existing `routines_run_test.zig`, `session_create_test.zig`, `kanban_tasks_create_test.zig`, and the inline workflow tests must pass with no behaviour change. The new `start_agent_test.zig` covers:
  - Contract: route is registered (source greps for `startAgentHandler` in `main.zig`).
  - Contract: handler calls `di.emit_run_agent` with the `skip_initial_queue_message` flag set.
  - Behaviour: missing `task_id` → 400.
  - Behaviour: missing task → 404.
  - Behaviour: worker already running → 409.
  - Behaviour: happy path → 200 with `{ success: true, session_id, status: 'triggered' }`.
- `zig build install:linux:system` — binary builds clean.
- Manual smoke (port 8080, isolated tmpdir):
  1. Start the server. Create a session with `POST /api/llm/session` and `queue_message: 'hello'` — wait for the worker to start and finish.
  2. POST `/api/workspaces/.../tasks/<id>/start_agent` with no body → expect 200 + `{success:true,status:"triggered"}`. The SSE `worker` channel should fire a `created` event.
  3. Immediately POST again → expect 409 (worker is running).
  4. Wait for the worker to finish. POST again → expect 200. The worker should resume from the existing chat history and produce a follow-up assistant message.

### Frontend
- `bun run build` clean (vue-tsc) — required for type-check (vitest alone doesn't type-check).
- `bunx vitest run` — all new behavioural tests pass; no regression on `KanbanTaskDetailDialog.spec.ts` / `KanbanTaskDetailDialog.runAgent.spec.ts` (the create-mode tests must NOT see the new button, and the existing tests must NOT see new emit errors).
- Manual smoke (port 8080, isolated tmpdir):
  1. Create a kanban task with title "Refactor modal" + description "Move AddItemDialog to a generic base". **DON'T** click Save (so the row stays persisted via Create-mode path). Open the task's detail dialog.
  2. Assert: `▶ Start agent` button is visible (edit mode). The Save button is disabled (no form changes yet). The Start agent button is enabled (`processingState` map is empty).
  3. Click `▶ Start agent`. Assert: dialog closes. The task card stays in its column. Open the task's chat view (via card click). Assert: a new assistant message appears within ~500 ms (the LLM's response to the existing context). The chat view's history shows the previous assistant turn but NOT a duplicate "Refactor modal\n\n..." user message.
  4. Re-open the task's detail dialog while the worker is still running. Assert: `▶ Start agent` is disabled with the explainer tooltip.
  5. Wait for the worker to finish (SSE `worker` `deleted` event). Re-open the dialog. Assert: `▶ Start agent` re-enables.
  6. Simulate backend 409 (mock returns 409). Assert: dialog stays open; red error banner reads "A worker is already running on this task."
  7. Simulate backend 404 (mock returns 404 for a deleted task). Assert: dialog closes; toast/inline notification "Task no longer exists."
  8. Create a brand-new task with no chat history, open its dialog, click `▶ Start agent`. Assert: dialog closes. Open chat. Assert: the LLM's response is whatever the system prompt dictates (likely an offer-to-help clarification). Document this behaviour as the expected no-history case.

## 7. Risks & open questions

- **Already-running race**: rare (requires SSE delivery > 100 ms lag AND a backend that completes the "is worker running?" check faster than the SSE event arrives). Mitigated by `:disabled` + `startAgentBusy` 1-shot re-entrancy guard + the backend's atomic 409 check. Belt + suspenders + safety net.
- **No-history UX**: documented in §3.8. If users complain, follow-up is a fallback that sends title+description as the queue_message for empty-history sessions. Not blocking for v1.
- **CLI parity**: the optional CLI command (see §5 backend) adds user-facing parity for users who want to start an agent from the terminal. If skipped for v1, document in the spec's follow-up section.
- **None blocking.** The endpoint, the worker-state plumbing (`processingState`), and the disabled-state data source all exist or are simple additions. The new endpoint's contract is intentionally narrower than `/api/llm/session` (which is a session-creation endpoint), so the API surface stays clean and the wire semantics are explicit.
