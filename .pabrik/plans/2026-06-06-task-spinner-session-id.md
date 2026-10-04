# Plan: Loading Spinner for Workspace Task Rows (task id = worker session id)

## Goal
Show the same yellow spinning indicator that the chat list uses next to a task name whenever the worker is actively processing that task. The task ID is the worker session ID — no new wiring, no backend change.

## Context

### How the chat list spinner works today
- `App.vue` provides a global `processingState: Ref<Record<string, boolean>>` (line 7-8) and populates it from the worker SSE stream. The map is keyed by the worker's `session_id` (with `id` as fallback), see `App.vue:18-39`.
- `ChatsList.vue` injects that ref, then for each chat row renders a yellow spinner when `!!processingState[item.id]` is true (template at `ChatsList.vue:489-497`):
  ```html
  <span v-if="item.processing === true" class="w-5 h-5 flex items-center justify-center shrink-0">
    <div class="w-4 h-4 border-2 rounded-full animate-spin"
         style="border-color: var(--color-yellow); border-top-color: transparent"></div>
  </span>
  ```
- The visual is a `border-2` ring with `var(--color-yellow)` and a transparent top — the classic CSS spinner.

### Why the same pattern works for tasks with zero backend work
- `AppLayout.vue:648-658` already mounts `<ChatView :chat-id="activeTask.id" :type="'task'" />` for task views. The LLM stream's session ID IS the task ID.
- Worker SSE events carry `session_id` for that task. `App.vue` keys `processingState` by that `session_id`, so `processingState[task.id]` automatically flips `true` when the worker is running and `false` when it ends.
- The frontend only needs to read from the same injected ref.

### What's currently missing
- `WorkspaceItem.vue:117-143` renders each task as a bullet + name + delete button. **No spinner**, even when the LLM is actively processing that task. The user has no visual signal in the sidebar that the task is "live."

## Approach
Mirror the `ChatsList.vue` pattern exactly: inject the same `processingState` ref into `WorkspaceItem.vue`, then add a smaller yellow spinner (3×3 to fit the 12-px text row) in place of the task's bullet point when `processingState[task.id]` is true. Hide the bullet while the spinner is shown so the row has a clean visual marker.

## Implementation Steps

### Step 1 — `src/apps/desktop/src/components/WorkspaceItem.vue`

**1a. Add the `inject` import (top of `<script setup>`)**

Current line 2:
```ts
import { computed } from 'vue'
```
Change to:
```ts
import { computed, inject, type Ref } from 'vue'
```

**1b. Inject the `processingState` ref (after the existing `useWorkspacesStore()` call at line 6)**

```ts
// Inject processingState from App.vue. Same contract ChatsList uses:
// keyed by worker session_id (which equals task.id when ChatView is
// mounted for a task — see AppLayout.vue:651 :chat-id="activeTask.id").
const processingState = inject<Ref<Record<string, boolean>>>(
  'processingState',
  ref<Record<string, boolean>>({}),
)
```

Add `ref` to the `vue` import too: `import { computed, inject, ref, type Ref } from 'vue'`.

**1c. Add the spinner to the task row template (replace lines 128-131)**

Current:
```html
<!-- Bullet point -->
<span class="w-1.5 h-1.5 rounded-full shrink-0" :style="{ backgroundColor: workspacesStore.activeTaskId === task.id ? 'var(--color-aqua)' : 'var(--semantic-text-dim)' }" />
<!-- Task name -->
<span class="flex-1 truncate">{{ task.name }}</span>
```

New:
```html
<!-- Spinner while worker is processing this task (mirrors ChatsList.vue:489-497, scaled down to fit 12px text). Bullet is hidden while the spinner is shown so the row has a single, clear visual marker. -->
<span
  v-if="processingState[task.id]"
  class="w-4 h-4 flex items-center justify-center shrink-0"
  data-testid="task-spinner"
>
  <div
    class="w-3 h-3 border-2 rounded-full animate-spin"
    style="border-color: var(--color-yellow); border-top-color: transparent"
  ></div>
</span>
<!-- Bullet point (only when not processing) -->
<span
  v-else
  class="w-1.5 h-1.5 rounded-full shrink-0"
  :style="{ backgroundColor: workspacesStore.activeTaskId === task.id ? 'var(--color-aqua)' : 'var(--semantic-text-dim)' }"
/>
<!-- Task name -->
<span class="flex-1 truncate">{{ task.name }}</span>
```

No other template, script, or style changes are required.

### Step 2 — New test file `src/apps/desktop/src/__tests__/workspaceItemTaskSpinner.spec.ts`

Mirror the structure of `sidebarActiveState.spec.ts:1-50` (the existing `ChatsList` + `processingState` test harness). Use the same `pinia` setup, the same `vue-router` mock, the same `makeLocalStorageStub` helper from `./helpers`.

The component under test (`WorkspaceItem`) doesn't call `useRouter`/`useRoute`, so the `vue-router` mock is not strictly required — but the `workspacesStore` actions it may trigger (delete) don't navigate, so it's also safe to skip. Keep the test minimal and only mock what `WorkspaceItem` actually uses.

