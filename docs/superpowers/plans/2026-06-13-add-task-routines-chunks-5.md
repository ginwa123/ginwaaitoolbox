# Add Task Routines — Chunk 5: Frontend types & API client

**Why this chunk is first:** Every frontend file that handles a task (the store, the API, the dialogs, the row component, the sidebar) needs the `task_type` / `routine` shape and the new API functions. The picker / dialog / integration chunks (6 + 7) build on this. No UI work in this chunk — it's pure data-layer plumbing.

**Files touched:**

| File | Change |
|---|---|
| `src/apps/desktop/src/stores/workspaces.ts` | `Task` interface gains `task_type: 'standard' \| 'routine'` and `routine?: RoutineMeta`. New `RoutineMeta` interface. `addTask` signature accepts `{ name, description?, taskType?, routine? }`. New `runRoutine` + `updateRoutine` actions. |
| `src/apps/desktop/src/api/index.ts` | `createTask(workspaceId, itemId, params)` accepts the new params shape. New `runRoutine(workspaceId, itemId, taskId)` function. `updateTaskSimple` accepts routine fields in `fields`. |
| `src/apps/desktop/src/__tests__/workspacesStoreTaskTypes.spec.ts` | New: `addTask` passes `taskType` + `routine` through to the API; `runRoutine` POSTs to `/run` and routes; `updateRoutine` PATCHes the routine fields. |
| `src/apps/desktop/src/__tests__/apiRunRoutine.spec.ts` | New: `api.runRoutine` POSTs to the right URL with the right shape. |

---

## Task 5.1: Extend `Task` interface + `addTask` signature in `stores/workspaces.ts`

**Files:**
- Modify: `src/apps/desktop/src/stores/workspaces.ts:50-57` (Task interface) and `:425-454` (addTask)
- Test: `src/apps/desktop/src/__tests__/workspacesStoreTaskTypes.spec.ts` (new)

### Step 1: Write the failing test

Create `src/apps/desktop/src/__tests__/workspacesStoreTaskTypes.spec.ts`:

