# Kanban SSE Auto-Move — Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** When the backend emits a `kanban_task.*` SSE event (task moved / assigned / unassigned between kanban columns), the `KanbanView.vue` card MUST visibly move to the new column without manual reload. Today the SSE pipeline emits the event but the frontend handler does not update the tasks in the Pinia store, so the card stays in the old column visually.

**Architecture:** Two surgical changes in the frontend:

1. **Add `fetchKanbanTasks(workspaceId, itemId)`** to the workspaces store — calls the existing `api.getTasks` and replaces `item.tasks` (mirror of the existing `fetchKanbanColumns` action, but for the tasks array).
2. **Dispatch SSE events by family** in `kanbanSse.ts` — `kanban_column.*` events continue to call `fetchKanbanColumns`; `kanban_task.*` events now call the new `fetchKanbanTasks`. The backend already emits sibling renumbering as part of every move (see `kanban_model.moveTask` step 2 + 3 in the design doc), so a full task re-fetch is the simplest correct action — in-place client-side renumbering would require the SSE payload to include the new positions of every sibling, which it does not.

**Tech Stack:** Vue 3 + Pinia + Vitest frontend; existing `apiSseClient` reconnect wrapper; `api.getTasks` REST wrapper (already exists).

**Spec / context:**
- Bug report (2026-06-27): When a kanban task is moved by an external actor (AI agent via `kanban_move_task`, or another connected client), the card does NOT visually move in the open `KanbanView.vue`. The card stays in the old column with stale `kanban_position`. After a hard reload, the card appears in the correct column (proving the backend moved it). The SSE event IS arriving on the wire — `DevTools → Network → /api/kanban/events` shows `kanban_task` events — but the frontend handler ignores the task data and only re-fetches columns.
- Diagnosis: `src/apps/desktop/src/stores/kanbanSse.ts:68` has `void ws.fetchKanbanColumns(event.workspace_id, event.item_id)` for EVERY event regardless of family. `fetchKanbanColumns` only replaces `item.kanban_columns` — it does NOT touch `item.tasks`. The `KanbanColumn.vue:89-101` computed `cardsInColumn` filters `props.tasks` by `t.kanban_column_id === props.column.id`, so without a `item.tasks` update, the cards never re-filter.
- Previous fix attempt: PR #38 (commit `d585a4b6`) added the entire SSE pipeline (backend events, frontend factory + store, AppLayout wiring, tests). It shipped the COLUMN auto-refresh but missed the TASK auto-refresh — the same handler was used for both event families. The user's task name (`kanban-sse-auto-move`) was filed against the parent plan (2026-06-26) but the work was not picked up before the parent plan merged.
- Task: `kanban-sse-auto-move` (workspace `ws_1779002584293_e52cd134532e1f00`, kanban board item `item_1782442554104741821`).

---

## Context

### Current state

**Backend (already complete, no changes needed):**
- `src/ai_workflow/tui/on_event_sent_kanban.zig` — emits `kanban_column` events on column create/update/delete/reorder and `kanban_task` events on task move/assign/unassign. Each event payload includes `workspace_id`, `item_id`, and the action-specific fields (column_id, new_name, new_position, task_id, new_column_id, new_position). Wired into the 6 existing kanban HTTP handlers per PR #38.
- `src/modules/custom_http_server/src/sse_manager.zig` — fans out `event_bus` emissions to all subscribed SSE clients. The `kanban_*` routing keys are global (every connected client receives every kanban event), so client-side filtering by `workspace_id` is required.

**Frontend (the bug is here):**
- `src/apps/desktop/src/api/index.ts:1900-1935` — `createKanbanSseConnection(opts)` factory is wired correctly. Returns a `SseClient` with the reconnect-aware wrapper. The factory parses incoming JSON and dispatches a typed `KanbanColumnEvent | KanbanTaskEvent` to `onEvent`.
- `src/apps/desktop/src/stores/kanbanSse.ts:57-69` — the SSE event handler. **Bug:** treats both event families identically with a single `fetchKanbanColumns` call. Column events work; task events are silently dropped on the floor as far as the task data is concerned.
- `src/apps/desktop/src/stores/workspaces.ts:663-682` — `fetchKanbanColumns` action replaces `item.kanban_columns`. There is NO equivalent action for `item.tasks`; `getTasks` is called once during `init()` per item, never refreshed.
- `src/apps/desktop/src/components/KanbanView.vue:112` — `const tasks = computed<Task[]>(() => props.item.tasks ?? [])`. Pass-through to `<KanbanColumn :tasks="tasks" />` (line 241). Vue 3 reactivity means a store-level mutation to `item.tasks` triggers the computed to re-evaluate.
- `src/apps/desktop/src/components/KanbanColumn.vue:89-101` — `cardsInColumn = computed(() => props.tasks.filter(t => t.kanban_column_id === props.column.id).sort(...))`. The card appears under the column matching its `kanban_column_id`, in order of `kanban_position`. When a SSE event updates `item.tasks` in the store, this computed re-evaluates and the card visually moves.
- `src/apps/desktop/src/components/AppLayout.vue:93-113` — initializes the kanban SSE on mount, updates the filter on workspace switch, tears down on unmount. Idempotent; no change needed.

