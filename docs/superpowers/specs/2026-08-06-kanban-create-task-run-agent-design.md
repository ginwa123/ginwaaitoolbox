# Kanban "Create task & run agent" — Design

> **For agentic workers:** This is a design spec. After the user approves, the next step is to invoke the `superpowers:writing-plans` skill to create a bite-sized implementation plan.

**Goal:** Add a secondary action in the kanban New Task dialog — **Create task & run agent** — that creates the task *and* queues its `title + description` as the first user message in the new chat session, kicking the agent off immediately and routing the user to that session's chat view. The title/description becomes the user's first chat turn verbatim.

**Architecture:** Extend the existing `KanbanTaskDetailDialog` (create mode) with a second submit button whose emit is `{ mode: 'create_and_run', name, description, is_auto_retry_until_stop, tags }`. The host (`KanbanView.vue`) gains a branch on `mode`: today it creates the task + moves it to the column + closes the dialog; the new branch additionally calls `api.sendChatMessage(task.id, queueMessage, item.path)` and navigates to the new task's chat view via the existing `setActiveTask` + `router.replace` pattern. The queued message is `title + '\n\n' + description` when description is non-empty, or just `title` when description is empty. No backend changes — `POST /api/workspaces/:ws/items/:item/tasks` and `POST /api/llm/session` already exist and compose cleanly.

**Tech Stack:** Vue 3 + TypeScript + Pinia + Vitest (`@vue/test-utils`). No new dependencies, no backend changes, no migration.

## 1. Why now — the problem

Today, creating a kanban task and starting the agent on it is a **two-step ceremony**:

1. Click **+** on a column → fill `title + description` → click **Create task**.
2. The task lands as a card. Click the card → the chat view opens, **empty**.
3. User re-types the task intent into the chatbox and hits Enter → the agent runs.

For one-off tasks where the description *is* the prompt (the typical case for standard tasks on a kanban), the second step is redundant — the user is typing the same thing twice. The new button collapses steps 1+2+3 into a single click: create, queue, navigate.

The existing **routine** task type already does this via the `Run Now` button (calls `POST /tasks/:id/run`). The new feature extends that same primitive to **standard** tasks at create time.

## 2. Current state — what exists today

**Frontend**
- `KanbanTaskDetailDialog.vue` (mode `'create'`) — collects `name`, `description`, `tags`, `is_auto_retry_until_stop`. Footer has **Cancel** + **Create task** buttons.
- `KanbanView.vue` — `handleCreateTaskSave` calls `workspacesStore.addTask` → `moveTaskToColumn` → closes the dialog. Opens the dialog in create mode when a column emits `@add-task`.
- `workspacesStore.addTask` → `api.createTask` (POST `/workspaces/:ws/items/:item/tasks`) → mirrors into `item.tasks[]`.
- `api.createTask` forwards `is_auto_retry_until_stop: '1'` only when the user flipped the toggle ON; otherwise no `sessions` row is inserted at create time (Migration 063 Option A).
- `api.sendChatMessage` (POST `/llm/session`) takes `sessionId`, `queueMessage`, `cwdSession`, `imageUrls`, `selectedProfile`, `isAutoRetryUntilStop` and returns `{ status: 'queued' | 'bad_request' | ... }`. The handler also stamps `last_human_touched_at` (so the kanban notification icon flips off).
- `sidebarRef.runRoutine(...)` is the existing end-to-end flow for routine tasks: POST `/run` → setActiveTask → router.replace to chat view.
- `ChatView.vue` already renders queued user messages on load via `loadChatHistory`. The queued message appears as a normal user turn in the chat transcript.

**Backend**
- `POST /api/workspaces/:ws/items/:item/tasks` (`task_create.zig`) — creates the task row. With `is_auto_retry_until_stop: '1'` it also inserts a `sessions` row keyed by `task.id`.
- `POST /api/llm/session` (`session_create.zig`) — creates/upserts the chat session (idempotent on `session_id == task.id`) and queues `queue_message` for the worker. Returns 201 `{id, name, status: 'send'}`.
- `task.id == session.id` is a project invariant (Migration 052 dropped the redundant `workspace_item_tasks.session_id` column).