```ts
/**
 * Tests for the Task interface extension and the addTask signature
 * change. The `task_type` and `routine` fields are additive; the
 * `addTask` action accepts the new params shape and passes them
 * through to api.createTask.
 *
 * Backwards-compat: legacy tasks with no `task_type` field must
 * continue to render as 'standard' (see the WorkspaceItemTask
 * `task.task_type === 'routine'` guard, Chunk 7).
 */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { setActivePinia, createPinia } from 'pinia'

import * as api from '../api'
import { useWorkspacesStore } from '../stores/workspaces'
import { makeLocalStorageStub } from './helpers'

describe('useWorkspacesStore.addTask — routine support', () => {
  const createTaskMock = vi.fn()

  beforeEach(() => {
    setActivePinia(createPinia())
    Object.defineProperty(globalThis, 'localStorage', {
      value: makeLocalStorageStub(),
      writable: true,
      configurable: true,
    })

    vi.spyOn(api, 'createTask').mockImplementation(createTaskMock)
    // init()'s other API calls — defensive in case a future test triggers it.
    vi.spyOn(api, 'getWorkspaces').mockResolvedValue({ workspaces: [] })
    vi.spyOn(api, 'getWorkspacesItems').mockResolvedValue({ items: [], count: 0 })
    vi.spyOn(api, 'getTasks').mockResolvedValue({ tasks: [], has_more: false, next_cursor: null })
  })

  afterEach(() => {
    vi.restoreAllMocks()
    createTaskMock.mockReset()
  })

  function seedStore() {
    const ws = useWorkspacesStore()
    ws.workspaces = [
      {
        id: 'ws_1',
        name: 'W1',
        icon: '📁',
        expanded: true,
        items: [
          { id: 'item_a', name: 'A', item_type: 'folder', tasks: [] },
        ],
      },
    ]
    return ws
  }

  it('passes taskType="routine" + routine fields through to api.createTask for a routine task', async () => {
    const ws = seedStore()
    createTaskMock.mockResolvedValueOnce({
      id: 'task_routine_1',
      name: 'Daily standup',
      task_type: 'routine',
      routine: {
        schedule: '0 9 * * 1-5',
        initial_prompt: 'summarize commits',
        enabled: true,
        last_run_at: null,
        next_run_at: '2099-01-01 09:00:00',
        last_status: null,
        last_error: null,
      },
    })

    const routine = {
      schedule: '0 9 * * 1-5',
      initial_prompt: 'summarize commits',
      enabled: true,
    }
    const taskId = await ws.addTask('ws_1', 'item_a', {
      name: 'Daily standup',
      taskType: 'routine',
      routine,
    })

    expect(taskId).toBe('task_routine_1')
    expect(createTaskMock).toHaveBeenCalledTimes(1)
    expect(createTaskMock).toHaveBeenCalledWith('ws_1', 'item_a', {
      name: 'Daily standup',
      description: undefined,
      taskType: 'routine',
      routine,
    })
    // The returned task is unshifted into the item's task list.
    const tasks = ws.workspaces[0]!.items[0]!.tasks!
    expect(tasks).toHaveLength(1)
    expect(tasks[0]!.task_type).toBe('routine')
    expect(tasks[0]!.routine?.schedule).toBe('0 9 * * 1-5')
  })

  it('passes taskType="standard" through for a standard task (default path)', async () => {
    const ws = seedStore()
    createTaskMock.mockResolvedValueOnce({
      id: 'task_std_1',
      name: 'Quick chat',
      task_type: 'standard',
    })

    await ws.addTask('ws_1', 'item_a', {
      name: 'Quick chat',
      description: 'a quick test',
      taskType: 'standard',
    })

    expect(createTaskMock).toHaveBeenCalledWith('ws_1', 'item_a', {
      name: 'Quick chat',
      description: 'a quick test',
      taskType: 'standard',
      routine: undefined,
    })
  })

  it('defaults taskType to "standard" when omitted (backwards-compat with existing call sites)', async () => {
    const ws = seedStore()
    createTaskMock.mockResolvedValueOnce({ id: 'task_std_2', name: 'Old way', task_type: 'standard' })

    // Existing call sites pass (name, description) and rely on the
    // legacy signature. The modified signature must accept this
    // shape and forward taskType: 'standard' + routine: undefined.
    await ws.addTask('ws_1', 'item_a', {
      name: 'Old way',
      description: 'legacy call',
    })

    expect(createTaskMock).toHaveBeenCalledWith('ws_1', 'item_a', {
      name: 'Old way',
      description: 'legacy call',
      taskType: 'standard',
      routine: undefined,
    })
  })

  it('falls back to a local-only task if the API call fails (preserves the legacy fallback contract)', async () => {
    const ws = seedStore()
    createTaskMock.mockRejectedValueOnce(new Error('network down'))

    const taskId = await ws.addTask('ws_1', 'item_a', {
      name: 'Offline',
      taskType: 'routine',
      routine: { schedule: '*/5 * * * *', initial_prompt: 'x', enabled: true },
    })

    expect(taskId).toBeDefined()
    const tasks = ws.workspaces[0]!.items[0]!.tasks!
    expect(tasks).toHaveLength(1)
    // The fallback task has task_type: 'routine' + routine fields
    // so the UI still works offline.
    expect(tasks[0]!.task_type).toBe('routine')
    expect(tasks[0]!.routine?.schedule).toBe('*/5 * * * *')
  })
})
```

### Step 2: Run the test, verify it FAILS

Run: `cd src/apps/desktop && timeout 120 bunx vitest run src/__tests__/workspacesStoreTaskTypes.spec.ts 2>&1 | tail -n 30`
Expected: FAIL with `TypeError: ws.addTask is not a function (it expected ... 3 separate args ...)` — the current `addTask(workspaceId, itemId, name, description?)` signature doesn't accept a `{ name, description?, taskType?, routine? }` object, and the `Task` type doesn't have `task_type` / `routine` fields yet.

### Step 3: Write the implementation

**3a. Extend the `Task` interface and add `RoutineMeta`** in `src/apps/desktop/src/stores/workspaces.ts:50-57`:

```ts
// Task interface for project tasks
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
  // NEW (Chunk 5 of task-routines plan): distinguishes standard chat
  // tasks from cron-scheduled routines. Defaults to 'standard' for
  // legacy data — see the `task.task_type === 'routine'` guard in
  // WorkspaceItemTask.vue and the WorkspaceItemTask / Sidebar tests.
  task_type: 'standard' | 'routine'
  // NEW: present iff task_type === 'routine'. Mirrors the API
  // response shape from getTasks / createTask. Optional on the
  // type for ergonomic narrow guards in templates.
  routine?: RoutineMeta
  completed?: boolean
  createdAt?: Date
  updatedAt?: Date
}
```

**3b. Replace the `addTask` action** at `src/apps/desktop/src/stores/workspaces.ts:425-454` with:

```ts
// Add a task to a workspace item.
//
// New (Chunk 5): the third arg is a single params object that
// carries name, description, taskType, and (for routines) the
// routine fields. The legacy 4-arg signature was
// (workspaceId, itemId, name, description?); that call shape
// is now gone (no other call site uses it — see git grep for
// `addTask(`.).
//
// taskType defaults to 'standard' so a caller that omits it
// gets the legacy behavior. For routines, `routine` must
// include `schedule` + `initial_prompt`; `enabled` defaults
// to true on the backend.
async function addTask(
  workspaceId: string,
  itemId: string,
  params: {
    name: string
    description?: string
    taskType?: 'standard' | 'routine'
    routine?: {
      schedule: string
      initial_prompt: string
      enabled?: boolean
    }
  },
): Promise<string | undefined> {
  const workspace = workspaces.value.find((ws) => ws.id === workspaceId)
  if (!workspace) return undefined

  const item = workspace.items.find((i) => i.id === itemId)
  if (!item) return undefined

  if (!item.tasks) {
    item.tasks = []
  }

  const taskType: 'standard' | 'routine' = params.taskType ?? 'standard'

  try {
    const newTask = await api.createTask(workspaceId, itemId, {
      name: params.name,
      description: params.description,
      taskType,
      routine: params.routine,
    })
    item.tasks.unshift(newTask)
    return newTask.id
  } catch (err) {
    console.error('Failed to create task:', err)
    // Fallback to local creation if API fails. Match the
    // pre-existing fallback contract (returns a taskId, populates
    // the item's tasks list) and now also carry task_type +
    // routine so the offline UI still branches correctly.
    const taskId = `task-${Date.now()}`
    item.tasks.unshift({
      id: taskId,
      name: params.name,
      description: params.description,
      task_type: taskType,
      routine: params.routine
        ? {
            schedule: params.routine.schedule,
            initial_prompt: params.routine.initial_prompt,
            enabled: params.routine.enabled ?? true,
            last_run_at: null,
            next_run_at: '',
            last_status: null,
            last_error: null,
          }
        : undefined,
      completed: false,
      createdAt: new Date(),
      updatedAt: new Date(),
    })
    return taskId
  }
}
```

**3c. Add `runRoutine` + `updateRoutine` to the return object** at `src/apps/desktop/src/stores/workspaces.ts:935` (next to the other actions). The implementations are added in Task 5.3; for now leave a stub so the type-check passes:

```ts
// (Implemented in Task 5.3; stubs here keep the type-check green
// while Task 5.1 is in review.)
async function runRoutine(
  _workspaceId: string,
  _itemId: string,
  _taskId: string,
): Promise<{ session_id: string } | undefined> {
  return undefined
}

async function updateRoutine(
  _workspaceId: string,
  _itemId: string,
  _taskId: string,
  _fields: {
    name?: string
    description?: string
    schedule?: string
    initial_prompt?: string
    enabled?: boolean
  },
): Promise<{ success: boolean }> {
  return { success: false }
}
```

And add `runRoutine,` / `updateRoutine,` to the return object (around line 935). This is a placeholder — Task 5.3 replaces it with the real implementation.

### Step 4: Run the test, verify it PASSES

Run: `cd src/apps/desktop && timeout 120 bunx vitest run src/__tests__/workspacesStoreTaskTypes.spec.ts 2>&1 | tail -n 30`
Expected: PASS (4/4 tests).

### Step 5: Type-check + commit

```bash
cd src/apps/desktop
timeout 120 bun run build 2>&1 | tail -n 20
```

Expected: clean (no TS errors). The `Task` interface addition is backwards-compatible because all existing literal `Task` constructions in the codebase set `id` and `name`; the new `task_type: 'standard' | 'routine'` field is required but every existing call site constructs the `Task` via `api.createTask` (which will return the field) or via the literal `{ id, name, ... }` pattern. **`Sidebar.vue:444-447` builds a `Task` literal in the fast-path** — it does not currently set `task_type`. After this change, the type-check will flag it. That's expected: the fast-path is removed in Chunk 7, but the type-check still wants the field. **Add `task_type: 'standard' as const` to that literal as part of this task.** (We are not removing the fast-path yet — that's Chunk 7's job — but the literal needs the new required field to pass the build.)

```bash
git add src/apps/desktop/src/stores/workspaces.ts \
        src/apps/desktop/src/components/Sidebar.vue \
        src/apps/desktop/src/__tests__/workspacesStoreTaskTypes.spec.ts
git commit -m "feat(routines): Task interface gains task_type + routine; addTask accepts params object"
```

---

## Task 5.2: Extend `api/index.ts` — `createTask` params + new `runRoutine`

**Files:**
- Modify: `src/apps/desktop/src/api/index.ts:50-60` (Task interface), `:214-227` (createTask), `:247-259` (updateTaskSimple)
- Create: `src/apps/desktop/src/api/index.ts:260-280` (new runRoutine function)
- Test: `src/apps/desktop/src/__tests__/apiRunRoutine.spec.ts` (new)

### Step 1: Write the failing test

Create `src/apps/desktop/src/__tests__/apiRunRoutine.spec.ts`:

```ts
/**
 * Unit tests for the api.runRoutine function and the modified
 * createTask / updateTaskSimple signatures. Mocks global.fetch to
 * assert URL, method, headers, and body shape.
 */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'

import { createTask, runRoutine, updateTaskSimple } from '../api'

describe('api.runRoutine', () => {
  const originalFetch = global.fetch
  const fetchMock = vi.fn()

  beforeEach(() => {
    fetchMock.mockReset()
    global.fetch = fetchMock as unknown as typeof fetch
  })

  afterEach(() => {
    global.fetch = originalFetch
  })

  function mockFetchOnce(status: number, body: unknown) {
    fetchMock.mockResolvedValueOnce({
      ok: status >= 200 && status < 300,
      status,
      json: () => Promise.resolve(body),
    } as Response)
  }

  it('POSTs to /api/workspaces/:w/items/:i/tasks/:tid/run with an empty body', async () => {
    mockFetchOnce(200, { session_id: 'task_alpha' })

    const result = await runRoutine('ws_1', 'item_1', 'task_alpha')

    expect(result).toEqual({ session_id: 'task_alpha' })
    expect(fetchMock).toHaveBeenCalledTimes(1)
    const [url, init] = fetchMock.mock.calls[0] as [string, RequestInit]
    expect(url).toBe('/api/workspaces/ws_1/items/item_1/tasks/task_alpha/run')
    expect(init.method).toBe('POST')
    // Body is empty (the backend doesn't need any input — it
    // already knows the routine from the path).
    expect(init.body).toBeUndefined()
  })

  it('returns { session_id } on 200', async () => {
    mockFetchOnce(200, { session_id: 'task_xyz' })
    const result = await runRoutine('ws', 'item', 'task_xyz')
    expect(result.session_id).toBe('task_xyz')
  })

  it('throws on non-2xx (409 if routine is disabled / already running)', async () => {
    mockFetchOnce(409, { error: 'routine disabled' })
    await expect(runRoutine('ws', 'item', 'task_off')).rejects.toThrow(/HTTP 409/)
  })
})

describe('api.createTask (extended signature)', () => {
  const originalFetch = global.fetch
  const fetchMock = vi.fn()

  afterEach(() => {
    fetchMock.mockReset()
    global.fetch = originalFetch
  })

  function mockFetchOnce(status: number, body: unknown) {
    fetchMock.mockResolvedValueOnce({
      ok: status >= 200 && status < 300,
      status,
      json: () => Promise.resolve(body),
    } as Response)
    global.fetch = fetchMock as unknown as typeof fetch
  }

  it('sends taskType="routine" + routine fields in the body for a routine task', async () => {
    mockFetchOnce(200, { id: 'task_1', name: 'Daily', task_type: 'routine' })

    await createTask('ws_1', 'item_1', {
      name: 'Daily',
      description: 'standup summary',
      taskType: 'routine',
      routine: {
        schedule: '0 9 * * 1-5',
        initial_prompt: 'summarize commits',
        enabled: true,
      },
    })

    expect(fetchMock).toHaveBeenCalledTimes(1)
    const [url, init] = fetchMock.mock.calls[0] as [string, RequestInit]
    expect(url).toBe('/api/workspaces/ws_1/items/item_1/tasks')
    expect(init.method).toBe('POST')
    expect(JSON.parse(init.body as string)).toEqual({
      name: 'Daily',
      description: 'standup summary',
      task_type: 'routine',
      schedule: '0 9 * * 1-5',
      initial_prompt: 'summarize commits',
      enabled: true,
    })
  })

  it('sends taskType="standard" with no routine fields for a standard task', async () => {
    mockFetchOnce(200, { id: 'task_2', name: 'Chat', task_type: 'standard' })

    await createTask('ws_1', 'item_1', {
      name: 'Chat',
      description: undefined,
      taskType: 'standard',
    })

    const [, init] = fetchMock.mock.calls[0] as [string, RequestInit]
    const body = JSON.parse(init.body as string)
    expect(body.task_type).toBe('standard')
    expect(body.schedule).toBeUndefined()
    expect(body.initial_prompt).toBeUndefined()
  })
})

describe('api.updateTaskSimple (routine fields)', () => {
  const originalFetch = global.fetch
  const fetchMock = vi.fn()

  afterEach(() => {
    fetchMock.mockReset()
    global.fetch = originalFetch
  })

  function mockFetchOnce(status: number, body: unknown) {
    fetchMock.mockResolvedValueOnce({
      ok: status >= 200 && status < 300,
      status,
      json: () => Promise.resolve(body),
    } as Response)
    global.fetch = fetchMock as unknown as typeof fetch
  }

  it('forwards schedule + initial_prompt + enabled through the body for an EditRoutine submit', async () => {
    mockFetchOnce(200, { success: true })

    await updateTaskSimple('task_1', {
      name: 'Daily standup',
      schedule: '0 10 * * 1-5',
      initial_prompt: 'summarize commits',
      enabled: true,
    })

    const [url, init] = fetchMock.mock.calls[0] as [string, RequestInit]
    expect(url).toBe('/api/workspaces/tasks/task_1')
    expect(init.method).toBe('PUT')
    expect(JSON.parse(init.body as string)).toEqual({
      name: 'Daily standup',
      schedule: '0 10 * * 1-5',
      initial_prompt: 'summarize commits',
      enabled: true,
    })
  })
})
```

### Step 2: Run the test, verify it FAILS

Run: `cd src/apps/desktop && timeout 120 bunx vitest run src/__tests__/apiRunRoutine.spec.ts 2>&1 | tail -n 30`
Expected: FAIL with `TypeError: api.runRoutine is not a function` (the function doesn't exist yet) and TS errors about `createTask`'s signature mismatch.

### Step 3: Write the implementation

**3a. Extend the `Task` interface** in `src/apps/desktop/src/api/index.ts:50-60`:

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
  // NEW (Chunk 5 of task-routines plan)
  task_type: 'standard' | 'routine'
  routine?: RoutineMeta
  completed?: boolean
  createdAt?: Date
  updatedAt?: Date
}
```

**3b. Replace `createTask`** at `src/apps/desktop/src/api/index.ts:214-227` with:

```ts
/**
 * Create a task under a workspace item.
 *
 * The third arg is a single params object. For a standard task
 * (the default), pass `{ name, description?, taskType: 'standard' }`.
 * For a routine, pass `{ name, taskType: 'routine', routine: { schedule, initial_prompt, enabled? } }`.
 *
 * The backend stores `task_type` on `workspace_item_tasks` and
 * (for routines) creates a row in the `routines` table inside the
 * same transaction. On a bad cron expression, the backend
 * returns 400 and the error surfaces as a thrown `Error('HTTP 400')`.
 */
export async function createTask(
  workspaceId: string,
  itemId: string,
  params: {
    name: string
    description?: string
    taskType?: 'standard' | 'routine'
    routine?: {
      schedule: string
      initial_prompt: string
      enabled?: boolean
    }
  },
): Promise<Task> {
  const taskType = params.taskType ?? 'standard'
  const body: Record<string, unknown> = {
    name: params.name,
    description: params.description,
    task_type: taskType,
  }
  if (taskType === 'routine' && params.routine) {
    body.schedule = params.routine.schedule
    body.initial_prompt = params.routine.initial_prompt
    if (params.routine.enabled !== undefined) {
      body.enabled = params.routine.enabled
    }
  }
  const response = await fetch(`${API_BASE}/workspaces/${workspaceId}/items/${itemId}/tasks`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(body),
  })
  if (!response.ok) throw new Error(`HTTP ${response.status}`)
  return response.json()
}
```

**3c. Add `runRoutine`** (after `deleteTask` at line 272):

```ts
/**
 * Manually fire a routine. Returns the session_id (which equals
 * the task_id per the codebase invariant task.id == session_id)
 * the routine will run in. The backend responds 200 + body as
 * soon as the sub-process is spawned — the actual LLM call
 * happens asynchronously.
 *
 * 404: task is not a routine (or doesn't exist)
 * 409: routine is disabled or another fire is in progress
 * 500: spawn failed
 */