### What's already in place

- `api.getTasks(workspaceId, itemId, limit=20, cursor?, sortBy='updated_at', direction='desc')` returns `{ tasks, has_more, next_cursor }` — the canonical way to refresh an item's task list from the frontend. Newest-first by `updated_at`.
- `useWorkspacesStore.findItem(workspaceId, itemId)` helper for locating the live item reference.
- The Pinia store pattern: optimistic update + rollback on API failure (mirrors `renameTask`, `pinTask`, etc.).
- The `kanbanSse.spec.ts` test harness uses `vi.spyOn(api, 'createKanbanSseConnection')` to capture the `onEvent` callback and dispatch synthetic events. Tests can spy on any store action via `vi.spyOn(ws, 'fetchKanbanColumns')` etc.

### Out of scope

- In-place client-side patch of the moved task + sibling renumbering (a future optimization — would require the SSE payload to include the new positions of every sibling). v1 re-fetches.
- Per-task SSE subscriptions (the routing key stays global; the client filter is what scopes events to the active workspace).
- Multi-tab sync (one SSE connection per tab is acceptable, matches the existing sessions/workers pattern).
- Showing a toast on SSE-driven task moves (silent auto-move is the desired UX; the user only sees the result).

---

## File Structure

### Modified frontend files (TS / Vue)

| File | Change |
|---|---|
| `src/apps/desktop/src/stores/workspaces.ts` | Add `fetchKanbanTasks(workspaceId, itemId)` action — calls `api.getTasks`, replaces `item.tasks`. Export from the store's return object. |
| `src/apps/desktop/src/stores/kanbanSse.ts` | Branch the `onEvent` handler on `event.action`: column-family events (`kanban_column.*`) call `fetchKanbanColumns`; task-family events (`kanban_task.*`) call the new `fetchKanbanTasks`. Workspace filter still gates by `event.workspace_id`. |
| `src/apps/desktop/src/__tests__/kanbanSse.spec.ts` | Replace the "kanban_task events trigger fetchKanbanColumns" test with one that asserts they trigger `fetchKanbanTasks`. Add coverage for `assigned` and `unassigned` actions. Add a "column events still trigger fetchKanbanColumns" test (replace the loose check). |
| `src/apps/desktop/src/__tests__/workspacesStoreKanbanTasks.spec.ts` | NEW: tests for `fetchKanbanTasks` (success path + API failure rollback + missing item no-op). |

### Modified frontend files (KanbanView.vue)

| File | Change |
|---|---|
| `src/apps/desktop/src/components/KanbanView.vue` | NO code change required. The component already renders `props.item.tasks` via a `computed`, and Vue 3 reactivity will re-render when the store updates `item.tasks`. The plan's only KanbanView.vue-adjacent change is to update the doc comment at the top to note "auto-refreshes on kanban_task.* SSE events via the workspacesStore.fetchKanbanTasks action". |

---

## Defaults locked by this plan

1. **Dispatch policy:** `kanban_column.*` → `fetchKanbanColumns`; `kanban_task.*` → `fetchKanbanTasks`. No fallback to "always re-fetch both" (would do 2× the HTTP work for every event).
2. **Refresh strategy:** Full re-fetch on `kanban_task.*` events (not in-place patch). Simpler, correct, covers sibling renumbering. In-place patch can be a future optimization once the SSE payload grows to include sibling positions.
3. **No optimistic update:** The SSE event is the backend's confirmation that the move succeeded; no local mutation is needed before the re-fetch resolves.
4. **Workspace filter:** Unchanged — events for other workspaces are dropped at the SSE handler level (`kanbanSse.ts:62`). The store action silently no-ops when the item isn't found locally (`findItem` returns undefined).
5. **Failure mode:** If the re-fetch fails (network blip), the next SSE event will trigger another fetch. No toast / banner — silent failure matches the existing `fetchKanbanColumns` behavior.
6. **Pagination:** `fetchKanbanTasks` uses the default `api.getTasks` page size (20 tasks, sorted by `updated_at desc`). For kanbans with >20 tasks, only the most recently updated 20 are kept in the local store (matches the current `init()` behavior). A future task can add pagination-aware refresh if needed; v1 is fine for the realistic kanban sizes (3–20 columns × 1–5 tasks each = 3–100 tasks).

---

