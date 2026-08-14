# Kanban-specific Task Create Endpoint — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a single kanban-scoped endpoint `POST /api/workspaces/:wid/items/:iid/kanban/tasks` that handles both `mode='create'` and `mode='create_and_run'` via a body discriminator, then point the existing kanban dialog at it so a kanban task creation never touches the generic `/tasks` route. Wire behavior stays identical — same fields, same SSE events, same UI.

**Architecture:** One Zig handler `kanban_tasks_create.zig` whose `useCase` branches on `body.mode`:
- `mode='create'` → calls `createStandardTask` (reuse the existing useCase with `.kanban` discriminator → auto-assign-to-first-column fires), emits `kanban_task` SSE (`action='assigned'`), returns `{ task, session: null }`.
- `mode='create_and_run'` → does the create step above **and** inserts the `sessions` row keyed by `task.id` (mirrors `sessionCreateHandler`), queues the message, emits `kanban_task` + `session_created` SSE, returns `{ task, session: { id, name, status: 'send' } }`.

The frontend swaps the 2-step dance (`addTask` + `runAgentOnNewTask`) for a single `addKanbanTask(mode, payload)` store action that calls one `api.createKanbanTask` helper.

**Tech Stack:** Zig 0.16 backend (handlers + tests) + Vue 3 / TypeScript / Pinia / Vitest frontend. No new dependencies, no DB migration.

## Design Decisions (review before execution)

| ID | Decision | Why | Alternative rejected |
|----|----------|-----|----------------------|
| D1 | **One endpoint with `mode` discriminator**, not two separate routes | User asked to combine. Matches the project's existing `task_type` discriminator pattern in `task_create.zig`. Single URL = single owner of the kanban-create wire shape. | Two endpoints (`/tasks` + `/tasks/run`) — duplicate validation, duplicate 404-on-not-kanban check, two routes to maintain. |
| D2 | **Path segment is `/kanban/`** (not `?item_type=kanban` or a query string) | Mirrors existing `kanban_columns_*` handlers (`POST /api/workspaces/:wid/items/:iid/kanban/columns`). Discoverable, tool-friendly. | Query string `?kanban=true` — easy to forget, easy to typo. |
| D3 | **Reject 404 if the parent item is not a kanban** (item_type='kanban' check) | Hard-fail fast. The generic `/tasks` endpoint already works for non-kanban items; calling kanban-specific routes on a non-kanban item is a programmer error. | Soft-fallback to the generic `/tasks` route — hides bugs. |
| D4 | **Reuse `createStandardTask` useCase** instead of duplicating its INSERT logic | Avoids drifting INSERT columns (tags, image_urls, cwd, unattended) between two handlers. We only add the auto-assign + SSE emit + (optionally) session-insert around it. | Inline a copy of `createStandardTask` — drifts within weeks. |
| D5 | **`session` field in response is `null` for `mode='create'`** | Single response shape — frontend can `if (response.session)` without sniffing `mode`. | Two separate response types — doubles the TS types. |
| D6 | **No migration** | Adding an endpoint doesn't change schema. The existing `tasks`, `kanban_columns`, `sessions` tables already support the workflow. | Adding a `kanban_tasks` table — premature, no caller needs it. |
| D7 | **Frontend action: `addKanbanTask(mode, payload)`** — single store action replacing `addTask` + `runAgentOnNewTask` for the kanban path | One owner of the kanban cross-component contract. The existing 2-action dance leaks the wire shape into the component. | Two separate calls in `KanbanView` — leaks wire shape into the component. |
| D8 | **`selectTask` emit still drives navigation** in both modes | Already plumbed through AppLayout → Sidebar. Reuses `router.replace({ view: 'task', task })`. No new navigation handler. | New `create-and-run-task` event — duplicates routing. |
| D9 | **Partial-success: do NOT navigate if the run step fails** | Same UX guard as the existing `runAgentOnNewTask`: surface a toast, keep the card visible, let the user click into it. | Navigate always — empty session view is worse. |

## Global Constraints