export async function runRoutine(
  workspaceId: string,
  itemId: string,
  taskId: string,
): Promise<{ session_id: string }> {
  const response = await fetch(
    `${API_BASE}/workspaces/${workspaceId}/items/${itemId}/tasks/${taskId}/run`,
    { method: 'POST' },
  )
  if (!response.ok) throw new Error(`HTTP ${response.status}`)
  return response.json()
}
```

**3d. Extend `updateTaskSimple`** at `src/apps/desktop/src/api/index.ts:247-259` to accept routine fields:

```ts
// Task API - Simple version (just task_id + optional fields)
//
// The backend's PUT /api/workspaces/tasks/:task_id accepts a
// subset of fields. Routine fields (`schedule`, `initial_prompt`,
// `enabled`) are accepted alongside the standard name/session_id.
// The server cascades any name change to the linked session and
// re-broadcasts via SSE.
export async function updateTaskSimple(
  taskId: string,
  data: {
    name?: string
    session_id?: string
    // NEW (Chunk 5 of task-routines plan)
    schedule?: string
    initial_prompt?: string
    enabled?: boolean
  },
): Promise<{ success: boolean }> {
  const response = await fetch(`${API_BASE}/workspaces/tasks/${taskId}`, {
    method: 'PUT',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(data),
  })
  if (!response.ok) throw new Error(`HTTP ${response.status}`)
  return response.json()
}
```

### Step 4: Run the test, verify it PASSES

Run: `cd src/apps/desktop && timeout 120 bunx vitest run src/__tests__/apiRunRoutine.spec.ts 2>&1 | tail -n 30`
Expected: PASS (5/5 tests).

### Step 5: Type-check + commit

```bash
cd src/apps/desktop
timeout 120 bun run build 2>&1 | tail -n 20
```

Expected: clean. The existing `workspacesStoreRenameTask.spec.ts` calls `api.updateTaskSimple('task_1', { name: 'New Name' })` — the new optional fields keep that call shape valid.

```bash
git add src/apps/desktop/src/api/index.ts \
        src/apps/desktop/src/__tests__/apiRunRoutine.spec.ts