## Chunk 1: Add `fetchKanbanTasks` action to workspaces store

**Goal:** Provide a single store action that refreshes `item.tasks` from the backend. Mirrors the existing `fetchKanbanColumns` action in shape and error semantics.

**Files touched:**
- `src/apps/desktop/src/stores/workspaces.ts` (modify — add action, export from store)

### Task 1.1: Write the failing test

**Files:**
- Create: `src/apps/desktop/src/__tests__/workspacesStoreKanbanTasks.spec.ts`

- [ ] **Step 1: Write the test file**

```ts
/**
 * Tests for the workspacesStore.fetchKanbanTasks action (added by
 * docs/superpowers/plans/2026-06-27-kanban-sse-auto-move.md).
 *
 * Mirrors the existing fetchKanbanColumns test coverage in spirit:
 * the action is the bridge between the SSE event handler and the
 * Pinia store, so the contract being tested is "calling
 * fetchKanbanTasks replaces item.tasks with the backend's response".
 *
 * Mock pattern: vi.spyOn(api, 'getTasks') returns a stubbed
 * { tasks, has_more, next_cursor } shape. Tests assert the local
 * store's `item.tasks` array matches the API response.
 */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { setActivePinia, createPinia } from 'pinia'

import * as api from '../api'
import type { Task, WorkspaceItem } from '../stores/workspaces'
import { useWorkspacesStore } from '../stores/workspaces'
import { makeLocalStorageStub } from './helpers'

const WS_ID = 'ws_test'
const ITEM_ID = 'item_test'

const makeItem = (overrides: Partial<WorkspaceItem> = {}): WorkspaceItem => ({
  id: ITEM_ID,
  name: 'Test Kanban',
  item_type: 'kanban',
  tasks: [],
  kanban_columns: [],
  ...overrides,
})

const makeTask = (overrides: Partial<Task> = {}): Task => ({
  id: 'task_1',
  name: 'Task 1',
  ...overrides,
})

describe('workspacesStore.fetchKanbanTasks', () => {
  beforeEach(() => {
    setActivePinia(createPinia())
    Object.defineProperty(globalThis, 'localStorage', {
      value: makeLocalStorageStub(),
      writable: true,
      configurable: true,
    })
  })

  afterEach(() => {
    vi.restoreAllMocks()
  })

  it('replaces item.tasks with the API response', async () => {
    const store = useWorkspacesStore()
    // Seed the store with the workspace + item.
    store.workspaces = [
      { id: WS_ID, name: 'ws', icon: '📁', expanded: false, items: [makeItem()] },
    ]
    const freshTasks = [
      makeTask({ id: 'task_a', name: 'A', kanban_column_id: 'col_1', kanban_position: 0 }),
      makeTask({ id: 'task_b', name: 'B', kanban_column_id: 'col_1', kanban_position: 1 }),
    ]
    vi.spyOn(api, 'getTasks').mockResolvedValue({
      tasks: freshTasks,
      has_more: false,
      next_cursor: null,
    })

    await store.fetchKanbanTasks(WS_ID, ITEM_ID)

    const item = store.workspaces[0]!.items[0]!
    expect(item.tasks).toEqual(freshTasks)
    expect(api.getTasks).toHaveBeenCalledWith(WS_ID, ITEM_ID)
  })

  it('is a no-op when the item is not found locally', async () => {
    const store = useWorkspacesStore()
    store.workspaces = [] // empty store
    const spy = vi.spyOn(api, 'getTasks').mockResolvedValue({
      tasks: [],
      has_more: false,
      next_cursor: null,
    })

    await store.fetchKanbanTasks(WS_ID, ITEM_ID)

    // getTasks is never called — short-circuit before the HTTP request.
    expect(spy).not.toHaveBeenCalled()
  })

  it('leaves the previous tasks array untouched when the API fails', async () => {
    const store = useWorkspacesStore()
    const existingTask = makeTask({ id: 'task_old', name: 'Old' })
    store.workspaces = [
      {
        id: WS_ID,
        name: 'ws',
        icon: '📁',
        expanded: false,
        items: [makeItem({ tasks: [existingTask] })],
      },
    ]
    vi.spyOn(api, 'getTasks').mockRejectedValue(new Error('network down'))

    await store.fetchKanbanTasks(WS_ID, ITEM_ID)

    const item = store.workspaces[0]!.items[0]!
    // Silent failure: the old tasks array is preserved so the UI
    // doesn't flash to empty on a transient network blip. The next
    // SSE event will trigger another fetch.
    expect(item.tasks).toEqual([existingTask])
  })

  it('passes through pagination fields (has_more, next_cursor) to the item', async () => {
    // Mirrors the loadMoreTasks action's pattern (workspaces.ts:1051-1083):
    // the item has hasMoreTasks + tasksNextCursor fields that the
    // folder-list view uses to render the "Load more" button. We don't
    // expect kanban-view to render that button today, but the fields
    // must be set for consistency.
    const store = useWorkspacesStore()
    store.workspaces = [
      { id: WS_ID, name: 'ws', icon: '📁', expanded: false, items: [makeItem()] },
    ]
    vi.spyOn(api, 'getTasks').mockResolvedValue({
      tasks: [makeTask()],
      has_more: true,
      next_cursor: 'cursor_abc',
    })

    await store.fetchKanbanTasks(WS_ID, ITEM_ID)

    const item = store.workspaces[0]!.items[0]!
    expect(item.hasMoreTasks).toBe(true)
    expect(item.tasksNextCursor).toBe('cursor_abc')
  })
})
```