- **Cross-platform**: works on Linux, macOS, AND Windows. Frontend changes verified with `bun run build` (vue-tsc typecheck) + `bunx vitest run`. Backend changes verified with `zig build test --summary all`.
- **No static-contract tests**: ALL tests are behavioural. No `expect(source).toContain(...)` patterns. See `~/.config/nalar/memories/static-contract-test-when-to-prefer-behavioural.md`.
- **TDD discipline**: every implementation step starts with a failing test, then minimal code to make it pass, then a commit.
- **Behavioural Zig tests** live as `_test.zig` siblings next to the handler (see `kanban_columns_create_test.zig`). Register in `test_runner.zig`.
- **Behavioural Vue tests** use `@vue/test-utils` `mount` with `setActivePinia(createPinia())` in `beforeEach`. Mock fetch via `vi.fn()` returning `{ ok, status, json, text }` shape.
- **Teleport-based components**: `KanbanTaskDetailDialog` uses `<Teleport to="body">`. Use `attachTo: document.body` and `document.querySelector` for assertions.
- **No port 8081**: smoke tests use port 8080.
- **NO new comments above `logger.infoFmt(...)` calls** (see `~/.config/nalar/memories/no-comments-on-logger-calls.md`).
- **SSE wire-format contract**: any new event type name must be added in **all three** sites (backend emitter + `additionalEventTypes` in `api/index.ts` + the named-event dispatch chain). The existing `kanban_task` and `session_created` events are reused — no new event name — so this rule does not trigger.

---

## File Structure

```
NEW  src/ai_workflow/tui/http_handlers/kanban_tasks_create.zig          (handler with mode discriminator)
NEW  src/ai_workflow/tui/http_handlers/kanban_tasks_create_test.zig     (behavioural Zig tests for both modes)
EDIT src/ai_workflow/tui/http_handlers/mod.zig                          (+ pub fn export for the handler)
EDIT src/ai_workflow/tui/test_runner.zig                                (+ register the _test.zig file)
EDIT src/main.zig                                                        (+ POST /api/.../kanban/tasks route)

EDIT src/apps/desktop/src/api/index.ts                                  (+ api.createKanbanTask with mode discriminator)
EDIT src/apps/desktop/src/stores/workspaces.ts                          (+ addKanbanTask action replacing addTask+runAgentOnNewTask for kanban)
EDIT src/apps/desktop/src/components/kanban/KanbanView.vue              (handleCreateTaskSave calls addKanbanTask instead of the dance)
NEW  src/apps/desktop/src/__tests__/kanbanApiCreateTask.spec.ts         (api.createKanbanTask: both modes' wire shape, body JSON, error paths)
NEW  src/apps/desktop/src/__tests__/workspacesStoreAddKanbanTask.spec.ts (action forwards mode, returns task, surfaces run failure)
EDIT src/apps/desktop/src/__tests__/KanbanView.createAndRun.spec.ts      (asserts single addKanbanTask call, no addTask+runAgentOnNewTask dance)

EDIT docs/SPEC.md                                                       (+ §10.2.1 PR index entry)
EDIT NALAR.md                                                           (+ Recent changes entry once shipped)
```

Total: **12 files** (3 NEW, 9 EDIT).

---

## Root Cause (read this before chunking — saves re-discovery)