```ts
/**
 * Regression tests for the "task row shows no spinner while worker is
 * processing" gap. WorkspaceItem must read from the same processingState
 * ref App.vue provides and show a yellow spinner on the matching row.
 */
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { setActivePinia, createPinia } from 'pinia'
import { ref } from 'vue'
import { mount } from '@vue/test-utils'

import WorkspaceItem from '../components/WorkspaceItem.vue'
import { useWorkspacesStore } from '../stores/workspaces'
import { makeLocalStorageStub } from './helpers'

const noTasksItem = {
  id: 'item_1',
  name: 'My Project',
  item_type: 'folder',
  tasks: [
    { id: 'task_alpha', name: 'Alpha task' },
    { id: 'task_beta', name: 'Beta task' },
  ],
}

function mountWorkspaceItem(tasks: Array<{ id: string; name: string }> = noTasksItem.tasks) {
  const processingState = ref<Record<string, boolean>>({})
  const wrapper = mount(WorkspaceItem, {
    props: {
      item: { ...noTasksItem, tasks },
      isActive: false,
      workspaceId: 'ws_1',
    },
    global: {
      provide: { processingState },
    },
  })
  return { wrapper, processingState }
}

describe('WorkspaceItem task spinner', () => {
  beforeEach(() => {
    setActivePinia(createPinia())
    Object.defineProperty(globalThis, 'localStorage', {
      value: makeLocalStorageStub(),
      writable: true,
      configurable: true,
    })
  })

  afterEach(() => {
    // pinia teardown is automatic via setActivePinia(createPinia()) in beforeEach
  })

  it('shows no spinner when no task is in processingState', () => {
    const { wrapper } = mountWorkspaceItem()
    expect(wrapper.findAll('[data-testid="task-spinner"]')).toHaveLength(0)
  })

  it('shows a spinner on the matching task when processingState[task.id] is true', async () => {
    const { wrapper, processingState } = mountWorkspaceItem()
    processingState.value = { task_alpha: true }
    await wrapper.vm.$nextTick()
    const spinners = wrapper.findAll('[data-testid="task-spinner"]')
    expect(spinners).toHaveLength(1)
    // The visible task is the one in processingState
    expect(wrapper.text()).toContain('Alpha task')
  })

  it('shows spinners on multiple tasks when several are processing', async () => {
    const { wrapper, processingState } = mountWorkspaceItem()
    processingState.value = { task_alpha: true, task_beta: true }
    await wrapper.vm.$nextTick()
    expect(wrapper.findAll('[data-testid="task-spinner"]')).toHaveLength(2)
  })

  it('hides the spinner and restores the bullet when the task is removed from processingState', async () => {
    const { wrapper, processingState } = mountWorkspaceItem()
    processingState.value = { task_alpha: true }
    await wrapper.vm.$nextTick()
    expect(wrapper.findAll('[data-testid="task-spinner"]')).toHaveLength(1)
    processingState.value = {}
    await wrapper.vm.$nextTick()
    expect(wrapper.findAll('[data-testid="task-spinner"]')).toHaveLength(0)
  })
})
```

The empty item's `tasks` are rendered only when `isExpanded === true`, so the test must expand the item before asserting. Add the `toggleExpandedItem('item_1')` call in each test (uses the `workspacesStore`):

```ts
import { useWorkspacesStore } from '../stores/workspaces'
// ...
const ws = useWorkspacesStore()
ws.expandedItemIds['item_1'] = true
```

Place that call right after `mountWorkspaceItem()` in each test that needs to see the rendered rows.

## Test Plan

| Test | Input | Expected |
|---|---|---|
| No tasks processing | `processingState = {}` | 0 spinners, bullets rendered |
| One task processing | `processingState = { task_alpha: true }` | 1 spinner, on the alpha row; bullet hidden on that row, rendered on beta |
| Two tasks processing | `processingState = { task_alpha: true, task_beta: true }` | 2 spinners, no bullets on either |
| Worker ends mid-session | start with `task_alpha: true`, then set `{}` | spinner gone, bullet back |

The data-testid is the single point of contact — tests should never depend on the exact class names or inline styles, so future visual tweaks don't break the regression suite.

## Verification

1. `cd src/apps/desktop && bun run build` — type-checks pass; no unused-import errors from the new `ref`/`inject`/`Ref` import in `WorkspaceItem.vue`.
2. `cd src/apps/desktop && bun test src/__tests__/workspaceItemTaskSpinner.spec.ts` — all 4 new tests pass.
3. `cd src/apps/desktop && bun test` — full frontend suite still green (31 prior tests, no regressions).
4. Manual smoke (with `bun run dev` and a running `nalar` server on port 8080):
   - Open the sidebar, expand a workspace, add a task, click it to open `ChatView`.
   - Send a message that takes a few seconds.
   - Confirm a yellow spinner appears next to the task name in the sidebar's task row, and disappears when the worker emits the `deleted` SSE event.

## Out of Scope

- No backend / Zig changes — confirmed by user.
- No changes to `stores/workspaces.ts` (we read from the injected ref directly; no `processing` field added to the `Task` type).
- No changes to `App.vue` (already provides `processingState`).
- No changes to `ChatsList.vue` (already correct).
- No changes to the task creation flow, the `updateTaskSimple` API, the `Worker` table, or the worker SSE shape.
- No persistence: the spinner is purely a runtime visual derived from the live `processingState` ref, which is already rebuilt from `fetchInitialWorkers()` on every SSE reconnect (`App.vue:65-88`).