- [ ] **Step 2: Run the new tests; confirm all 4 FAIL**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox/src/apps/desktop
timeout 120 bunx vitest run workspacesStoreKanbanTasks.spec.ts 2>&1 | tail -n 25
```

Expected: All 4 tests fail with `TypeError: store.fetchKanbanTasks is not a function` (the action doesn't exist yet).

- [ ] **Step 3: Commit the failing tests**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox
git add src/apps/desktop/src/__tests__/workspacesStoreKanbanTasks.spec.ts
git commit -m "test(workspaces-store): failing tests for fetchKanbanTasks action"
```

### Task 1.2: Implement the action

**Files:**
- Modify: `src/apps/desktop/src/stores/workspaces.ts` (insert new action near `fetchKanbanColumns` at line 663)

- [ ] **Step 1: Add `fetchKanbanTasks` after `fetchKanbanColumns`**

Insert immediately after `fetchKanbanColumns` (line 682) and before `addKanbanColumn` (line 687):

```ts
// Refresh an item's tasks from the backend and replace the local
// `item.tasks` array. Used by the kanbanSse store to react to
// `kanban_task.*` SSE events (moved / assigned / unassigned) so the
// KanbanView.vue card visibly moves to the new column without a
// manual reload.
//
// Mirrors `fetchKanbanColumns` in shape and error semantics:
//   - Silently no-ops if the item isn't in the local store (defensive
//     against stale SSE events after a workspace switch).
//   - Silently preserves the existing tasks array on API failure
//     (matches `fetchKanbanColumns`'s best-effort semantics — the
//     next SSE event will trigger another fetch).
//   - Sets `hasMoreTasks` + `tasksNextCursor` on the item for
//     pagination-state consistency (matches `loadMoreTasks`'s
//     pattern at workspaces.ts:1051-1083).
//
// Does NOT call `api.getTasks` if the item is missing — short-circuit
// before the HTTP request to avoid a needless 404 roundtrip.
async function fetchKanbanTasks(
  workspaceId: string,
  itemId: string,
): Promise<void> {
  const item = findItem(workspaceId, itemId)
  if (!item) return
  try {
    const { tasks, has_more, next_cursor } = await api.getTasks(workspaceId, itemId)
    item.tasks = tasks ?? []
    item.hasMoreTasks = has_more
    item.tasksNextCursor = next_cursor
  } catch (err) {
    console.error('[workspacesStore.fetchKanbanTasks] API call failed:', err)
    // Leave the existing tasks array untouched so the UI doesn't
    // flash to empty on a transient network blip. The next SSE
    // event will trigger another fetch.
  }
}
```

- [ ] **Step 2: Export from the store's return object**

In `workspaces.ts:1568` (the `return { ... }` block), add `fetchKanbanTasks` next to `fetchKanbanColumns`:

```ts
fetchKanbanColumns,
fetchKanbanTasks,
```

- [ ] **Step 3: Run the new tests; confirm all 4 PASS**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox/src/apps/desktop
timeout 120 bunx vitest run workspacesStoreKanbanTasks.spec.ts 2>&1 | tail -n 15
```

Expected: All 4 tests pass. If `findItem` is not in scope, check the import structure — `findItem` is defined at line 586 in the same file (inside the `defineStore` callback), so it's available to all sibling actions.

- [ ] **Step 4: Run the full test suite; confirm no regressions**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox/src/apps/desktop
timeout 120 bunx vitest run 2>&1 | tail -n 10
```

Expected: All existing tests still pass + 4 new `workspacesStoreKanbanTasks` tests. Total increases by 4.

- [ ] **Step 5: Run the TypeScript type-check**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox/src/apps/desktop
timeout 120 bun run build 2>&1 | tail -n 10
```

Expected: `vue-tsc --build` succeeds with no new errors. CRITICAL: `bun run build`, NOT `bunx vitest run` — see project memory `desktop-typescript-bun-build-as-typecheck.md`.

- [ ] **Step 6: Commit**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox
git add src/apps/desktop/src/stores/workspaces.ts
git commit -m "feat(workspaces-store): add fetchKanbanTasks action (mirrors fetchKanbanColumns)"
```