git commit -m "feat(routines): api.createTask accepts routine params; new api.runRoutine; updateTaskSimple accepts routine fields"
```

---

## Task 5.3: Implement `runRoutine` + `updateRoutine` store actions

**Files:**
- Modify: `src/apps/desktop/src/stores/workspaces.ts` (replace the stubs from Task 5.1 with the real implementations)
- Test: `src/apps/desktop/src/__tests__/workspacesStoreTaskTypes.spec.ts` (extend the file with `runRoutine` and `updateRoutine` tests)

### Step 1: Write the failing test

Append to `src/apps/desktop/src/__tests__/workspacesStoreTaskTypes.spec.ts` (the file from Task 5.1). Add new `describe` blocks after the existing one:

```ts
describe('useWorkspacesStore.runRoutine', () => {
  const runRoutineApiMock = vi.fn()

  beforeEach(() => {
    setActivePinia(createPinia())
    Object.defineProperty(globalThis, 'localStorage', {
      value: makeLocalStorageStub(),
      writable: true,
      configurable: true,
    })
    vi.spyOn(api, 'runRoutine').mockImplementation(runRoutineApiMock)
    vi.spyOn(api, 'createTask').mockResolvedValue({
      id: 'task_1',
      name: 'Daily',
      task_type: 'routine',
    })
  })

  afterEach(() => {
    vi.restoreAllMocks()
    runRoutineApiMock.mockReset()
  })

  function seedStore() {
    const ws = useWorkspacesStore()
    ws.workspaces = [
      {
        id: 'ws_1',
        name: 'W1',
        icon: '📁',
        expanded: true,
        items: [
          { id: 'item_a', name: 'A', item_type: 'folder', tasks: [
            { id: 'task_routine_1', name: 'Daily', task_type: 'routine' },
          ] },
        ],
      },
    ]
    return ws
  }

  it('calls api.runRoutine with (workspaceId, itemId, taskId) and returns the session_id', async () => {
    const ws = seedStore()
    runRoutineApiMock.mockResolvedValueOnce({ session_id: 'task_routine_1' })

    const result = await ws.runRoutine('ws_1', 'item_a', 'task_routine_1')

    expect(runRoutineApiMock).toHaveBeenCalledWith('ws_1', 'item_a', 'task_routine_1')
    expect(result).toEqual({ session_id: 'task_routine_1' })
  })

  it('returns undefined (does not throw) if the API call fails — the caller (Sidebar) handles the error toast', async () => {
    const ws = seedStore()
    runRoutineApiMock.mockRejectedValueOnce(new Error('409 conflict'))

    // We don't want a console.error to fail the test; silence it.
    const consoleErrSpy = vi.spyOn(console, 'error').mockImplementation(() => {})
    const result = await ws.runRoutine('ws_1', 'item_a', 'task_routine_1')
    consoleErrSpy.mockRestore()

    expect(result).toBeUndefined()
  })
})