```
User wants ONE kanban-only task create endpoint (not the generic /tasks route).

Current behavior:
  KanbanTaskDetailDialog emits 'create' or 'create-and-run'.
  KanbanView.handleCreateTaskSave(payload) dispatches on mode:
    mode='create':
      - workspacesStore.addTask(payload)
        -> api.createTask
        -> POST /api/workspaces/:wid/items/:iid/tasks
        -> tasksCreateHandler creates the task; if iid is kanban, AUTO-ASSIGNS to first column
        -> emits kanban_task SSE event (action='assigned')
    mode='create_and_run':
      - workspacesStore.addTask(payload)
        -> POST /api/.../tasks (same as above)
      - workspacesStore.runAgentOnNewTask(taskId, payload)
        -> api.sendChatMessage({ session_id: taskId, queue_message, cwd, ... })
        -> POST /api/llm/session
        -> sessionCreateHandler inserts the sessions row keyed by task.id

Why change?
  Endpoint hygiene. The /api/.../tasks route is the generic path used by
  standard, routine, and memory task creation. Calling it from a kanban-
  only flow muddies ownership: 'which endpoints does the kanban dialog
  touch?' Today: 2 (tasks + llm/session). Tomorrow: 1 kanban-scoped.

  User wants ONE combined endpoint. Behavior stays the same — same wire
  fields, same SSE events, same UI.

The fix:
  Backend:
    POST /api/workspaces/:wid/items/:iid/kanban/tasks
      - Validates iid.item_type == 'kanban' (404 otherwise)
      - Parses body.mode ∈ {'create', 'create_and_run'}
      - For both modes: calls createStandardTask(.kanban)
        -> auto-assigns to first column
        -> emits kanban_task SSE (action='assigned')
      - For mode='create_and_run' ONLY:
        -> validates queue_message non-empty
        -> inserts sessions row keyed by task.id
        -> emits session_created SSE
      - Always returns { task: {...full task row...}, session: {id, name, status} | null }

  Frontend:
    api.createKanbanTask(workspaceId, itemId, { mode, name, ... })
      - mode='create'         -> body without queue_message
      - mode='create_and_run' -> body with queue_message
    workspacesStore.addKanbanTask(workspaceId, itemId, mode, payload)
      - delegates to api.createKanbanTask
      - wraps mode='create_and_run' failures in try/catch with notifyError
        so the partial-success path still surfaces the created card
    KanbanView.handleCreateTaskSave:
      - mode='create'         -> await addKanbanTask(..., 'create', payload)
                                  emit('selectTask', task)
      - mode='create_and_run' -> const { task, session } = await addKanbanTask(..., 'create_and_run', payload)
                                  emit('selectTask', task)  // session is observed by SSE
```

---

## Tasks

### Task 1: Backend — Add `kanban_tasks_create.zig` handler (both modes)

**Files:**
- NEW `src/ai_workflow/tui/http_handlers/kanban_tasks_create.zig`
- NEW `src/ai_workflow/tui/http_handlers/kanban_tasks_create_test.zig`
- EDIT `src/ai_workflow/tui/http_handlers/mod.zig`

#### Step 1.1 — Write the failing behavioural tests for both modes

In `kanban_tasks_create_test.zig`:

```zig
const std = @import("std");
const testing = std.testing;
const handlers = @import("mod.zig");
const H = @import("http_response.zig");
const UseCases = @import("../../use_cases.zig");

// ====== common (both modes) ======

test "kanban_tasks_create: returns 404 when item is not a kanban" {
    // setup: a workspaces + items row with item_type='folder'
    // call: handlers.kanbanTasksCreate(arena, db, wid, iid, body, response_writer)
    // assert: response.status == 404, body contains 'not a kanban'
}

test "kanban_tasks_create: returns 400 when mode is missing" {
    // setup: kanban item exists
    // call with body={}
    // assert: response.status == 400, body mentions 'mode'
}

test "kanban_tasks_create: returns 400 when mode is invalid" {
    // call with body={ "mode": "nonsense" }
    // assert: response.status == 400
}

// ====== mode='create' ======

test "kanban_tasks_create (mode=create): returns 201 + task + null session on valid create" {
    // setup: kanban item with first column
    // call with body={ "mode": "create", "name": "Fix bug", "description": "..." }
    // assert: response.status == 201
    // assert: body.task.id starts with 'task_'
    // assert: body.task.kanban_column_id == firstColumn.id
    // assert: body.session == null
}

test "kanban_tasks_create (mode=create): does NOT insert a sessions row" {
    // setup: kanban item
    // call with body={ "mode": "create", "name": "X" }
    // assert: SELECT COUNT(*) FROM sessions WHERE id = body.task.id == 0
}

test "kanban_tasks_create (mode=create): honours tags + image_urls + cwd + unattended" {
    // call with full body
    // assert: SELECT tags, image_urls, cwd, is_auto_retry_until_stop FROM tasks WHERE id = ?
    //         matches the body fields
}

// ====== mode='create_and_run' ======

test "kanban_tasks_create (mode=create_and_run): returns 400 when queue_message is empty" {
    // setup: kanban item
    // call with body={ "mode": "create_and_run", "name": "X", "queue_message": "" }
    // assert: response.status == 400
}

test "kanban_tasks_create (mode=create_and_run): returns 201 + task + session on valid run" {
    // setup: kanban item with first column
    // call with body={ "mode": "create_and_run", "name": "Fix bug", "queue_message": "fix the login" }
    // assert: response.status == 201
    // assert: body.task.id starts with 'task_'
    // assert: body.task.kanban_column_id == firstColumn.id
    // assert: body.session.id == body.task.id  // task.id == session.id convention
    // assert: body.session.name == "Fix bug"
    // assert: body.session.status == 'send'
}

test "kanban_tasks_create (mode=create_and_run): inserts sessions row keyed by task.id" {
    // call with valid body
    // assert: SELECT 1 FROM sessions WHERE id = body.task.id returns 1 row
}

test "kanban_tasks_create (mode=create_and_run): forwards cwd + unattended + profile to sessions row" {
    // call with { mode, name, queue_message, cwd, is_auto_retry_until_stop: '1', selected_profile_model: 'foo' }
    // assert: sessions row has cwd, is_auto_retry_until_stop='1', selected_profile_model='foo'
}

// ====== SSE ======

test "kanban_tasks_create (mode=create): emits exactly one kanban_task SSE event" {
    // subscribe to SSE
    // call with mode='create'
    // assert: 1 event received, event_type='kanban_task', action='assigned', task_id=...
}

test "kanban_tasks_create (mode=create_and_run): emits kanban_task + session_created" {
    // subscribe to SSE
    // call with mode='create_and_run'
    // assert: 2 events received:
    //   - event_type='kanban_task', action='assigned'
    //   - event_type='session_created', session_id=task.id
}
```