---

## Chunk 2: Dispatch SSE events by family in `kanbanSse.ts`

**Goal:** When a `kanban_task.*` event arrives, call `fetchKanbanTasks` so the affected task's `kanban_column_id` + `kanban_position` are refreshed in the store and the card visibly moves. Column events continue to call `fetchKanbanColumns`.

**Files touched:**
- `src/apps/desktop/src/stores/kanbanSse.ts` (modify — branch the onEvent handler)

### Task 2.1: Branch the SSE event handler

**Files:**
- Modify: `src/apps/desktop/src/stores/kanbanSse.ts:57-69` (the onEvent callback)

- [ ] **Step 1: Replace the handler body**

Replace the current onEvent body (lines 57-69) with a branched dispatch:

```ts
(event) => {
  // Drop events for other workspaces — the backend fans out
  // kanban events globally, so any connected client receives
  // them all. Skipping the no-op fetch keeps the local store's
  // re-fetch rate at 1 per actual mutation.
  if (event.workspace_id !== workspaceId) return
  const ws = useWorkspacesStore()
  // Dispatch by event family. Column events refresh the column
  // list (renames, reorder, add, delete); task events refresh the
  // task list (move, assign, unassign). A full re-fetch (vs in-place
  // patch) is the simplest correct action — sibling positions
  // renumber as part of every move, and the SSE payload doesn't
  // include the new positions of every sibling, so client-side
  // patching would be brittle. A future optimization could grow the
  // payload and switch to in-place updates.
  if ('column_id' in event) {
    // KanbanColumnEvent: column_id is the discriminator.
    void ws.fetchKanbanColumns(event.workspace_id, event.item_id)
  } else if ('task_id' in event) {
    // KanbanTaskEvent: task_id is the discriminator. The move /
    // assign / unassign all change item.tasks, so a single
    // fetchKanbanTasks handles all three.
    void ws.fetchKanbanTasks(event.workspace_id, event.item_id)
  }
  // Defensive: unknown event shapes are silently dropped (no
  // fetch, no warning) — the API factory guarantees only the
  // two known shapes reach this callback.
},
```

The `'column_id' in event` / `'task_id' in event` discriminated-union narrowing works because `KanbanColumnEvent` has `column_id: string` and `KanbanTaskEvent` has `task_id: string` (and neither has the other field). TypeScript's type narrowing will recognize the discriminator and the call to `fetchKanbanColumns` (which expects 2 args) or `fetchKanbanTasks` (which expects 2 args) type-checks.

- [ ] **Step 2: Type-check**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox/src/apps/desktop
timeout 120 bun run build 2>&1 | tail -n 10
```

Expected: `vue-tsc --build` succeeds. The `'column_id' in event` narrowing is a standard TypeScript discriminated-union idiom and type-checks against the `KanbanColumnEvent | KanbanTaskEvent` union.

- [ ] **Step 3: Commit**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox
git add src/apps/desktop/src/stores/kanbanSse.ts
git commit -m "feat(kanban-sse): dispatch task events to fetchKanbanTasks (column events unchanged)"
```

### Task 2.2: Update the existing SSE test to match the new dispatch

**Files:**
- Modify: `src/apps/desktop/src/__tests__/kanbanSse.spec.ts:121-139` (the "triggers fetchKanbanColumns on kanban_task events" test)

- [ ] **Step 1: Replace the test**

Replace the test at lines 121-139:

```ts
  it('triggers fetchKanbanTasks on kanban_task events (moved action)', async () => {
    const ws = useWorkspacesStore()
    const fetchColumnsSpy = vi.spyOn(ws, 'fetchKanbanColumns').mockResolvedValue()
    const fetchTasksSpy = vi.spyOn(ws, 'fetchKanbanTasks').mockResolvedValue()

    const store = useKanbanSseStore()
    store.initKanbanSse('ws_1')

    const event: KanbanTaskEvent = {
      action: 'moved',
      workspace_id: 'ws_1',
      item_id: 'item_1',
      task_id: 'task_1',
      new_column_id: 'col_done',
      new_position: 0,
    }
    dispatch(event)

    // Task events refresh TASKS, not columns. fetchKanbanColumns must
    // NOT be called — that would be wasted HTTP traffic (and would mask
    // a future bug where the column handler accidentally picks up task
    // events).
    expect(fetchColumnsSpy).not.toHaveBeenCalled()
    expect(fetchTasksSpy).toHaveBeenCalledWith('ws_1', 'item_1')
  })

  it('triggers fetchKanbanTasks on kanban_task events (assigned action)', async () => {
    const ws = useWorkspacesStore()
    const fetchTasksSpy = vi.spyOn(ws, 'fetchKanbanTasks').mockResolvedValue()

    const store = useKanbanSseStore()
    store.initKanbanSse('ws_1')

    const event: KanbanTaskEvent = {
      action: 'assigned',
      workspace_id: 'ws_1',
      item_id: 'item_1',
      task_id: 'task_new',
      new_column_id: 'col_1',
      new_position: 0,
    }
    dispatch(event)

    expect(fetchTasksSpy).toHaveBeenCalledWith('ws_1', 'item_1')
  })

  it('triggers fetchKanbanTasks on kanban_task events (unassigned action)', async () => {
    const ws = useWorkspacesStore()
    const fetchTasksSpy = vi.spyOn(ws, 'fetchKanbanTasks').mockResolvedValue()

    const store = useKanbanSseStore()
    store.initKanbanSse('ws_1')

    const event: KanbanTaskEvent = {
      action: 'unassigned',
      workspace_id: 'ws_1',
      item_id: 'item_1',
      task_id: 'task_1',
      new_column_id: null,
      new_position: null,
    }
    dispatch(event)

    expect(fetchTasksSpy).toHaveBeenCalledWith('ws_1', 'item_1')
  })

  it('triggers fetchKanbanColumns (NOT fetchKanbanTasks) on kanban_column events', async () => {
    const ws = useWorkspacesStore()
    const fetchColumnsSpy = vi.spyOn(ws, 'fetchKanbanColumns').mockResolvedValue()
    const fetchTasksSpy = vi.spyOn(ws, 'fetchKanbanTasks').mockResolvedValue()

    const store = useKanbanSseStore()
    store.initKanbanSse('ws_1')

    const event: KanbanColumnEvent = {
      action: 'updated',
      workspace_id: 'ws_1',
      item_id: 'item_1',
      column_id: 'col_1',
    }
    dispatch(event)

    expect(fetchColumnsSpy).toHaveBeenCalledWith('ws_1', 'item_1')
    // Column events must NOT trigger task fetches — they're a
    // different shape of mutation (rename / reorder / add / delete
    // columns don't change task positions).
    expect(fetchTasksSpy).not.toHaveBeenCalled()
  })
```

The 3 new "task" tests assert the NEW dispatch. The "column" test (renamed from "triggers fetchKanbanColumns on kanban_column events") adds a negative assertion — `fetchKanbanTasks` must NOT be called for column events. This guards against future regressions where someone re-merges the two dispatch branches.

The existing tests at lines 103-119 ("triggers fetchKanbanColumns on kanban_column events") and lines 141-162 ("ignores events for other workspaces") are unchanged.

- [ ] **Step 2: Run the updated SSE tests; confirm all pass**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox/src/apps/desktop
timeout 120 bunx vitest run kanbanSse.spec.ts 2>&1 | tail -n 25
```

Expected: All 8 tests pass (the 5 original + the 3 new / updated). The "triggers fetchKanbanColumns on kanban_task events" test (the one being replaced) will now FAIL because it expects `fetchKanbanColumns` to be called on a task event — confirming the bug-fix intent.

- [ ] **Step 3: Run the full test suite; confirm no regressions**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox/src/apps/desktop
timeout 120 bunx vitest run 2>&1 | tail -n 10
```

Expected: All tests pass. Total increases by 3 (3 new kanban_task tests, replacing the 1 old "triggers fetchKanbanColumns on kanban_task events" test → net +2 test cases, plus the 4 new workspacesStoreKanbanTasks tests from Chunk 1 → net +6 across both files).

- [ ] **Step 4: Type-check**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox/src/apps/desktop
timeout 120 bun run build 2>&1 | tail -n 10
```

Expected: `vue-tsc --build` succeeds. The test file's typed `KanbanTaskEvent` literal with `new_column_id: null` / `new_position: null` is valid (the interface declares these as `string | null | undefined`).

- [ ] **Step 5: Commit**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox
git add src/apps/desktop/src/__tests__/kanbanSse.spec.ts
git commit -m "test(kanban-sse): assert task events trigger fetchKanbanTasks, not fetchKanbanColumns"
```

---

## Chunk 3: KanbanView.vue doc comment update

**Goal:** Document that the component auto-refreshes on kanban SSE events. NO behavior change — the reactivity already works once the store updates `item.tasks`.

**Files touched:**
- `src/apps/desktop/src/components/KanbanView.vue` (modify — comment-only change)

### Task 3.1: Update the doc comment

**Files:**
- Modify: `src/apps/desktop/src/components/KanbanView.vue:1-37` (the leading doc comment)

- [ ] **Step 1: Add the SSE note**

After the existing "Public API: emits: ..." block (around line 35), add a "Live updates" paragraph:

```vue
  Live updates:
    The component reacts to backend SSE events on `/api/kanban/events`
    through the workspacesStore. Two event families drive auto-refresh:
      - kanban_column.* (created / updated / deleted / reordered)
        → workspacesStore.fetchKanbanColumns refreshes
          item.kanban_columns. The columns row re-renders.
      - kanban_task.* (assigned / moved / unassigned)
        → workspacesStore.fetchKanbanTasks refreshes item.tasks.
          The cards re-filter by kanban_column_id and re-sort by
          kanban_position, so the affected card visibly moves
          between columns without a manual reload.

    Both refresh paths are owned by useKanbanSseStore (one global
    connection, AppLayout-managed). KanbanView.vue does NOT open
    its own SSE connection — the store-level subscription covers
    the lifetime of the AppLayout (one connection, even if the
    user navigates between kanbans).
```

- [ ] **Step 2: Type-check (no source changes, but verify nothing broke)**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox/src/apps/desktop
timeout 120 bun run build 2>&1 | tail -n 10
```

Expected: `vue-tsc --build` succeeds. Comments don't affect type-check, but the build step confirms the file still parses cleanly.

- [ ] **Step 3: Commit**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox
git add src/apps/desktop/src/components/KanbanView.vue
git commit -m "docs(KanbanView): document auto-refresh via kanban SSE events"
```

---

## Chunk 4: End-to-end manual smoke test

**Goal:** Confirm that a task move triggered via the AI agent's `kanban_move_task` tool visibly moves the card in the open KanbanView without a manual reload.

**Files touched:**
- (No source change — manual smoke test)

### Task 4.1: Spin up nalar on port 8080

- [ ] **Step 1: Build the binary (if not already built)**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox
timeout 180 zig build install:linux:system 2>&1 | tail -n 5
```

Expected: `Build Summary: 4/6 steps succeeded`. The cp step fails with permission denied (expected — `/usr/local/bin/nalar` requires root). The binary at `zig-out/bin/nalar` is built.

- [ ] **Step 2: Start nalar on port 8080 (NOT 8081 — see Mandatory rules)**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox
./zig-out/bin/nalar --port 8080 &
echo "PID: $!"
sleep 2
```

Expected: nalar starts on port 8080. The 8081 instance is untouched.

### Task 4.2: Smoke test the auto-move

- [ ] **Step 1: List the kanban columns**

```bash
curl -sS http://127.0.0.1:8080/api/workspaces/ws_1779002584293_e52cd134532e1f00/items/item_1782442554104741821/kanban/columns | python3 -m json.tool
```

Expected: 3 columns (todo / in progress / done).

- [ ] **Step 2: Open the SSE stream in one terminal**

```bash
curl -N http://127.0.0.1:8080/api/kanban/events
```

Expected: The connection stays open; the server emits `event: connected\ndata: {...}\n\n` immediately.

- [ ] **Step 3: Open the desktop app in a browser (port 8080)**

Navigate to `http://localhost:8080`, expand the kanban workspace, click on the `kanban sprint 1` item. The 3-column board renders. Open DevTools → Network → filter by "EventStream".

- [ ] **Step 4: Trigger a task move via curl (simulating the AI agent)**

Find a task id and target column id (the seeded defaults are visible in the kanban API response):

```bash
# Replace task_id and column_id with real values from the board.
curl -X PATCH http://127.0.0.1:8080/api/workspaces/ws_1779002584293_e52cd134532e1f00/items/item_1782442554104741821/tasks/<task_id>/move \
  -H 'Content-Type: application/json' \
  -d '{"column_id":"<col_id>","position":0}'
```

Expected: 200 response with the updated task object.

- [ ] **Step 5: Confirm the SSE event arrives**

In the curl terminal from Step 2, you should see within 1 second:

```
event: kanban_task
data: {"action":"moved","workspace_id":"ws_...","item_id":"item_...","task_id":"task_...","new_column_id":"<col_id>","new_position":0}
```

- [ ] **Step 6: Confirm the card visually moves in the browser**

In the browser window, the moved card SHOULD appear in the target column within 1–2 seconds (the fetch + render cycle). Without the fix, the card stays in the old column.

- [ ] **Step 7: Stop nalar**

```bash
kill $(pgrep -f "nalar --port 8080")
```

(NEVER `pkill -f "zig build run"` — would also kill the 8081 instance.)

### Task 4.3: Commit the smoke-test result