describe('useWorkspacesStore.updateRoutine', () => {
  const updateTaskSimpleMock = vi.fn()

  beforeEach(() => {
    setActivePinia(createPinia())
    Object.defineProperty(globalThis, 'localStorage', {
      value: makeLocalStorageStub(),
      writable: true,
      configurable: true,
    })
    vi.spyOn(api, 'updateTaskSimple').mockImplementation(updateTaskSimpleMock)
  })

  afterEach(() => {
    vi.restoreAllMocks()
    updateTaskSimpleMock.mockReset()
  })

  it('forwards routine fields + name through to api.updateTaskSimple', async () => {
    const ws = useWorkspacesStore()
    ws.workspaces = [
      {
        id: 'ws_1', name: 'W1', icon: '📁', expanded: true,
        items: [
          { id: 'item_a', name: 'A', item_type: 'folder', tasks: [
            { id: 'task_r_1', name: 'Old', task_type: 'routine' },
          ] },
        ],
      },
    ]
    updateTaskSimpleMock.mockResolvedValueOnce({ success: true })

    await ws.updateRoutine('ws_1', 'item_a', 'task_r_1', {
      name: 'New name',
      schedule: '0 10 * * 1-5',
      initial_prompt: 'updated prompt',
      enabled: false,
    })

    expect(updateTaskSimpleMock).toHaveBeenCalledTimes(1)
    expect(updateTaskSimpleMock).toHaveBeenCalledWith('task_r_1', {
      name: 'New name',
      schedule: '0 10 * * 1-5',
      initial_prompt: 'updated prompt',
      enabled: false,
    })
  })

  it('updates the task name optimistically in the local tree', async () => {
    const ws = useWorkspacesStore()
    ws.workspaces = [
      {
        id: 'ws_1', name: 'W1', icon: '📁', expanded: true,
        items: [
          { id: 'item_a', name: 'A', item_type: 'folder', tasks: [
            { id: 'task_r_1', name: 'Old', task_type: 'routine' },
          ] },
        ],
      },
    ]
    updateTaskSimpleMock.mockResolvedValueOnce({ success: true })

    await ws.updateRoutine('ws_1', 'item_a', 'task_r_1', { name: 'Renamed' })
    expect(ws.workspaces[0]!.items[0]!.tasks![0]!.name).toBe('Renamed')
  })
})
```

### Step 2: Run the test, verify it FAILS

Run: `cd src/apps/desktop && timeout 120 bunx vitest run src/__tests__/workspacesStoreTaskTypes.spec.ts 2>&1 | tail -n 30`
Expected: FAIL — the stubs from Task 5.1 return `undefined` / `{ success: false }` regardless of input, so the success-path assertions fail.

### Step 3: Write the implementation

**Replace the stubs** in `src/apps/desktop/src/stores/workspaces.ts` (the stubs added in Task 5.1) with the real implementations:

```ts
// Manually fire a routine. Returns the backend's
// `{ session_id }` on success, or `undefined` on failure (the
// caller's responsibility to navigate / show an error).
//
// We deliberately do NOT navigate here — that's a UI concern
// owned by Sidebar.vue. The store action is pure: it calls
// the API and returns the result. This matches the
// `addTask` pattern (store action returns a taskId; the
// component decides what to do with it).
async function runRoutine(
  workspaceId: string,
  itemId: string,
  taskId: string,
): Promise<{ session_id: string } | undefined> {
  try {
    return await api.runRoutine(workspaceId, itemId, taskId)
  } catch (err) {
    console.error('Failed to run routine:', err)
    return undefined
  }
}

