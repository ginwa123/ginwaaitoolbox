# Kanban "Task details — Start agent" — Design

> **For agentic workers:** This is a design spec. After the user approves, the next step is to invoke the `superpowers:writing-plans` skill to create a bite-sized implementation plan.

**Goal:** Add a secondary action to the kanban **Task details** dialog (edit mode only) — **Start agent** — that kicks off an LLM worker on the task's existing session by queuing its saved `name + description` as the first user message. The button is **disabled when a worker is already running for that session** (same condition that gates the existing unattended toggle's racing risk). On success the dialog closes and the user stays on the kanban; the worker runs in the background.

**Architecture:** Extend `KanbanTaskDetailDialog.vue` with a `▶ Start agent` button in edit mode (sibling to the existing Save/Cancel). The button injects the existing `processingState` map (provided by `App.vue` via `provide('processingState', ref<Record<string, boolean>>({}))`) and disables itself when `processingState[task.id] === true`. Clicking emits a new `start-agent` event; the host (`KanbanView.vue`) gains a handler that calls a new store action `runAgentOnTask(workspaceId, itemId, taskId)` which delegates to the existing `api.sendChatMessage` (POST `/api/llm/session`) — same wire shape as the create-mode `runAgentOnNewTask` action. **No backend changes, no migration, no new API endpoint.**

**Tech Stack:** Vue 3 + TypeScript + Pinia + Vitest (`@vue/test-utils`). Existing dependencies only.

## 1. Why now — the problem

Today, starting an agent on an existing kanban task is a multi-step detour:

1. Open the kanban. Find the task card.
2. **Click the card** → the chat view dialog opens (empty — no assistant is running yet).
3. **Re-type** the task intent into the chat box (often "what the user wrote in the title/description five minutes ago").
4. Press Enter → the agent runs.

For tasks where the title+description *is* the prompt (the dominant case for standard tasks on a kanban), step 3 is pure toil — the user is paying a re-typing tax. The Create-mode **Create task & run agent** button (plan `2026-08-06-kanban-create-task-run-agent`) already collapses this for brand-new tasks. The user's request completes the parity for existing tasks: a button that does the same primitive (`POST /api/llm/session` with the task's content as the first user message) without leaving the kanban.

Equally important: the button must be **safe to spam**. If a worker is already running for a task's session, naively calling `/api/llm/session` would queue a *second* user message — the user would not expect "Start agent" to append another turn on top of an in-flight one. The disable-when-running rule makes the affordance safe and discoverable: the user sees the button greyed out and understands "an agent is already running on this task".

## 2. Current state — what exists today