- [ ] **Step 1: Document the smoke test**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox
git commit --allow-empty -m "test(kanban-sse): smoke test confirms task auto-move on /api/kanban/events"
```

---

## Verification

After all 4 chunks land:

1. **Frontend type-check:** `cd src/apps/desktop && timeout 120 bun run build` exits clean. CRITICAL: `bun run build`, NOT `bunx vitest run` — see project memory `desktop-typescript-bun-build-as-typecheck.md`.
2. **Frontend unit tests:** `cd src/apps/desktop && timeout 120 bunx vitest run` passes all tests. New tests added:
   - `workspacesStoreKanbanTasks.spec.ts` — 4 tests for `fetchKanbanTasks`
   - `kanbanSse.spec.ts` — 3 new tests (moved / assigned / unassigned → fetchKanbanTasks) + 1 renamed test (column events → fetchKanbanColumns, with negative assertion)
3. **Backend still compiles:** `timeout 180 zig build install:linux:system` succeeds (the backend changes from PR #38 are unchanged; this verifies nothing in the frontend broke the cross-compile path).
4. **End-to-end smoke test:** A task move triggered via curl visibly moves the card in the open KanbanView within 1–2 seconds.
5. **Regression check:** Drag-and-drop on the board still works. The KanbanColumn → KanbanView → AppLayout → workspacesStore.moveTaskToColumn chain emits the SSE event via the backend handler, and the local optimistic update (line 793) happens immediately; the SSE re-fetch then arrives and re-syncs the local store to the backend's post-renumber positions (no visual flash because the optimistic and backend states match for single-user cases).

## Risk / known limitations

- **Stale data on multi-user conflict:** if two clients move tasks in the same column simultaneously, the last SSE event wins on each client. The optimistic-update-then-SSE-confirm pattern means the second mover's client briefly sees its own position, then the SSE re-fetch restores the backend's ordering. Acceptable for v1; full multi-user conflict resolution is out of scope.
- **SSE re-fetch overwrites optimistic update on failure:** if the optimistic `moveTaskToColumn` call succeeds locally but the API call fails, the optimistic state is rolled back (workspaces.ts:780-796). The SSE re-fetch then arrives and (if the API actually persisted) shows the post-failure state. No data loss, but the user sees a brief flash. Acceptable.
- **Re-fetch costs:** every SSE event triggers one HTTP call. For a kanban with heavy multi-user activity, this could become a hot loop. Mitigated by: (a) the SSE event rate is bounded by the backend's mutation rate (no fanout), (b) `api.getTasks` is cheap (one indexed query), (c) the page size cap of 20 keeps the response small. A future optimization could coalesce rapid events (debounce the fetch by 100ms) if real-world usage shows it.
- **`fetchKanbanTasks` race with `init()`:** if `init()` is still in-flight when an SSE event arrives, the SSE-triggered fetch races with the init's per-item `getTasks` call. Both are read-only; the last write to `item.tasks` wins. In practice `init()` completes within a few hundred ms and the SSE event is unlikely to arrive before then (the SSE event itself needs an LLM tool call, which takes seconds). Acceptable.
- **Pagination reset on SSE refresh:** `fetchKanbanTasks` replaces `item.tasks` with the first page (20 tasks). If a kanban has >20 tasks and the user has scrolled to load more (folder-list view), the next SSE refresh reverts them to page 1. Acceptable for v1; kanban boards rarely exceed 20 tasks.

## Rollback

- **Chunk 1 (fetchKanbanTasks):** revert the new action. The kanbanSse store will fall back to the old single-handler that always called `fetchKanbanColumns`, and the SSE pipeline continues to work for column events. Task auto-move stops working (the bug returns), but no other behavior changes.
- **Chunk 2 (event dispatch):** revert the branched onEvent handler to the original single `fetchKanbanColumns` call. Task events silently stop triggering fetches (back to the original bug).
- **Chunk 3 (doc comment):** comment-only — no rollback needed.
- **Chunk 4 (smoke test):** no source changes — no rollback needed.

---

## Files to create / modify

| File | Change |
|---|---|
| `src/apps/desktop/src/stores/workspaces.ts` | Add `fetchKanbanTasks(workspaceId, itemId)` action (Chunk 1); export from store's return object |
| `src/apps/desktop/src/stores/kanbanSse.ts` | Branch onEvent by event family (Chunk 2) |
| `src/apps/desktop/src/__tests__/workspacesStoreKanbanTasks.spec.ts` | NEW: 4 tests for `fetchKanbanTasks` |
| `src/apps/desktop/src/__tests__/kanbanSse.spec.ts` | Replace 1 task-event test with 3 + add 1 negative-assertion test for column events (Chunk 2) |
| `src/apps/desktop/src/components/KanbanView.vue` | Doc-comment update for "Live updates" section (Chunk 3) |

**Total LOC estimate:**
- New code: ~30 lines (`fetchKanbanTasks` action + branch in onEvent + 4 + 4 new tests)
- Modified code: ~15 lines (doc comment, test rewrites, export from store)
- Test coverage: 8 new tests across 2 files