// PATCH-equivalent for routine tasks. The backend's
// updateTaskSimple accepts name + routine fields, so this is
// a thin wrapper that calls the API and updates the local
// task's name (optimistic) on success. Schedule + initial_prompt
// + enabled live on the routine row; their updates surface via
// the routines table's next refresh (or the SSE event the
// backend emits on update — see Chunk 4 for the broadcast).
async function updateRoutine(
  workspaceId: string,
  itemId: string,
  taskId: string,
  fields: {
    name?: string
    description?: string
    schedule?: string
    initial_prompt?: string
    enabled?: boolean
  },
): Promise<{ success: boolean }> {
  const workspace = workspaces.value.find((ws) => ws.id === workspaceId)
  if (!workspace) return { success: false }
  const item = workspace.items.find((i) => i.id === itemId)
  if (!item || !item.tasks) return { success: false }
  const task = item.tasks.find((t) => t.id === taskId)
  if (!task) return { success: false }

  const previousName = task.name
  if (fields.name !== undefined && fields.name.trim() !== task.name) {
    task.name = fields.name.trim()
  }

  try {
    return await api.updateTaskSimple(taskId, fields)
  } catch (err) {
    console.error('Failed to update routine:', err)
    // Rollback the optimistic name change on error.
    task.name = previousName
    return { success: false }
  }
}
```

And add `runRoutine,` + `updateRoutine,` to the `return { ... }` block of the store (alongside the other actions). The location is the existing `return` block at the bottom of the `useWorkspacesStore` function (around line 905 in the pre-Chunk-5 version).

### Step 4: Run the test, verify it PASSES

Run: `cd src/apps/desktop && timeout 120 bunx vitest run src/__tests__/workspacesStoreTaskTypes.spec.ts 2>&1 | tail -n 30`
Expected: PASS (4 + 2 + 2 = 8 tests, all green).

### Step 5: Type-check + commit

```bash
cd src/apps/desktop
timeout 120 bun run build 2>&1 | tail -n 20
```

Expected: clean.

```bash
git add src/apps/desktop/src/stores/workspaces.ts \
        src/apps/desktop/src/__tests__/workspacesStoreTaskTypes.spec.ts
git commit -m "feat(routines): runRoutine + updateRoutine store actions"
```

---

## Chunk 5 done — checkpoint

- ✅ `Task` interface has `task_type` + `routine`
- ✅ `addTask` accepts `{ name, description?, taskType?, routine? }`
- ✅ `api.createTask` + `api.updateTaskSimple` accept routine fields
- ✅ `api.runRoutine` POSTs to the new `/run` endpoint
- ✅ `workspacesStore.runRoutine` + `workspacesStore.updateRoutine` actions

Next: **Chunk 6 — Frontend dialogs** (`AddTaskPickerDialog`, `AddRoutineDialog`, `EditRoutineDialog`, wire `AddTaskDialog`). See `chunks-6.md`.