## 3. Design — UX, wire, sequencing

### 3.1 UX — the new button

```
┌──────────────────────────────────────────┐
│ New task                            [✕]  │
├──────────────────────────────────────────┤
│ Task name                                │
│ [Enter task name…              ]         │
│                                          │
│ Description (0 / 5000)                   │
│ [Add a description…            ]         │
│                                          │
│ Tags                                     │
│ [Add tags…                     ]         │
│                                          │
│ Unattended mode              [● ◯]       │
├──────────────────────────────────────────┤
│              [Cancel] [Create task] [▶ Create task & run agent] │
└──────────────────────────────────────────┘
```

- **Label**: `▶ Create task & run agent` (right-aligned, after the existing primary button). The ▶ prefix reuses the same play-icon glyph as the existing **Run now** button on routine cards (`WorkspaceItemTaskCard.vue:388`).
- **Style**: outlined (1px var(--color-border), transparent background) — *visually subordinate* to the primary `Create task` button (filled gradient). Hover: faint `var(--color-violet)` tint + violet text. Disabled: 0.5 opacity + cursor not-allowed.
- **Position**: `flex justify-end gap-2` in the existing footer, so:
  - `Cancel` (left)
  - `Create task` (filled gradient — primary)
  - `▶ Create task & run agent` (outlined — secondary)
- **Enabled state**:
  - Disabled when name is empty (matches the existing `canSave` invariant).
  - Description is **not** required (Q2 = 2b). An empty description is allowed; the queued message becomes just the title.
  - Tags / unattended toggle do not gate the button.
- **Hover tooltip**: `Create the task and start the agent. The title + description becomes the first user message.`

### 3.2 Wire — emit shape

The dialog gains a new emit alongside the existing `create` and `save`:

```ts
'create-and-run': [
  payload: {
    mode: 'create_and_run'
    name: string                    // already trimmed
    description: string             // raw, may be ''
    is_auto_retry_until_stop: '0' | '1'
    tags: string[]
  }
]
```