Register in `src/ai_workflow/tui/test_runner.zig` (find the existing `kanban_columns_create_test` registration and add the new line nearby).

Run: `timeout 60 zig build test --summary all 2>&1 | grep -E "(kanban_tasks_create|FAIL)"` — expect compile errors / test failure.

#### Step 1.2 — Implement the handler

In `kanban_tasks_create.zig`:

```zig
//! `POST /api/workspaces/:workspace_id/items/:item_id/kanban/tasks`.
//!
//! Kanban-scoped task create endpoint with a `mode` discriminator:
//!
//!   - `mode='create'`           — create the task, auto-assign to the
//!                                 kanban's first column, emit
//!                                 `kanban_task` SSE (action='assigned').
//!                                 Returns `{ task, session: null }`.
//!
//!   - `mode='create_and_run'`   — same as above PLUS insert the
//!                                 `sessions` row keyed by `task.id`,
//!                                 queue the first message, and emit
//!                                 `session_created` SSE. Returns
//!                                 `{ task, session: { id, name, status: 'send' } }`.
//!
//! Body: `{ mode, name, description?, queue_message? (create_and_run only),
//!         tags?, image_urls?, cwd?, is_auto_retry_until_stop?,
//!         selected_profile_model? }`.
//!
//! Errors:
//!   - 400 missing/invalid JSON body, missing/invalid `mode`,
//!     empty `queue_message` for `create_and_run`
//!   - 404 parent item is not a kanban
//!   - 500 DB failure (insert, fetch, or session-create failure)

const std = @import("std");
const nalarcore = @import("nalarcore");
const gserverz = nalarcore.gserverz;
const http_response = @import("http_response.zig");
const on_event_sent_kanban = nalarcore.ai_mod.on_event_sent_kanban;

pub const KanbanTaskCreateError = error{
    ItemIdRequired,
    ModeRequired,
    InvalidMode,
    QueueMessageRequiredForRun,
    NotAKanbanItem,
    WorkspaceItemNotFound,
    CreateStandardTaskFailed,
    CreateSessionFailed,
};

pub const RequestKanbanTask = struct {
    mode: []const u8 = "",
    name: []const u8 = "",
    description: ?[]const u8 = null,
    queue_message: ?[]const u8 = null,
    tags: ?[]const u8 = null,
    image_urls: ?[]const u8 = null,
    cwd: ?[]const u8 = null,
    is_auto_retry_until_stop: ?[]const u8 = null,
    selected_profile_model: ?[]const u8 = null,
};

pub const ResponseKanbanTask = struct {
    task: std.json.Value,
    session: ?std.json.Value = null,
};

pub fn useCase(
    arena: std.mem.Allocator,
    db: *sqlite.Db,
    wid: []const u8,
    iid: []const u8,
    body: RequestKanbanTask,
) !ResponseKanbanTask { ... }

pub fn kanbanTasksCreateHandler(
    ctx: gserverz.HttpContext,
    req: gserverz.HttpRequest,
    res: gserverz.HttpResponse,
) !gserverz.HttpResponse { ... }
```

The `useCase` body:

1. Validate `body.mode` ∈ `{create, create_and_run}` (400 otherwise).
2. SELECT item_type FROM workspace_items WHERE id = ? — assert `"kanban"` (404 otherwise).
3. Call `UseCases.createStandardTask(arena, db, wid, iid, body, .kanban)` — this returns the inserted task and triggers the auto-assign.
4. Emit `kanban_task` SSE (`action='assigned'`).
5. If `mode == 'create_and_run'`:
   - Assert `queue_message` non-empty (400 otherwise).
   - Call `UseCases.createSessionForTask(arena, db, task.id, queue_message, cwd, unattended, profile)` — a NEW thin useCase mirroring `sessionCreateHandler`'s INSERT into `sessions` keyed by `task.id`.
   - Emit `session_created` SSE.
   - Return `{ task, session: { id: task.id, name: task.name, status: "send" } }`.
6. Else return `{ task, session: null }`.

The handler wraps `useCase` in the standard `try → H.writeJson(status, payload)` shape that `kanban_columns_create.zig` uses (see its `kanbanColumnsCreateHandler` for the exact pattern).

Re-export in `mod.zig`:
```zig
pub const kanban_tasks_create = @import("kanban_tasks_create.zig");
```

Run: `timeout 60 zig build test --summary all 2>&1 | grep -E "(kanban_tasks_create|FAIL)"` — expect tests pass.

Commit: `feat(kanban): add POST /kanban/tasks handler with mode discriminator + behavioural tests`

---

### Task 2: Backend — Register route in `src/main.zig`

**Files:**
- EDIT `src/main.zig`

Find the existing route registration for the generic `POST /api/workspaces/:wid/items/:iid/tasks` (likely alongside `tasksCreateHandler`). Add the new route immediately after:

```zig
// POST /api/workspaces/:wid/items/:iid/kanban/tasks
```

Reuse the same path-param extraction pattern that the existing `tasksCreateHandler` route uses — no new routing logic.

Smoke test (must use port 8080 — see Global Constraints):
```bash
timeout 5 curl -sI -X POST http://localhost:8080/api/workspaces/wid/items/iid/kanban/tasks \
  -H 'Content-Type: application/json' \
  -d '{"mode":"create","name":"smoke"}' | head -n 5
# expect: HTTP/1.1 404 Not Found (no such wid/iid) — proves the route is wired
```

Commit: `feat(kanban): register POST /kanban/tasks route`

---

### Task 3: Frontend — Add `api.createKanbanTask` (one helper, mode-discriminated)

**Files:**
- EDIT `src/apps/desktop/src/api/index.ts`
- NEW `src/apps/desktop/src/__tests__/kanbanApiCreateTask.spec.ts`

#### Step 3.1 — Write the failing behavioural tests

`kanbanApiCreateTask.spec.ts`:
```ts
test('api.createKanbanTask (mode=create) POSTs to /kanban/tasks with mode=create + JSON body', async () => {
  // mock fetch
  // call api.createKanbanTask(workspaceId, itemId, { mode: 'create', name: 'Fix bug' })
  // assert fetch URL is /workspaces/{wid}/items/{iid}/kanban/tasks
  // assert method=POST, Content-Type=application/json
  // assert body.mode === 'create' and forwards name/description/tags/image_urls/cwd/unattended
  // assert returned response.task is parsed JSON, response.session is null
})

test('api.createKanbanTask (mode=create_and_run) includes queue_message in body', async () => {
  // call with { mode: 'create_and_run', name, queue_message, selected_profile_model }
  // assert body includes mode=create_and_run + queue_message + selected_profile_model
  // assert returned response.session has id+name+status='send'
})

test('api.createKanbanTask propagates non-2xx as thrown error', async () => {
  // mock fetch returning { ok: false, status: 404, json: async () => ({ error: '...' }) }
  // await expect(api.createKanbanTask(...)).rejects.toThrow(/not a kanban/i)
})

test('api.createKanbanTask propagates 400 on invalid mode', async () => {
  // mock fetch returning { ok: false, status: 400, json: async () => ({ error: '...' }) }
  // await expect(api.createKanbanTask({ mode: 'nonsense' })).rejects.toThrow()
})
```

Run: `bunx vitest run src/apps/desktop/src/__tests__/kanbanApiCreateTask.spec.ts` — expect failure (helper doesn't exist yet).

#### Step 3.2 — Implement the API helper

In `src/apps/desktop/src/api/index.ts`:

```ts
export type KanbanCreateMode = 'create' | 'create_and_run'

export interface KanbanCreateTaskPayload {
  mode: KanbanCreateMode
  name: string
  description?: string
  tags?: string[]
  image_urls?: string[]
  cwd?: string
  is_auto_retry_until_stop?: boolean
}

export interface KanbanCreateAndRunPayload extends KanbanCreateTaskPayload {
  mode: 'create_and_run'
  queue_message: string
  selected_profile_model?: string
}

export interface KanbanCreateResponse {
  task: Task
  session: { id: string; name: string; status: string } | null
}

export async function createKanbanTask(
  workspaceId: string,
  itemId: string,
  payload: KanbanCreateTaskPayload | KanbanCreateAndRunPayload,
): Promise<KanbanCreateResponse> {
  return apiFetch<KanbanCreateResponse>(
    `/workspaces/${workspaceId}/items/${itemId}/kanban/tasks`,
    {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(payload),
    },
  )
}
```

Run the spec. Expect pass.

Commit: `feat(kanban): add api.createKanbanTask helper with mode discriminator`

---

### Task 4: Frontend — Add `addKanbanTask(mode, payload)` store action

**Files:**
- EDIT `src/apps/desktop/src/stores/workspaces.ts`
- NEW `src/apps/desktop/src/__tests__/workspacesStoreAddKanbanTask.spec.ts`

#### Step 4.1 — Write the failing test

```ts
test('addKanbanTask("create") calls api.createKanbanTask and returns task + null session', async () => {
  // mock api.createKanbanTask
  // call store.addKanbanTask(workspaceId, itemId, 'create', { name: 'X' })
  // expect: api.createKanbanTask called with ({ mode: 'create', name: 'X' })
  // expect: returns { task: <mock>, session: null }
})

test('addKanbanTask("create_and_run") calls api.createKanbanTask with queue_message + returns session', async () => {
  // mock api.createKanbanTask
  // call store.addKanbanTask(workspaceId, itemId, 'create_and_run',
  //   { name: 'Fix bug', description: 'The login button is broken', queue_message: 'Fix bug\n\nThe login button is broken' })
  // expect: api.createKanbanTask called with the same shape including mode='create_and_run'
  // expect: returns { task, session: <mock session> }
})

test('addKanbanTask surfaces create_and_run failure WITHOUT throwing', async () => {
  // mock api.createKanbanTask to reject for the run-only path
  // (use a payload that includes queue_message so we hit the run path)
  // call store.addKanbanTask(..., 'create_and_run', { name: 'X', queue_message: 'go' })
  // expect: notifyError called
  // expect: returns { task: null, session: null }  (NOT re-thrown)
})

test('addKanbanTask("create") failure DOES throw (no partial-success path needed)', async () => {
  // mock api.createKanbanTask to reject for plain create
  // await expect(store.addKanbanTask(..., 'create', { name: 'X' })).rejects.toThrow()
})
```

Run: `bunx vitest run src/apps/desktop/src/__tests__/workspacesStoreAddKanbanTask.spec.ts` — expect failure.

#### Step 4.2 — Implement the action

In `workspaces.ts`:

```ts
async function addKanbanTask(
  workspaceId: string,
  itemId: string,
  mode: 'create' | 'create_and_run',
  payload: {
    name: string
    description?: string
    queue_message?: string
    tags?: string[]
    image_urls?: string[]
    cwd?: string
    is_auto_retry_until_stop?: boolean
    selected_profile_model?: string
  },
): Promise<KanbanCreateResponse> {
  const wire: KanbanCreateTaskPayload | KanbanCreateAndRunPayload =
    mode === 'create_and_run'
      ? {
          mode: 'create_and_run',
          name: payload.name,
          description: payload.description,
          queue_message: payload.queue_message ?? '',
          tags: payload.tags,
          image_urls: payload.image_urls,
          cwd: payload.cwd,
          is_auto_retry_until_stop: payload.is_auto_retry_until_stop,
          selected_profile_model: payload.selected_profile_model,
        }
      : {
          mode: 'create',
          name: payload.name,
          description: payload.description,
          tags: payload.tags,
          image_urls: payload.image_urls,
          cwd: payload.cwd,
          is_auto_retry_until_stop: payload.is_auto_retry_until_stop,
        }

  try {
    return await api.createKanbanTask(workspaceId, itemId, wire)
  } catch (err) {
    if (mode === 'create_and_run') {
      notifyError(err)
      return { task: null as any, session: null }
    }
    throw err
  }
}
```

Run the spec. Expect pass. Run `bun run build` for typecheck.

Commit: `feat(kanban): add workspacesStore.addKanbanTask(mode, payload) action`

---

### Task 5: Frontend — Swap `KanbanView.handleCreateTaskSave` to the new action

**Files:**
- EDIT `src/apps/desktop/src/components/kanban/KanbanView.vue`
- EDIT `src/apps/desktop/src/__tests__/KanbanView.createAndRun.spec.ts`

#### Step 5.1 — Update the existing `createAndRun` test to assert the new call shape

Find the test "creates task and runs agent when mode is create_and_run" (or similar). Update the assertions:

```ts
expect(workspacesStore.addKanbanTask).toHaveBeenCalledWith(
  workspaceId, itemId, 'create_and_run',
  expect.objectContaining({ queue_message: 'Fix bug\n\nThe login button is broken' })
)
expect(workspacesStore.addTask).not.toHaveBeenCalled()
expect(workspacesStore.runAgentOnNewTask).not.toHaveBeenCalled()
```

Find the test "creates task only when mode is create" (or similar). Update:

```ts
expect(workspacesStore.addKanbanTask).toHaveBeenCalledWith(
  workspaceId, itemId, 'create',
  expect.objectContaining({ name: 'Fix bug', queue_message: undefined })
)
expect(workspacesStore.addTask).not.toHaveBeenCalled()
```

Run: `bunx vitest run src/apps/desktop/src/__tests__/KanbanView.createAndRun.spec.ts` — expect failure (handler still calls `addTask`).

#### Step 5.2 — Replace the handler body

In `KanbanView.vue::handleCreateTaskSave`:

```ts
const response = await workspacesStore.addKanbanTask(
  workspaceId, itemId,
  payload.mode,
  {
    name: payload.name,
    description: payload.description,
    tags: payload.tags,
    image_urls: payload.image_urls,
    cwd: payload.cwd,
    is_auto_retry_until_stop: payload.is_auto_retry_until_stop,
    selected_profile_model: payload.selected_profile_model,
    queue_message: payload.mode === 'create_and_run'
      ? (payload.description ? `${payload.name}\n\n${payload.description}` : payload.name)
      : undefined,
  },
)

if (response.task) {
  emit('selectTask', response.task)
}
```

Run the spec. Expect pass. Run `bun run build` for typecheck.

Commit: `refactor(kanban): route KanbanView.handleCreateTaskSave through addKanbanTask`

---

### Task 6: End-to-end smoke verification

**Files:** none

Run the full suite:
- Backend: `timeout 300 zig build test --summary all` — expect 2235 pass, 6 skip, 0 fail (or whatever current baseline is).
- Frontend: `timeout 60 bun run build` (typecheck) + `bunx vitest run` (behavioural) — expect green.

Boot the desktop app on port 8080, open the kanban, hit `+` on a column, type a task, click "Create task & run agent". Verify:
1. The task appears in the first column (auto-assign still works).
2. The chatview opens (selectTask still drives navigation).
3. The agent starts (queue_message reached the LLM, SSE session_created event fired).

Also smoke-test plain "Create task" (mode='create'):
- Verify no `sessions` row is created.
- Verify no `session_created` SSE event fires.

Commit: any green-fix commits discovered during smoke.

---

## Out of Scope (follow-ups to file as separate kanban tasks)

- **Drop the legacy `POST /api/.../tasks` call from `KanbanView`** — out of scope here; once the new endpoint is stable, remove the kanban branch from the generic handler so it serves only non-kanban items. This is a non-trivial change because `addTask` is also used by the legacy `taskCreate` flow.
- **Deprecate `runAgentOnNewTask`** — once `addKanbanTask('create_and_run')` is the sole caller, mark `runAgentOnNewTask` deprecated and route removal through a follow-up plan.
- **Open PR** with the new endpoint described in `docs/SPEC.md §10.2.1`.