**Frontend (existing primitives we re-use)**
- `KanbanTaskDetailDialog.vue` (mode `'edit'`) — collects `name`, `description`, `tags`, `cwd` (per-task), and the `unattended` toggle. Footer has **Cancel** + **Save**. The dialog is purely presentational — emits events, no API calls.
- `KanbanView.vue` — `handleTaskDetailSave` (edit-mode save) and `handleCreateTaskSave` (create-mode handlers including `create-and-run`). Mounts the dialog at lines 1166 and 1184 with two separate instances (edit + create).
- `workspacesStore.runAgentOnNewTask(...)` (`stores/workspaces.ts:2746`) — wraps `api.sendChatMessage(taskId, queueMessage, cwdSession, imageUrls, selectedProfile, isAutoRetryUntilStop)`. Used by the create-and-run path.
- `api.sendChatMessage` (`api/index.ts:1168`) — POST `/api/llm/session` with `{ session_id, queue_message, allowed_tools, cwd_session, image_urls, selected_profile_model, is_auto_retry_until_stop }` and returns `{ status: 'queued' | 'bad_request' | 'unprocessable_entity' | 'http_error' | 'offline' }`. The handler is idempotent on `session_id == task.id` (creates the session row if it doesn't yet exist; queues the message against the existing one).
- `App.vue` (`App.vue:10`) — owns the `processingState` map (`Record<sessionId, boolean>`) and `provide('processingState', ...)`. Populated by:
  - SSE worker events (`worker` channel): created/updated → add; deleted → remove.
  - Initial `GET /api/workers` fetch on every (re)connect of the SSE bus — covers server restart / network drop.

**Backend (no changes needed)**
- `POST /api/llm/session` (`session_create.zig`) — existing endpoint, idempotent on `session_id == task.id`. Returns 201 on first call, 200 on subsequent calls.

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
- **Style**: outlined (`1px var(--color-border)`, transparent background) — *visually subordinate* to the primary `Save` button (filled gradient). Mirrors the style of `Create task & run agent` (line 1493). Disabled: 0.5 opacity + cursor not-allowed, identical to the existing disabled-button class.
- **Position**: actions row (`flex justify-end gap-2`), ordered:
  - `Cancel` (leftmost — destructive-leaning affordance, low-touch)
  - `▶ Start agent` (middle — secondary action)
  - `Save` (rightmost — primary, rightmost == most-likely-default per the existing pattern).
- **Visibility**: edit mode **only**. Create mode already has `▶ Create task & run agent`; rendering both would be redundant and visually noisy.
- **Disabled state**: `isWorkerRunning = inject('processingState')?.[task.id] === true`. When `true` the button is `:disabled` and a tooltip explains *"A worker is already running on this task — wait for it to finish before starting a new agent."*
- **Enabled state**: `!isWorkerRunning`. No additional gate (name length, dirty form, etc.). The button reflects the worker's worker-level running state — it does not care whether the user has edited the form.
- **Hover tooltip** (enabled): *"Start the agent on this task. The title + description becomes the first user message."*
- **What runs on click**: queue the saved task content via `POST /api/llm/session`. **Not** the form's in-form draft. See §3.5 for rationale.

### 3.2 Disabled-state visualization (bonus, optional)

To make the disabled state more informative (vs. just greyed-out), a small text label next to the button could read *"Running…"* when `isWorkerRunning === true`:

```
│              [Cancel] [Running… ▶ Start agent] [Save]│
```

This is a nice-to-have; the existing `0.5 opacity` disabled style is the minimum viable signal. **Decision deferred** to implementation — implement the label iff tests show users couldn't tell why the button was greyed out. (Pragmatic YAGNI: ship the disabled style only; iterate later.)

### 3.3 Wire — emit shape

The dialog gains a new emit alongside the existing `save`, `update-unattended`, `update-cwd`:

```ts
'start-agent': [
  payload: {
    taskId: string  // the task whose worker should start; == session_id
  },
]
```

Minimal payload — the host already has `taskId` and could read the task from the workspaces store; we pass it explicitly to make the event self-contained and trivially mock-able in tests.

### 3.4 Sequencing — host (`KanbanView.vue`)

`KanbanView.vue` gains a new handler, wired to the dialog's `@start-agent`:

```ts
const handleStartAgent = async (payload: { taskId: string }) => {
  if (!activeTaskDetailId.value || activeTaskDetailId.value !== payload.taskId) return
  startAgentError.value = null
  startAgentBusy.value = true
  try {
    const task = activeTaskDetail.value
    if (!task) { startAgentError.value = 'Task no longer exists.'; return }
    const queueMessage = task.description?.trim()
      ? `${task.name}\n\n${task.description}`
      : task.name
    const result = await workspacesStore.runAgentOnTask(
      props.workspaceId,
      props.itemId || props.item.id,
      payload.taskId,
      {
        queueMessage,
        cwd: task.cwd || props.item.path || '',
      },
    )
    if (result && result.status === 'queued') {
      showTaskDetail.value = false
      activeTaskDetailId.value = null
    } else if (result) {
      startAgentError.value = `Agent didn't start — status: ${result.status}`
    } else {
      startAgentError.value = 'Agent didn't start — network error.'
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

### 3.5 Store — new action

`workspacesStore.runAgentOnTask(workspaceId, itemId, taskId, params)` is a sibling of `runAgentOnNewTask` (§3.4 of plan `2026-08-06-kanban-create-task-run-agent`):

```ts
// Same wire shape as runAgentOnNewTask (both POST /api/llm/session).
// The two actions diverge ONLY on the queue_message source: the new
// one reads from params (host supplies the persisted task row),
// while runAgentOnNewTask is called in the create path where the
// task doesn't exist yet.
async function runAgentOnTask(
  workspaceId: string,
  itemId: string,
  taskId: string,
  params: {
    queueMessage: string
    cwd: string
  },
): Promise<{ status: string } | undefined> {
  try {
    return await api.sendChatMessage(
      taskId,
      params.queueMessage,
      params.cwd,
      undefined, // imageUrls — not threaded through for the start-agent flow
      '',        // selectedProfile — use the session's persisted profile (via /llm/session default)
    )
  } catch (err) {
    console.error('Failed to start agent on existing task:', err)
    return undefined
  }
}
```

**Why a thin wrapper instead of inlining in the component?** Mirrors the rationale for `runAgentOnNewTask` (§3.4 of the create-mode plan): single ownership of the cross-component contract, easier to add per-call auditing later, and tests can mock the store action instead of the API helper. The two store actions are siblings — no shared base class needed, just clear naming.

**Why does the action NOT thread `selectedProfile` / `isAutoRetryUntilStop` / `imageUrls`?**
- `selectedProfile`: the session row was created with its profile at task-creation time (Migration 063 Option A). The backend's `/api/llm/session` POST handler reads `sessions.selected_profile_model` from the existing row if no value is passed — so passing `''` lets the backend persist the "use existing" semantics. If a future user need surfaces (e.g. "start with a different profile"), the action accepts it as an optional param.
- `isAutoRetryUntilStop`: same logic — session already has its flag from when the task was created. Unattended-mode toggle in the dialog changes the flag separately (immediate-save, emits `update-unattended`); it does not need to be re-passed on Start agent.
- `imageUrls`: the queued message uses the existing description; if the description contains image markdown (`![name](url)`), it's preserved verbatim. There's no separate "attachment" channel for the run-agent path. (The create-mode path threads imageUrls because pendingFiles aren't in `description`.)

### 3.6 Queued message composition

| `task.name` | `task.description` (trimmed) | `queue_message` |
|-------------|------------------------------|-----------------|
| non-empty | empty / whitespace | `name` |
| non-empty | non-empty | `name` + `\n\n` + `description` (raw, not trimmed) |

- Title and description are joined verbatim — the LLM sees what the user saved.
- Trailing/leading whitespace inside description is preserved.
- `\n\n` matches Markdown paragraph-break convention. The chatview renders Markdown.

### 3.7 Source of the queued message: persisted task row (NOT form draft)

The button uses `task.name` / `task.description` from the dialog's `task` prop (which is a live reference into `props.item.tasks[]` via `activeTaskDetail`). **The in-form draft (`name`/`description` refs in the dialog's `<script setup>`) is NOT used.**

Rationale:
1. **Matches the unattended-toggle UX** — that toggle is an iOS-style immediate-save switch (saves the moment you flip it, doesn't gate on Save click). Start agent is the same family: when you click it, the current persisted state is what runs.
2. **No save-before-run race** — if the form is dirty AND the user clicks Start agent, we'd need a 2-step "save first, then run" sequence with status reporting for partial success (the existing kanban flow has this for create-and-run). Keeping "Start agent = read from persisted row" sidesteps the entire class of bug.
3. **Discovers the right mental model** — "Start agent" = "run an agent on the task as it exists right now". If you want to run on *new* content, the workflow is: edit, **Save**, then Start agent. Three deliberate steps, no surprise.

(If the user wants the new draft as the prompt, they click Save first — the existing `Save` button is right there.)

### 3.8 Disabled-state race — why we don't need more

The disabled check is `processingState[task.id] === true`. Race scenarios:

| Scenario | Behaviour |
|----------|-----------|
| User A opens dialog, worker not running, clicks Start. SSE `worker` event arrives 100 ms later (created event) → `processingState[task.id] = true`. | POST is in flight; backend queues the message; SSE adds the worker to the map. No double-queue — the user only clicked once. |
| Worker finishes between dialog open and click (SSE `deleted` event arrives). | Map clears, button enables, user clicks. POST spawns a new worker. Correct. |
| Worker is running (map says true). User clicks anyway via keyboard shortcut. | `:disabled` prevents the click on a focused button. The `mousedown` handler is not registered for this button (unlike Save's draft-commit dance — see §3.10). Even if `disabled` is overridden by the browser, the host handler is gated by `startAgentBusy.value` (one-shot re-entrancy guard). |

A long-running POST that succeeds mid-flight (the SSE `worker created` event arrives before the POST returns) **does not** cause a double-queue — the existing `POST /api/llm/session` handler creates the worker once and enqueues the message once. Concurrent calls would be a backend concern, not a UX concern.

### 3.9 Error handling — partial-success UX

| Outcome | UI behaviour |
|---------|---------------|
| POST returns `status: 'queued'` | Dialog closes (matches create-and-run). Background worker runs. |
| POST returns `status: 'bad_request'` / `'unprocessable_entity'` / `'http_error'` / `'offline'` | Dialog stays open. The dialog's existing `errorMessage` prop (already wired in create-mode — line 1192) is set via a new `startAgentError` ref. User can fix and retry. |
| POST throws (network down) | Same as `offline` — caught in the store action which returns `undefined`; host maps to "network error". |
| SSE `worker` race: a worker was created between dialog open and click (impossible — the disabled check would have been true) | n/a — defensive :disabled covers this. |
| User has unsaved form edits + clicks Start agent | Form edits are **silently dropped** (Start agent uses the persisted row, not the draft; matches the unattended-toggle UX). If this becomes a UX complaint, follow-up with a "Save changes first?" guard. For the v1, this trade-off is acceptable and documented. |

### 3.10 The mousedown pattern from `commitTagsDraftOnSaveMouseDown` is NOT applied here

The Save button uses a `mousedown` handler to commit any draft tag before click logic (`commitTagsDraftOnSaveMouseDown` at line 780). The Start agent button does **not** need this — it doesn't read form state, it reads `task` from props. The drafts don't affect whether the button is enabled or what it emits.

## 4. Out of scope (deferred)

- **Re-attach currently-edited draft into the queued message** — explicit user request "use saved version" precludes this. Follow-up: a "Save and start agent" combined button could be added if users complain about lost edits.
- **Refreshing `processingState` from the backend on dialog open** — `App.vue` already re-syncs on every SSE (re)connect (line 109). For a session open for a long time before the dialog is opened, the map may be stale *only* if the SSE bus had been disconnected long enough for a worker to spawn+finish on a different nalar instance. Acceptable — clicking an enabled button when a remote worker is actually running would create a 2nd queue, but the 2nd queue is queued after the first finishes (FIFO inside the backend's session queue), so it's recoverable.
- **Visualizing "Running…" text in the disabled button** — see §3.2; deferred until user feedback justifies.
- **Start-agent affordance on the kanban card itself (not just in the dialog)** — would require passing `processingState` to `KanbanCard` and re-organizing the card's row layout. The dialog is the existing entry point for editing a task; the card's click surface is reserved for opening the chat view. Out of scope.
- **A "Start unattended" combined button** — the unattended toggle is separate; the user can pre-toggle unattended mode and then click Start agent to combine (Order: 1) toggle unattended → 2) click Start agent). No combined action needed.
- **Confirmation modal "Are you sure?"** — the button is enabled at most once per idle worker-state window; the cost of an accidental click is queueing an extra user message, which is easy to recover from (delete the user message, or stop the worker via ChatView). No confirmation gate.

## 5. Files to touch

| Type | Path | Change |
|------|------|--------|
| EDIT | `src/apps/desktop/src/components/kanban/KanbanTaskDetailDialog.vue` | Add `inject('processingState')`; add `▶ Start agent` button + `start-agent` emit (edit mode only); add `isWorkerRunning` computed; register it on KanbanView's mount. |
| EDIT | `src/apps/desktop/src/components/kanban/KanbanView.vue` | Wire `@start-agent="handleStartAgent"`. Add `handleStartAgent` handler that calls `workspacesStore.runAgentOnTask(...)`. Add `startAgentError` ref bound to the dialog's `errorMessage` prop. |
| EDIT | `src/apps/desktop/src/stores/workspaces.ts` | Add `runAgentOnTask(workspaceId, itemId, taskId, params)` action; export from `defineStore`. Add to the test export list (line 3930 area). |
| NEW  | `src/apps/desktop/src/__tests__/KanbanTaskDetailDialog.startAgent.spec.ts` | Behavioural (mount pattern mirrors `KanbanTaskDetailDialog.runAgent.spec.ts`): button hidden in create mode; visible in edit mode; disabled when `processingState[task.id] = true`; enabled when false / absent; click emits `start-agent` with `{ taskId }`; injecting a non-object processingState doesn't throw. |
| NEW  | `src/apps/desktop/src/__tests__/KanbanView.startAgent.spec.ts` | Behavioural: `@start-agent` handler calls `workspacesStore.runAgentOnTask` with the persisted task's name+description; closes dialog on `status: 'queued'`; sets errorMessage and keeps dialog open on bad status / undefined / thrown error; doesn't double-fire on `startAgentBusy`. |
| NEW  | `src/apps/desktop/src/__tests__/workspacesStoreStartAgent.spec.ts` | Behavioural (mirrors `workspacesStoreRunAgent.spec.ts`): `runAgentOnTask` forwards `queueMessage`, `cwd`, calls `api.sendChatMessage` with `taskId`; returns `{ status: 'queued' }` on success and `undefined` on caught error; does NOT pass `imageUrls`/`selectedProfile`/`isAutoRetryUntilStop` (defaults). |
| EDIT | `docs/SPEC.md` | Add a §X entry summarising the start-agent affordance (and a pointer to this spec). |
| EDIT | `NALAR.md` | Append "### 2026-08-18: kanban task detail start agent" changelog entry, mirroring the style of the existing 2026-08-13 / 2026-08-14 entries. |

Total: **8 files** (3 NEW, 5 EDIT). No backend changes. No migration. No Zig changes. No new dependencies.

## 6. Verification

- `bun run build` clean (vue-tsc) — required for type-check (vitest alone doesn't type-check).
- `bunx vitest run` — all new behavioural tests pass; no regression on `KanbanTaskDetailDialog.spec.ts` / `KanbanTaskDetailDialog.runAgent.spec.ts` (the create-mode tests must NOT see the new button, and the existing tests must NOT see new emit errors).
- `zig build test --summary all` — no regression (frontend-only change but verify nothing touched Zig compiles).
- `zig build install:linux:system` — binary still builds.
- Manual smoke (port 8080, isolated tmpdir):
  1. Create a kanban task with title "Refactor modal" + description "Move AddItemDialog to a generic base". **DON'T** click Save (so the row stays persisted via Create-mode path). Open the task's detail dialog.
  2. Assert: `▶ Start agent` button is visible (edit mode). The Save button is disabled (no form changes yet). The Start agent button is enabled (`processingState` map is empty after the create-and-run path doesn't apply — create-mode plain save doesn't queue, only `Run agent` does).
  3. Click `▶ Start agent`. Assert: dialog closes. The task card stays in its column. Open the task's chat view (via card click). Assert: the first user turn is "Refactor modal\n\nMove AddItemDialog to a generic base"; agent spinner appears within ~500 ms.
  4. Re-open the task's detail dialog while the worker is still running. Assert: `▶ Start agent` is disabled with the explainer tooltip. Assert: the Save button is unaffected (form changes are still allowed; the worker is independent of edits).
  5. Wait for the worker to finish (SSE `worker` `deleted` event). Re-open the dialog. Assert: `▶ Start agent` re-enables.
  6. Edit the description (form is dirty), then click `▶ Start agent` WITHOUT saving first. Assert: dialog closes. Open chat. Assert: the queued message uses the *original* description (the Save button was never clicked), not the edited draft. (Documented behaviour — §3.7.)
  7. Simulate POST failure (mock returns `status: 'http_error'`). Assert: dialog stays open; red error banner reads "Agent didn't start — status: http_error". The user can retry.

## 7. Risks & open questions

- **Already-running race**: rare (requires SSE delivery > 100 ms lag), mitigated by `:disabled` + `startAgentBusy` 1-shot re-entrancy guard. If observed in production, add a backend-side mutex to `/api/llm/session` (out of scope here — backend team can decide).
- **Stale `processingState`**: only possible if the SSE bus was disconnected long enough for a remote worker to spawn+finish on another nalar instance while the dialog sat open. Self-healing on next reconnect. Documented.
- **Form-edits dropped on Start agent click**: explicit trade-off (see §3.7). If users complain, the fix is a combined Save+Start button (~1 day follow-up). Not blocking for v1.
- **None blocking.** The endpoint (`/api/llm/session`), the worker-state plumbing (`processingState`), and the disabled-state data source all exist. The only thing being added is a presentational button + a thin store action + two event wires.