The existing `create` emit stays untouched (today's "Create task" path). The new path is a sibling — same payload, just a different `mode` discriminator.

### 3.3 Sequencing — host (`KanbanView.vue`)

`handleCreateTaskSave` accepts `mode: 'create' | 'create_and_run'`:

```ts
async function handleCreateTaskSave(payload: {
  mode: 'create' | 'create_and_run'
  name: string
  description: string
  is_auto_retry_until_stop?: '0' | '1'
  tags?: string[]
}) {
  // ... existing guards ...

  // Step 1 — same as today: create the task.
  const taskId = await workspacesStore.addTask(wsId, itId, {
    name: payload.name,
    description: payload.description,
    isAutoRetryUntilStop: payload.is_auto_retry_until_stop,
    tags: payload.tags,
  })
  if (!taskId) { createError.value = 'Failed to create task — please retry.'; return }

  // Step 2 — move the new task to the column the user clicked.
  await workspacesStore.moveTaskToColumn(wsId, itId, taskId, desiredColumnId, 0)

  // Step 3 — branch on mode.
  if (payload.mode === 'create_and_run') {
    // Build the queued message: "title\n\ndescription" when description is non-empty,
    // or just "title" when description is empty.
    const queueMessage = payload.description.trim() !== ''
      ? `${payload.name}\n\n${payload.description}`
      : payload.name
    // Fire-and-forget: a failed send falls back to "task created but agent
    // not started". The user can type into the empty chat view manually.
    const result = await workspacesStore.runAgentOnNewTask(
      wsId, itId, taskId, {
        queueMessage,
        cwd: item.path || '',
        isAutoRetryUntilStop: payload.is_auto_retry_until_stop,
      },
    )
    if (result?.status === 'queued') {
      workspacesStore.setActiveTask(taskId)
      router.replace({ path: '/app', query: { view: 'task', task: taskId, session: taskId } })
    }
    // else: fall through — task is created, dialog closes, user can click the
    // card to manually start the agent.
  }

  // Step 4 — close the dialog (same for both modes).
  showCreateDialog.value = false
  activeCreateColumnId.value = null
}
```

### 3.4 Store — new action

```ts
// workspacesStore.runAgentOnNewTask
async function runAgentOnNewTask(
  workspaceId: string,
  itemId: string,
  taskId: string,
  params: {
    queueMessage: string
    cwd: string
    isAutoRetryUntilStop?: '0' | '1'
  },
): Promise<{ status: string } | undefined> {
  return await api.sendChatMessage(
    taskId,
    params.queueMessage,
    params.cwd,
    undefined,                                // imageUrls
    '',                                       // selectedProfile
    params.isAutoRetryUntilStop ?? '',        // passes '1' only when toggle is ON
  )
}
```

**Why a thin wrapper instead of inlining in the component?** The store action is the place that owns cross-component contracts (mirroring into Pinia, side effects on the workspaces tree). The `api.sendChatMessage` call is a one-line forward today, but the action gives us a single place to:
- log the queued message for debugging
- add a per-item `queuedMessage` audit row (future)
- expose `runAgentOnNewTask` to other call sites (e.g. the future "Run agent on existing task" button)

### 3.5 Queued message composition

| `name` | `description` (trimmed) | `queue_message` (sent to backend) |
|--------|-------------------------|------------------------------------|
| non-empty | empty | `name` only |
| non-empty | non-empty | `name` + `\n\n` + `description` (raw, not trimmed — preserves user's whitespace + markdown) |

- The title and description are joined verbatim. No "Title:" prefix, no JSON envelope — the LLM sees what the user typed.
- Trailing/leading whitespace inside `description` is preserved (users may use leading markdown like `## Heading` or list items).
- The `\n\n` separator matches Markdown convention (two newlines = paragraph break). The chat view renders Markdown, so a heading in `name` (e.g., `# My task`) renders as an H1, and a heading in `description` (e.g., `## Steps`) renders as an H2.

### 3.6 Error handling — partial success

The two calls are sequential, not transactional. Possible failure modes:

| Step that fails | Backend state | UI behavior |
|------------------|---------------|-------------|
| `createTask` (1) | no row, no session | Dialog stays open; `errorMessage` banner shows the API error; nothing navigated |
| `moveTaskToColumn` (2) | task row exists in default column | Dialog closes (current behavior); user sees the task at the auto-assigned column |
| `sendChatMessage` (3) | task row + session row exist, but no queued message | Dialog closes; `setActiveTask` NOT called; user sees the card in its column. They can click the card to open the (empty) chat view and type a message manually. Toast: "Task created — agent didn't start, please retry." (reuse `useNotificationStore().add(...)`) |

The third failure mode is rare (the session_create handler is robust) but the fallback is important: never strand the user with a task that they can't interact with.

### 3.7 Why a store action instead of the existing `runRoutine`?

`workspacesStore.runRoutine(ws, item, taskId)` is for **routine** tasks specifically (it calls `POST /tasks/:taskId/run` which is a routine-only endpoint). The new flow is for **standard** tasks and uses a different endpoint (`POST /llm/session`). The store action names them apart: `runRoutine` (existing) vs `runAgentOnNewTask` (new). They share the *post-success* navigation pattern (`setActiveTask` + `router.replace`) but have different preconditions and endpoint contracts.

## 4. Out of scope (deferred)

- **"Run agent on existing task"** — same primitive, just `runAgentOnExistingTask(taskId, message, cwd)`. Easy follow-up; out of scope here because the user request is specifically the create dialog.
- **Showing a spinner in the chatview before the first LLM chunk** — `processingState` already does this for the session. Today it's set by the SSE handler on the first assistant token; for the first turn after `queue_message`, the worker picks it up immediately and the SSE `agent_running` event flips the flag. Sufficient.
- **Markdown rendering of the queued message in the chatview before the LLM responds** — the chatview's `loadChatHistory` reads the queued message from the backend on mount and renders it as a user turn. Markdown rendering already happens via `MarkdownDescription`-style pipeline.
- **Confirmation modal** — the button is enabled at all times (Q2 = 2b). No "Are you sure?" gate.
- **Backwards compatibility with the legacy "Create task" button** — the existing button stays as-is. New button is a sibling. Users who only want a placeholder task keep using "Create task".
- **Queueing an agent run for routine/memory tasks at create time** — routine tasks already have `initial_prompt` and are scheduled; memory tasks don't run agents. Out of scope.

## 5. Files to touch

| Type | Path | Change |
|------|------|--------|
| EDIT | `src/apps/desktop/src/components/kanban/KanbanTaskDetailDialog.vue` | Add `▶ Create task & run agent` button; add `create-and-run` emit; add `canRunAgent` computed |
| EDIT | `src/apps/desktop/src/components/kanban/KanbanView.vue` | Extend `handleCreateTaskSave` to branch on `mode: 'create' \| 'create_and_run'`; import `useNotificationStore` for the partial-success toast |
| EDIT | `src/apps/desktop/src/stores/workspaces.ts` | Add `runAgentOnNewTask(workspaceId, itemId, taskId, params)` action; export from `defineStore` |
| NEW  | `src/apps/desktop/src/__tests__/KanbanTaskDetailDialog.runAgent.spec.ts` | Behavioural: button visibility, disabled when name empty, emit shape on click |
| NEW  | `src/apps/desktop/src/__tests__/KanbanView.createAndRun.spec.ts` | Behavioural: host calls `addTask` then `moveTaskToColumn` then `sendChatMessage` in correct order; navigates only on `status: 'queued'`; partial-success toast on failed send |
| NEW  | `src/apps/desktop/src/__tests__/workspacesStoreRunAgent.spec.ts` | Behavioural: `runAgentOnNewTask` forwards `queueMessage`, `cwd`, `isAutoRetryUntilStop` correctly |
| EDIT | `docs/SPEC.md` | Add §3.7 entry; §10.2.1 PR index row |
| EDIT | `NALAR.md` | Append "### 2026-08-06: kanban create-task-run-agent" changelog entry |

Total: **8 files** (3 NEW, 5 EDIT). No backend changes. No migration. No Zig changes.

## 6. Verification

- `bun run build` clean (vue-tsc) — required for type-check (vitest alone doesn't type-check).
- `bunx vitest run` — all new behavioural tests pass.
- `zig build test --summary all` — no regression (frontend-only change but verify nothing touched Zig compiles).
- `zig build install:linux:system` — binary still builds.
- Manual smoke (port 8080, isolated tmpdir):
  1. Open kanban → click `+` on Todo column → fill title "Refactor modal" + description "Move AddItemDialog to a generic base" + unattended OFF → click ▶ Create task & run agent.
  2. Assert: dialog closes; new card appears at top of Todo column; chat view opens automatically; the message "Refactor modal\n\nMove AddItemDialog to a generic base" is the first user turn; agent spinner shows within ~500ms.
  3. Repeat with description EMPTY → assert message is just "Refactor modal".
  4. Repeat with unattended ON → assert `api.sendChatMessage` was called with `isAutoRetryUntilStop: '1'` (mock assert in test).
  5. Kill the network mid-call (test mock returns 500) → assert: card appears, dialog closes, but chat view does NOT navigate; toast: "Task created — agent didn't start".

## 7. Risks & open questions

- **None blocking.** The two backend endpoints are independent and well-tested. The main risk is the partial-success UX (a task exists but no queued message) — handled by the fallback to manual chat input.
- **Open**: should the new button respect the existing `canSave` (only enabled when name is non-empty)? — YES, same invariant. Spec'd.
- **Open**: should the new button copy the kanban's `path` as the session `cwd`? — YES. The session already uses `item.path` (passed via `KanbanView`'s `cwd` prop, threaded through to `api.sendChatMessage` as `cwdSession`). Spec'd.
